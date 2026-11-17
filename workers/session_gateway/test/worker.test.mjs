import assert from "node:assert/strict";
import crypto from "node:crypto";
import http from "node:http";
import test from "node:test";

import worker, { PortalSessionVault } from "../src/index.js";
import { bytesToBase64 } from "../src/protocol.js";

/**
 * In-memory Durable Object storage & namespace harness matching Cloudflare's
 * `ctx.storage` + `env.SESSION_VAULT` APIs. Supports recreating the DO instance
 * to verify persistence across hibernation / eviction.
 */
function createDurableObjectHarness(envRef) {
  const backingMap = new Map();
  let scheduledAlarmMs = null;

  const storage = {
    async get(key) {
      if (!backingMap.has(key)) return undefined;
      return structuredClone(backingMap.get(key));
    },
    async put(key, value) {
      backingMap.set(key, structuredClone(value));
    },
    async delete(key) {
      return backingMap.delete(key);
    },
    async setAlarm(timestampMs) {
      scheduledAlarmMs = Number(timestampMs);
    },
    async getAlarm() {
      return scheduledAlarmMs;
    },
    async deleteAlarm() {
      scheduledAlarmMs = null;
    },
  };

  let activeVault = new PortalSessionVault({ storage }, envRef);

  const namespace = {
    idFromName(name) {
      return `do-id:${name}`;
    },
    get(_id) {
      return {
        fetch(req) {
          return activeVault.fetch(req);
        },
      };
    },
  };

  return {
    storage,
    backingMap,
    namespace,
    getScheduledAlarm: () => scheduledAlarmMs,
    getVault: () => activeVault,
    evictAndRecreateVault: () => {
      activeVault = new PortalSessionVault({ storage }, envRef);
      return activeVault;
    },
  };
}

function createRsaFixture() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync("rsa", {
    modulusLength: 1024,
    publicExponent: 0x10001,
  });
  const jwk = publicKey.export({ format: "jwk" });
  const toStdBase64 = (b64url) => {
    let s = b64url.replace(/-/g, "+").replace(/_/g, "/");
    while (s.length % 4 !== 0) s += "=";
    return s;
  };
  return {
    modulusBase64: toStdBase64(jwk.n),
    exponentBase64: toStdBase64(jwk.e),
    modulusHex: Buffer.from(jwk.n, "base64url").toString("hex"),
    exponentHex: Buffer.from(jwk.e, "base64url").toString("hex"),
    decryptPkcs1(cipherBase64) {
      const buf = Buffer.from(cipherBase64, "base64");
      return crypto
        .privateDecrypt(
          {
            key: privateKey,
            padding: crypto.constants.RSA_PKCS1_PADDING,
          },
          buf,
        )
        .toString("utf8");
    },
  };
}

async function startLocalMockServer(handler) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const addr = server.address();
  const origin = `http://127.0.0.1:${addr.port}`;
  return {
    origin,
    port: addr.port,
    close: () =>
      new Promise((resolve) => {
        if (typeof server.closeAllConnections === "function") {
          server.closeAllConnections();
        }
        server.close(resolve);
      }),
  };
}

const rsa = createRsaFixture();

test("public /health works and /v1/* enforces constant-time multi-key API Key auth", async () => {
  const env = {
    COURSELENS_API_KEY: "key-mobile-secret, key-cli-secret",
    PORTAL_URL: "https://jwglxt.qust.edu.cn/jwglxt",
    PORTAL_USERNAME: "20230001",
    PORTAL_PASSWORD: "pw",
    PORTAL_COOKIES: "JSESSIONID=seed123",
    __FETCH_IMPL: async () =>
      new Response(
        '<div class="infoContentTitle">张三-20230001</div><p>学院：计算机学院</p><p>班级：计科231</p>',
        { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } },
      ),
  };
  const harness = createDurableObjectHarness(env);
  env.SESSION_VAULT = harness.namespace;

  // 1. Public health check without API Key
  const healthRes = await worker.fetch(new Request("https://worker.example.dev/health"), env);
  assert.equal(healthRes.status, 200);
  const healthJson = await healthRes.json();
  assert.equal(healthJson.ok, true);
  assert.equal(healthJson.mode, "stateful-worker");

  // 2. OPTIONS CORS preflight
  const optRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/proxy", { method: "OPTIONS" }),
    env,
  );
  assert.equal(optRes.status, 204);
  assert.match(optRes.headers.get("access-control-allow-headers") || "", /Authorization/);

  // 3. Missing API Key -> 401
  const missingRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/session?offline=1"),
    env,
  );
  assert.equal(missingRes.status, 401);

  // 4. Wrong API Key -> 401
  const wrongRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/session?offline=1", {
      headers: { Authorization: "Bearer wrong-key" },
    }),
    env,
  );
  assert.equal(wrongRes.status, 401);

  // 5. First key via Authorization: Bearer
  const okBearer = await worker.fetch(
    new Request("https://worker.example.dev/v1/session", {
      headers: { Authorization: "Bearer key-mobile-secret" },
    }),
    env,
  );
  assert.equal(okBearer.status, 200);
  const sessionJson = await okBearer.json();
  assert.equal(sessionJson.alive, true);
  assert.equal(sessionJson.schoolId, "qust");
  assert.equal(sessionJson.studentInfo.name, "张三");
  assert.equal(sessionJson.studentInfo.department, "计算机学院");

  // 6. Second comma-separated key via X-CourseLens-Key
  const okCustomHeader = await worker.fetch(
    new Request("https://worker.example.dev/v1/session?offline=1", {
      headers: { "X-CourseLens-Key": "key-cli-secret" },
    }),
    env,
  );
  assert.equal(okCustomHeader.status, 200);
});

test("Zhengfang RSA login, single-flight deduplication, DO eviction persistence, 901 auto-relogin & zero cookie leakage", async (t) => {
  let loginPostCount = 0;
  let activeSessionId = "SID_GEN_1";
  let sessionGeneration = 1;
  let expectedPassword = "Correct#Password!2026";
  let receivedUpstreamHeaders = null;

  const mockPortal = await startLocalMockServer((req, res) => {
    const reqUrl = new URL(req.url, "http://127.0.0.1");
    const cookieHdr = req.headers.cookie || "";

    if (reqUrl.pathname === "/jwglxt/xtgl/login_slogin.html" && req.method === "GET") {
      res.writeHead(200, {
        "Content-Type": "text/html; charset=utf-8",
        "Set-Cookie": `PRELOGIN=pre_${sessionGeneration}; Path=/jwglxt; HttpOnly`,
      });
      res.end(`
        <html><body>
          <form action="/jwglxt/xtgl/login_slogin.html" method="post">
            <input type="hidden" id="csrftoken" name="csrftoken" value="csrf_${sessionGeneration}" />
            <input type="hidden" name="mmsfjm" value="1" />
            <input type="password" name="mm" />
          </form>
        </body></html>
      `);
      return;
    }

    if (reqUrl.pathname === "/jwglxt/xtgl/login_getPublicKey.html") {
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
      res.end(
        JSON.stringify({
          modulus: rsa.modulusBase64,
          exponent: rsa.exponentBase64,
        }),
      );
      return;
    }

    if (reqUrl.pathname === "/jwglxt/xtgl/login_slogin.html" && req.method === "POST") {
      loginPostCount += 1;
      const chunks = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", async () => {
        // Add small delay to ensure concurrent /v1/proxy calls overlap in flight.
        await new Promise((r) => setTimeout(r, 40));
        const form = new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
        const yhm = form.get("yhm");
        const mm = form.get("mm") || "";
        let decrypted = "";
        try {
          decrypted = rsa.decryptPkcs1(mm);
        } catch {
          decrypted = "";
        }
        if (yhm !== "20230888" || decrypted !== expectedPassword) {
          res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
          res.end('<p id="tips">用户名或密码不正确</p><input type="password" name="mm"/>');
          return;
        }
        activeSessionId = `SID_GEN_${sessionGeneration}`;
        res.writeHead(302, {
          Location: "/jwglxt/xtgl/index_initMenu.html?jsdm=xs",
          "Set-Cookie": `JSESSIONID=${activeSessionId}; Path=/jwglxt; HttpOnly`,
        });
        res.end();
      });
      return;
    }

    if (reqUrl.pathname === "/jwglxt/xtgl/index_initMenu.html") {
      if (!cookieHdr.includes(`JSESSIONID=${activeSessionId}`)) {
        res.writeHead(302, { Location: "/jwglxt/xtgl/login_slogin.html" });
        res.end();
        return;
      }
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end('<h4 class="media-heading">李四 同学</h4>');
      return;
    }

    if (reqUrl.pathname === "/jwglxt/xtgl/index_cxYhxxIndex.html") {
      if (!cookieHdr.includes(`JSESSIONID=${activeSessionId}`)) {
        res.writeHead(901, { "Content-Type": "text/plain" });
        res.end("sessionOut");
        return;
      }
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(
        '<div class="infoContentTitle">李四-20230888</div><p>学院：信息科学技术学院</p><p>班级：软件232</p>',
      );
      return;
    }

    if (reqUrl.pathname === "/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html") {
      receivedUpstreamHeaders = req.headers;
      if (!cookieHdr.includes(`JSESSIONID=${activeSessionId}`)) {
        res.writeHead(901, {
          "Content-Type": "text/plain",
          "Set-Cookie": "JSESSIONID=deleteMe; Path=/jwglxt",
        });
        res.end("sessionOut");
        return;
      }
      res.writeHead(200, {
        "Content-Type": "application/json; charset=utf-8",
        "Set-Cookie": "ROUTEID=.node1; Path=/",
      });
      res.end(JSON.stringify({ kbList: [{ kcmc: "高等数学", xqj: "1" }], gen: sessionGeneration }));
      return;
    }

    res.writeHead(404);
    res.end("not found");
  });
  t.after(() => mockPortal.close());

  let virtualNow = 1_760_000_000_000;
  const env = {
    COURSELENS_API_KEY: "api-key-alpha",
    PORTAL_URL: `${mockPortal.origin}/jwglxt`,
    PORTAL_USERNAME: "20230888",
    PORTAL_PASSWORD: expectedPassword,
    KEEPALIVE_INTERVAL_SEC: "600",
    KEEPALIVE_MAX_IDLE_SEC: "3600",
    __ALLOW_LOOPBACK_FOR_TEST: true,
    __NOW_FN: () => virtualNow,
  };
  const harness = createDurableObjectHarness(env);
  env.SESSION_VAULT = harness.namespace;

  const makeProxyReq = () =>
    worker.fetch(
      new Request("https://worker.example.dev/v1/proxy", {
        method: "POST",
        headers: {
          Authorization: "Bearer api-key-alpha",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          method: "POST",
          url: `${mockPortal.origin}/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html?gnmkdm=N2151`,
          headers: {
            "Content-Type": "application/x-www-form-urlencoded",
            Cookie: "CLIENT_EVIL_COOKIE=should_be_stripped",
            Authorization: "Bearer should_not_leak_upstream",
          },
          bodyBase64: bytesToBase64(new TextEncoder().encode("xnm=2025&xqm=3")),
        }),
      }),
      env,
    );

  // 1. Fire 5 concurrent cold-start /v1/proxy requests -> must single-flight into 1 login POST!
  const responses = await Promise.all([
    makeProxyReq(),
    makeProxyReq(),
    makeProxyReq(),
    makeProxyReq(),
    makeProxyReq(),
  ]);
  assert.equal(loginPostCount, 1, "Single-flight lock must deduplicate concurrent cold-start logins");

  for (const res of responses) {
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.status, 200);
    assert.equal("hopCookies" in body, false, "Must never expose hopCookies");
    for (const k of Object.keys(body.headers || {})) {
      assert.notEqual(k.toLowerCase(), "set-cookie", "Must strip Set-Cookie from response headers");
    }
    const decoded = JSON.parse(Buffer.from(body.bodyBase64, "base64").toString("utf8"));
    assert.equal(decoded.kbList[0].kcmc, "高等数学");
  }

  // Verify client Cookie & Authorization headers were stripped before hitting upstream portal
  assert.ok(receivedUpstreamHeaders);
  assert.equal(receivedUpstreamHeaders.authorization, undefined);
  assert.equal(receivedUpstreamHeaders.cookie.includes("CLIENT_EVIL_COOKIE"), false);
  assert.equal(receivedUpstreamHeaders.cookie.includes("JSESSIONID=SID_GEN_1"), true);

  // 2. Evict Durable Object in memory and recreate from persisted storage -> zero new login needed
  harness.evictAndRecreateVault();
  const afterEvictRes = await makeProxyReq();
  assert.equal(afterEvictRes.status, 200);
  assert.equal(loginPostCount, 1, "Hydrated CookieJar from DO storage must avoid re-login");

  // 3. Simulate upstream portal invalidating session (HTTP 901) -> transparent 1-shot re-login & replay
  sessionGeneration = 2;
  activeSessionId = "INVALIDATED_ON_SERVER";
  const reloginRes = await makeProxyReq();
  assert.equal(reloginRes.status, 200);
  assert.equal(loginPostCount, 2, "Should automatically re-login once on HTTP 901");
  const reloginPayload = await reloginRes.json();
  const reloginData = JSON.parse(Buffer.from(reloginPayload.bodyBase64, "base64").toString("utf8"));
  assert.equal(reloginData.gen, 2);

  // 4. Simulate Secret rotation (user changes PORTAL_PASSWORD in Cloudflare Secrets) -> fingerprint invalidation
  sessionGeneration = 3;
  expectedPassword = "Rotated#Password!2027";
  env.PORTAL_PASSWORD = expectedPassword;
  const rotatedRes = await makeProxyReq();
  assert.equal(rotatedRes.status, 200);
  assert.equal(loginPostCount, 3, "Password secret rotation must invalidate old fingerprint and re-login");

  // 5. Alarm keep-alive test: while active, alarm probes session without re-login; when expired, re-logs in; when idle > maxIdle, pauses
  assert.equal(harness.getScheduledAlarm(), virtualNow + 600_000);
  virtualNow += 600_000;
  await harness.getVault().alarm();
  assert.equal(loginPostCount, 3, "Healthy session during alarm should not re-login");
  assert.equal(harness.getScheduledAlarm(), virtualNow + 600_000);

  // Advance past maxIdle (3600s) without client traffic -> alarm should pause rescheduling
  const lastScheduled = harness.getScheduledAlarm();
  virtualNow += 4_000_000;
  await harness.getVault().alarm();
  assert.equal(
    harness.getScheduledAlarm(),
    lastScheduled,
    "Alarm should stop rescheduling once client is idle past KEEPALIVE_MAX_IDLE_SEC",
  );
});

test("Security Redlines #3 (POST timeout -> 504 RESULT_UNKNOWN, zero retry) & #4 (HostPolicy + SSRF guard)", async (t) => {
  let slowPostHits = 0;

  const mockPortal = await startLocalMockServer((req, res) => {
    const reqUrl = new URL(req.url, "http://127.0.0.1");
    if (reqUrl.pathname === "/jwglxt/xtgl/index_cxYhxxIndex.html") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end('<div class="infoContentTitle">王五-20230999</div>');
      return;
    }
    if (reqUrl.pathname === "/jwglxt/xsxk/zzxkyzb_xkBcZyZzxkYzb.html" && req.method === "POST") {
      slowPostHits += 1;
      // Intentionally hang longer than __UPSTREAM_TIMEOUT_MS (80ms)
      setTimeout(() => {
        if (!res.destroyed && !res.writableEnded) {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end('{"flag":"1"}');
        }
      }, 300).unref();
      return;
    }
    res.writeHead(200);
    res.end("ok");
  });
  t.after(() => mockPortal.close());

  const env = {
    COURSELENS_API_KEY: "redline-key",
    PORTAL_URL: `${mockPortal.origin}/jwglxt`,
    PORTAL_USERNAME: "20230999",
    PORTAL_COOKIES: "JSESSIONID=SEED_OK",
    __ALLOW_LOOPBACK_FOR_TEST: true,
    __UPSTREAM_TIMEOUT_MS: 80,
  };
  const harness = createDurableObjectHarness(env);
  env.SESSION_VAULT = harness.namespace;

  // 1. Redline #3: POST write timeout must return 504 RESULT_UNKNOWN with ZERO automatic retry
  const timeoutRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/proxy", {
      method: "POST",
      headers: {
        Authorization: "Bearer redline-key",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        method: "POST",
        url: `${mockPortal.origin}/jwglxt/xsxk/zzxkyzb_xkBcZyZzxkYzb.html`,
        bodyBase64: bytesToBase64(new TextEncoder().encode("jxb_ids=ABC")),
      }),
    }),
    env,
  );
  assert.equal(timeoutRes.status, 504);
  const timeoutJson = await timeoutRes.json();
  assert.equal(timeoutJson.status, "RESULT_UNKNOWN");
  assert.equal(slowPostHits, 1, "Write POST must NEVER be retried on timeout");

  // 2. Redline #4: Non-whitelisted external domain must be rejected with 403 UNTRUSTED_URL
  const evilHostRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/proxy", {
      method: "POST",
      headers: {
        Authorization: "Bearer redline-key",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        method: "GET",
        url: "https://evil.example.org/steal",
      }),
    }),
    env,
  );
  assert.equal(evilHostRes.status, 403);
  const evilJson = await evilHostRes.json();
  assert.equal(evilJson.status, "UNTRUSTED_URL");

  // 3. Redline #4: Loopback/private IP SSRF blocked in production mode (__ALLOW_LOOPBACK_FOR_TEST unset)
  const prodEnv = {
    COURSELENS_API_KEY: "redline-key",
    PORTAL_URL: "http://127.0.0.1:8080/jwglxt",
    PORTAL_COOKIES: "JSESSIONID=SEED",
  };
  const prodHarness = createDurableObjectHarness(prodEnv);
  prodEnv.SESSION_VAULT = prodHarness.namespace;

  const ssrfRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/session", {
      headers: { Authorization: "Bearer redline-key" },
    }),
    prodEnv,
  );
  assert.equal(ssrfRes.status, 403);
  const ssrfJson = await ssrfRes.json();
  assert.equal(ssrfJson.status, "UNTRUSTED_URL");
});

test("CAS SSO and Qingzhi portal login flows establish server-side sessions", async (t) => {
  // 1. CAS + Portal mock
  const mockCasPortal = await startLocalMockServer((req, res) => {
    const u = new URL(req.url, "http://127.0.0.1");
    if (u.pathname === "/cas/login" && req.method === "GET") {
      res.writeHead(200, {
        "Content-Type": "text/html; charset=utf-8",
        "Set-Cookie": "CAS_INIT=1; Path=/cas",
      });
      res.end(`
        <form id="fm1" action="/cas/login" method="post">
          <input type="hidden" name="execution" value="e1s1" />
          <input type="hidden" name="_eventId" value="submit" />
        </form>
      `);
      return;
    }
    if (u.pathname === "/cas/v2/getPubKey") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ modulus: rsa.modulusHex, exponent: rsa.exponentHex }));
      return;
    }
    if (u.pathname === "/cas/v2/getKaptchaStatus") {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("false");
      return;
    }
    if (u.pathname === "/cas/login" && req.method === "POST") {
      res.writeHead(302, {
        Location: `${mockCasPortal.origin}/jwglxt/sso?ticket=ST-12345`,
        "Set-Cookie": "CASTGC=TGT-999; Path=/cas; HttpOnly",
      });
      res.end();
      return;
    }
    if (u.pathname === "/jwglxt/sso") {
      res.writeHead(302, {
        Location: `${mockCasPortal.origin}/jwglxt`,
        "Set-Cookie": "JSESSIONID=CAS_PORTAL_SID; Path=/jwglxt; HttpOnly",
      });
      res.end();
      return;
    }
    if (u.pathname === "/jwglxt" || u.pathname === "/jwglxt/") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end('<div class="infoContentTitle">赵六-20231111</div>');
      return;
    }
    res.writeHead(404);
    res.end();
  });
  t.after(() => mockCasPortal.close());

  const casEnv = {
    COURSELENS_API_KEY: "cas-key",
    PORTAL_URL: `${mockCasPortal.origin}/jwglxt`,
    PORTAL_CAS_URL: `${mockCasPortal.origin}/cas/login`,
    PORTAL_USERNAME: "20231111",
    PORTAL_PASSWORD: "casPassword",
    __ALLOW_LOOPBACK_FOR_TEST: true,
  };
  casEnv.SESSION_VAULT = createDurableObjectHarness(casEnv).namespace;

  const casRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/session", {
      headers: { Authorization: "Bearer cas-key" },
    }),
    casEnv,
  );
  assert.equal(casRes.status, 200);
  const casJson = await casRes.json();
  assert.equal(casJson.alive, true);
  assert.equal(casJson.studentInfo.name, "赵六");

  // 2. Qingzhi (QZ) mock
  const mockQz = await startLocalMockServer((req, res) => {
    const u = new URL(req.url, "http://127.0.0.1");
    if (u.pathname === "/jsxsd/xk/LoginToXk" && req.method === "GET") {
      res.writeHead(200, {
        "Content-Type": "text/html; charset=utf-8",
        "Set-Cookie": "JSESSIONID=QZ_PRE; Path=/jsxsd",
      });
      res.end(`
        <script>var scode = "ABCDEFGHIJKLMNOPQRST1234567890"; var sxh = "12121212121212121212";</script>
        <form action="/jsxsd/xk/LoginToXk" method="post">
          <input type="password" name="userPassword" />
        </form>
      `);
      return;
    }
    if (u.pathname === "/jsxsd/xk/LoginToXk" && req.method === "POST") {
      const chunks = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", () => {
        const form = new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
        assert.equal(form.get("userAccount"), "20232222");
        assert.ok((form.get("encoded") || "").length > 12);
        res.writeHead(302, {
          Location: "/jsxsd/framework/xsMain.jsp",
          "Set-Cookie": "JSESSIONID=QZ_AUTHED; Path=/jsxsd; HttpOnly",
        });
        res.end();
      });
      return;
    }
    if (u.pathname === "/jsxsd/framework/xsMain.jsp") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end('<div id="Top1_divLoginName">孙七 同学</div>');
      return;
    }
    res.writeHead(404);
    res.end();
  });
  t.after(() => mockQz.close());

  const qzEnv = {
    COURSELENS_API_KEY: "qz-key",
    PORTAL_URL: `${mockQz.origin}/jsxsd`,
    PORTAL_SYSTEM: "QZ",
    PORTAL_USERNAME: "20232222",
    PORTAL_PASSWORD: "qzPassword",
    __ALLOW_LOOPBACK_FOR_TEST: true,
  };
  qzEnv.SESSION_VAULT = createDurableObjectHarness(qzEnv).namespace;

  const qzRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/session", {
      headers: { Authorization: "Bearer qz-key" },
    }),
    qzEnv,
  );
  assert.equal(qzRes.status, 200);
  const qzJson = await qzRes.json();
  assert.equal(qzJson.systemId, "QZ");
  assert.equal(qzJson.studentInfo.name, "孙七");
  assert.equal(qzJson.keepaliveMode, "lazy");
  assert.equal(qzJson.keepaliveIntervalSec, 0);
});

test("Default lazy keep-alive: zero idle alarms, legacy alarm cleanup, /v1/session verify TTL & staggered 901 generation deduplication", async (t) => {
  let loginPostCount = 0;
  let probeHitCount = 0;
  let activeSessionId = "LAZY_SID_1";
  let sessionGeneration = 1;
  let slowSecond901 = false;

  const mockPortal = await startLocalMockServer((req, res) => {
    const reqUrl = new URL(req.url, "http://127.0.0.1");
    const cookieHdr = req.headers.cookie || "";

    if (reqUrl.pathname === "/jwglxt/xtgl/login_slogin.html" && req.method === "GET") {
      res.writeHead(200, {
        "Content-Type": "text/html; charset=utf-8",
        "Set-Cookie": `PRELOGIN=lazy_${sessionGeneration}; Path=/jwglxt; HttpOnly`,
      });
      res.end(`
        <html><body>
          <form action="/jwglxt/xtgl/login_slogin.html" method="post">
            <input type="hidden" id="csrftoken" name="csrftoken" value="csrf_${sessionGeneration}" />
            <input type="hidden" name="mmsfjm" value="0" />
            <input type="password" name="mm" />
          </form>
        </body></html>
      `);
      return;
    }

    if (reqUrl.pathname === "/jwglxt/xtgl/login_slogin.html" && req.method === "POST") {
      loginPostCount += 1;
      req.resume();
      req.on("end", () => {
        activeSessionId = `LAZY_SID_${sessionGeneration}`;
        res.writeHead(302, {
          Location: "/jwglxt/xtgl/index_initMenu.html?jsdm=xs",
          "Set-Cookie": `JSESSIONID=${activeSessionId}; Path=/jwglxt; HttpOnly`,
        });
        res.end();
      });
      return;
    }

    if (reqUrl.pathname === "/jwglxt/xtgl/index_initMenu.html") {
      if (!cookieHdr.includes(`JSESSIONID=${activeSessionId}`)) {
        res.writeHead(302, { Location: "/jwglxt/xtgl/login_slogin.html" });
        res.end();
        return;
      }
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end('<h4 class="media-heading">周八 同学</h4>');
      return;
    }

    if (reqUrl.pathname === "/jwglxt/xtgl/index_cxYhxxIndex.html") {
      probeHitCount += 1;
      if (!cookieHdr.includes(`JSESSIONID=${activeSessionId}`)) {
        res.writeHead(901, { "Content-Type": "text/plain" });
        res.end("sessionOut");
        return;
      }
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end('<div class="infoContentTitle">周八-20236666</div>');
      return;
    }

    if (reqUrl.pathname === "/jwglxt/cjcx/cjcx_cxDgXscj.html") {
      if (!cookieHdr.includes(`JSESSIONID=${activeSessionId}`)) {
        const delayMs = slowSecond901 && reqUrl.searchParams.get("req") === "slow" ? 80 : 0;
        setTimeout(() => {
          res.writeHead(901, { "Content-Type": "text/plain" });
          res.end("sessionOut");
        }, delayMs);
        return;
      }
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ items: [{ kcmc: "数据结构" }], gen: sessionGeneration }));
      return;
    }

    res.writeHead(404);
    res.end("not found");
  });
  t.after(() => mockPortal.close());

  let virtualNow = 1_770_000_000_000;
  const env = {
    COURSELENS_API_KEY: "lazy-key",
    PORTAL_URL: `${mockPortal.origin}/jwglxt`,
    PORTAL_USERNAME: "20236666",
    PORTAL_PASSWORD: "lazyPassword",
    // Notice: KEEPALIVE_INTERVAL_SEC is intentionally omitted -> defaults to 0 (lazy mode)
    __ALLOW_LOOPBACK_FOR_TEST: true,
    __NOW_FN: () => virtualNow,
  };
  const harness = createDurableObjectHarness(env);
  env.SESSION_VAULT = harness.namespace;

  // Pre-seed a legacy scheduled alarm as if upgrading from an older Worker deployment
  await harness.storage.setAlarm(virtualNow + 900_000);
  assert.notEqual(harness.getScheduledAlarm(), null);

  // 1. Leftover alarm firing in lazy mode must clear itself with ZERO upstream requests
  await harness.getVault().alarm();
  assert.equal(harness.getScheduledAlarm(), null, "Legacy alarm must be cleared in lazy mode");
  assert.equal(loginPostCount, 0);
  assert.equal(probeHitCount, 0);

  // 2. First GET /v1/session logs in on demand and schedules ZERO background alarms
  await harness.storage.setAlarm(virtualNow + 900_000);
  harness.evictAndRecreateVault();
  const sessRes1 = await worker.fetch(
    new Request("https://worker.example.dev/v1/session", {
      headers: { Authorization: "Bearer lazy-key" },
    }),
    env,
  );
  assert.equal(sessRes1.status, 200);
  const sessJson1 = await sessRes1.json();
  assert.equal(sessJson1.alive, true);
  assert.equal(sessJson1.keepaliveMode, "lazy");
  assert.equal(sessJson1.keepaliveIntervalSec, 0);
  assert.equal(loginPostCount, 1);
  assert.equal(harness.getScheduledAlarm(), null, "Lazy mode must never schedule alarms after /v1/session");

  // 3. Consecutive GET /v1/session within SESSION_VERIFY_TTL_SEC (default 120s) skips upstream probe
  const probesAfterLogin = probeHitCount;
  virtualNow += 30_000;
  const sessRes2 = await worker.fetch(
    new Request("https://worker.example.dev/v1/session", {
      headers: { Authorization: "Bearer lazy-key" },
    }),
    env,
  );
  assert.equal(sessRes2.status, 200);
  assert.equal(probeHitCount, probesAfterLogin, "Short-term verify window should skip duplicate upstream probe");

  // Passing ?probe=1 forces live upstream verification immediately
  const sessProbeForced = await worker.fetch(
    new Request("https://worker.example.dev/v1/session?probe=1", {
      headers: { Authorization: "Bearer lazy-key" },
    }),
    env,
  );
  assert.equal(sessProbeForced.status, 200);
  assert.equal(probeHitCount, probesAfterLogin + 1, "?probe=1 must perform live upstream probe");

  // 4. Simulate 12 hours of zero requests (upstream session expires, zero background traffic)
  virtualNow += 12 * 3600 * 1000;
  sessionGeneration = 2;
  activeSessionId = "EXPIRED_OVERNIGHT";
  slowSecond901 = true;

  // Fire two concurrent /v1/proxy requests where request #2 receives HTTP 901 AFTER request #1 already finished re-login!
  const makeGradeProxy = (tag) =>
    worker.fetch(
      new Request("https://worker.example.dev/v1/proxy", {
        method: "POST",
        headers: {
          Authorization: "Bearer lazy-key",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          method: "POST",
          url: `${mockPortal.origin}/jwglxt/cjcx/cjcx_cxDgXscj.html?req=${tag}`,
          bodyBase64: bytesToBase64(new TextEncoder().encode("xnm=2025&xqm=3")),
        }),
      }),
      env,
    );

  const [fastRes, slowRes] = await Promise.all([
    makeGradeProxy("fast"),
    makeGradeProxy("slow"),
  ]);
  assert.equal(fastRes.status, 200);
  assert.equal(slowRes.status, 200);
  assert.equal(
    loginPostCount,
    2,
    "Staggered 901 responses from same expired generation must deduplicate into 1 re-login",
  );
  assert.equal(harness.getScheduledAlarm(), null, "Lazy mode must never schedule alarms after /v1/proxy");

  for (const r of [fastRes, slowRes]) {
    const payload = await r.json();
    const data = JSON.parse(Buffer.from(payload.bodyBase64, "base64").toString("utf8"));
    assert.equal(data.gen, 2);
  }

  // 5. After SESSION_VERIFY_TTL_SEC (120s) expires and upstream session dies again, GET /v1/session probes & re-logins lazily
  virtualNow += 180_000;
  sessionGeneration = 3;
  activeSessionId = "EXPIRED_AGAIN";
  const sessAfterTtl = await worker.fetch(
    new Request("https://worker.example.dev/v1/session", {
      headers: { Authorization: "Bearer lazy-key" },
    }),
    env,
  );
  assert.equal(sessAfterTtl.status, 200);
  assert.equal(loginPostCount, 3, "GET /v1/session past verify TTL must probe and re-login when expired");
  assert.equal(harness.getScheduledAlarm(), null, "Still zero alarms after lazy /v1/session re-login");

  // 6. Opting into KEEPALIVE_INTERVAL_SEC > 0 sets an alarm, and switching back to 0 clears it immediately
  env.KEEPALIVE_INTERVAL_SEC = "300";
  const optInRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/session?offline=1", {
      headers: { Authorization: "Bearer lazy-key" },
    }),
    env,
  );
  const optInJson = await optInRes.json();
  assert.equal(optInJson.keepaliveMode, "alarm");
  assert.equal(optInJson.keepaliveIntervalSec, 300);
  assert.equal(harness.getScheduledAlarm(), virtualNow + 300_000);

  env.KEEPALIVE_INTERVAL_SEC = "0";
  const backToLazyRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/session?offline=1", {
      headers: { Authorization: "Bearer lazy-key" },
    }),
    env,
  );
  const backToLazyJson = await backToLazyRes.json();
  assert.equal(backToLazyJson.keepaliveMode, "lazy");
  assert.equal(backToLazyJson.keepaliveIntervalSec, 0);
  assert.equal(harness.getScheduledAlarm(), null, "Switching KEEPALIVE_INTERVAL_SEC back to 0 must delete pending alarm");
});

test("Rejects placeholder API keys and enforces CORS_ORIGIN allowlist + hardening headers", async () => {
  // 1. Placeholder key from .dev.vars.example must fail closed with 500 CONFIG_ERROR
  const placeholderEnv = {
    COURSELENS_API_KEY: "cl_sk_replace_with_32_bytes_random_hex",
    PORTAL_URL: "https://jwglxt.qust.edu.cn/jwglxt",
  };
  placeholderEnv.SESSION_VAULT = createDurableObjectHarness(placeholderEnv).namespace;

  const placeholderRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/session?offline=1", {
      headers: { Authorization: "Bearer cl_sk_replace_with_32_bytes_random_hex" },
    }),
    placeholderEnv,
  );
  assert.equal(placeholderRes.status, 500);
  const placeholderJson = await placeholderRes.json();
  assert.equal(placeholderJson.status, "CONFIG_ERROR");

  // 2. CORS_ORIGIN comma-separated allowlist
  const corsEnv = {
    COURSELENS_API_KEY: "live-strong-secret-key",
    CORS_ORIGIN: "https://app.courselens.example, https://admin.courselens.example",
    PORTAL_URL: "https://jwglxt.qust.edu.cn/jwglxt",
    PORTAL_COOKIES: "JSESSIONID=SEED1",
  };
  corsEnv.SESSION_VAULT = createDurableObjectHarness(corsEnv).namespace;

  // Disallowed browser Origin -> 403 FORBIDDEN_ORIGIN on both OPTIONS and API call
  const evilPreflight = await worker.fetch(
    new Request("https://worker.example.dev/v1/proxy", {
      method: "OPTIONS",
      headers: { Origin: "https://evil.attacker.example" },
    }),
    corsEnv,
  );
  assert.equal(evilPreflight.status, 403);

  const evilGet = await worker.fetch(
    new Request("https://worker.example.dev/v1/session?offline=1", {
      headers: {
        Origin: "https://evil.attacker.example",
        Authorization: "Bearer live-strong-secret-key",
      },
    }),
    corsEnv,
  );
  assert.equal(evilGet.status, 403);
  assert.equal((await evilGet.json()).status, "FORBIDDEN_ORIGIN");

  // Allowed browser Origin -> 200 + echoed Origin + Vary: Origin + security headers
  const allowedGet = await worker.fetch(
    new Request("https://worker.example.dev/v1/session?offline=1", {
      headers: {
        Origin: "https://admin.courselens.example",
        Authorization: "Bearer live-strong-secret-key",
      },
    }),
    corsEnv,
  );
  assert.equal(allowedGet.status, 200);
  assert.equal(allowedGet.headers.get("access-control-allow-origin"), "https://admin.courselens.example");
  assert.equal(allowedGet.headers.get("vary"), "Origin");
  assert.equal(allowedGet.headers.get("x-content-type-options"), "nosniff");
  assert.equal(allowedGet.headers.get("x-frame-options"), "DENY");
  assert.equal(allowedGet.headers.get("referrer-policy"), "no-referrer");

  // Originless native/CLI request -> 200 allowed
  const cliGet = await worker.fetch(
    new Request("https://worker.example.dev/v1/session?offline=1", {
      headers: { Authorization: "Bearer live-strong-secret-key" },
    }),
    corsEnv,
  );
  assert.equal(cliGet.status, 200);
});

test("Encrypts persisted cookies at rest with AES-256-GCM in DO storage and fences DELETE /v1/session against concurrent writes", async (t) => {
  let releaseSlowProbe = null;
  let blockProbe = false;

  const mockPortal = await startLocalMockServer((req, res) => {
    const u = new URL(req.url, "http://127.0.0.1");
    if (u.pathname === "/jwglxt/xtgl/index_cxYhxxIndex.html") {
      const finish = () => {
        res.writeHead(200, {
          "Content-Type": "text/html; charset=utf-8",
          "Set-Cookie": "JSESSIONID=ULTRA_SECRET_DO_COOKIE_999; Path=/jwglxt; HttpOnly",
        });
        res.end('<div class="infoContentTitle">加密测试-20260001</div>');
      };
      if (blockProbe) {
        releaseSlowProbe = finish;
      } else {
        finish();
      }
      return;
    }
    res.writeHead(200);
    res.end("ok");
  });
  t.after(() => mockPortal.close());

  const env = {
    COURSELENS_API_KEY: "vault-enc-key",
    PORTAL_URL: `${mockPortal.origin}/jwglxt`,
    PORTAL_USERNAME: "20260001",
    PORTAL_COOKIES: "SEED_COOKIE=INITIAL_SECRET_VALUE",
    __ALLOW_LOOPBACK_FOR_TEST: true,
  };
  const harness = createDurableObjectHarness(env);
  env.SESSION_VAULT = harness.namespace;

  // 1. Trigger session establishment and inspect raw DO storage
  const res1 = await worker.fetch(
    new Request("https://worker.example.dev/v1/session", {
      headers: { Authorization: "Bearer vault-enc-key" },
    }),
    env,
  );
  assert.equal(res1.status, 200);

  const rawStoredCookies = harness.backingMap.get("v1:cookies");
  assert.ok(rawStoredCookies && typeof rawStoredCookies === "object");
  assert.equal(rawStoredCookies.alg, "AES-256-GCM");
  assert.equal(Array.isArray(rawStoredCookies), false, "Cookies must not be stored as plaintext array");
  const serializedBacking = JSON.stringify(Array.from(harness.backingMap.entries()));
  assert.equal(
    serializedBacking.includes("ULTRA_SECRET_DO_COOKIE_999"),
    false,
    "Plaintext JSESSIONID must never appear in DO SQLite storage",
  );
  assert.equal(
    serializedBacking.includes("INITIAL_SECRET_VALUE"),
    false,
    "Plaintext seed cookie must never appear in DO SQLite storage",
  );

  // Evict & hydrate from encrypted envelope
  harness.evictAndRecreateVault();
  const offlineHydrated = await worker.fetch(
    new Request("https://worker.example.dev/v1/session?offline=1", {
      headers: { Authorization: "Bearer vault-enc-key" },
    }),
    env,
  );
  assert.equal((await offlineHydrated.json()).authenticated, true);

  // 2. Concurrent DELETE /v1/session epoch fencing:
  // Start an in-flight /v1/session/refresh that blocks upstream, issue DELETE /v1/session while blocked,
  // then release the slow upstream response -> deleted session must NOT be resurrected!
  blockProbe = true;
  const inFlightRefresh = worker.fetch(
    new Request("https://worker.example.dev/v1/session/refresh", {
      method: "POST",
      headers: { Authorization: "Bearer vault-enc-key" },
    }),
    env,
  );

  // Wait until upstream handler has received the request
  while (!releaseSlowProbe) {
    await new Promise((r) => setTimeout(r, 5));
  }

  const delRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/session", {
      method: "DELETE",
      headers: { Authorization: "Bearer vault-enc-key" },
    }),
    env,
  );
  assert.equal(delRes.status, 200);

  // Now let the in-flight refresh finish
  blockProbe = false;
  releaseSlowProbe();
  await inFlightRefresh;

  assert.equal(
    harness.backingMap.has("v1:cookies"),
    false,
    "Stale in-flight refresh must NOT write cookies back to DO storage after DELETE /v1/session",
  );
  const afterDeleteOffline = await worker.fetch(
    new Request("https://worker.example.dev/v1/session?offline=1", {
      headers: { Authorization: "Bearer vault-enc-key" },
    }),
    env,
  );
  assert.equal(afterDeleteOffline.status, 200);
  assert.equal((await afterDeleteOffline.json()).authenticated, false);
});

test("Protects non-idempotent POST edge cases: 403 no-replay, post-redirect timeout -> 504 RESULT_UNKNOWN, login timeout -> 502 NETWORK_ERROR", async (t) => {
  let businessPostCount = 0;
  let redirectMutateCount = 0;
  let loginPostCount = 0;
  let hangLoginPost = false;

  const mockPortal = await startLocalMockServer((req, res) => {
    const u = new URL(req.url, "http://127.0.0.1");
    if (u.pathname === "/jwglxt/xtgl/login_slogin.html" && req.method === "GET") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(
        '<form action="/jwglxt/xtgl/login_slogin.html" method="post"><input name="csrftoken" value="t1"/><input name="mmsfjm" value="0"/><input type="password" name="mm"/></form>',
      );
      return;
    }
    if (u.pathname === "/jwglxt/xtgl/login_slogin.html" && req.method === "POST") {
      loginPostCount += 1;
      req.resume();
      if (hangLoginPost) {
        setTimeout(() => {
          if (!res.destroyed && !res.writableEnded) res.end();
        }, 300).unref();
        return;
      }
      res.writeHead(302, {
        Location: "/jwglxt/xtgl/index_initMenu.html",
        "Set-Cookie": "JSESSIONID=OK_SID; Path=/jwglxt; HttpOnly",
      });
      res.end();
      return;
    }
    if (u.pathname === "/jwglxt/xtgl/index_initMenu.html" || u.pathname === "/jwglxt/xtgl/index_cxYhxxIndex.html") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end('<div class="infoContentTitle">测试生-20260002</div>');
      return;
    }
    if (u.pathname === "/jwglxt/xsxk/forbidden_endpoint.html" && req.method === "POST") {
      businessPostCount += 1;
      res.writeHead(403, { "Content-Type": "application/json" });
      res.end('{"msg":"选课轮次未开放"}');
      return;
    }
    if (u.pathname === "/jwglxt/xsxk/mutate_then_redirect.html" && req.method === "POST") {
      redirectMutateCount += 1;
      res.writeHead(302, { Location: "/jwglxt/xsxk/slow_receipt.html" });
      res.end();
      return;
    }
    if (u.pathname === "/jwglxt/xsxk/slow_receipt.html") {
      setTimeout(() => {
        if (!res.destroyed && !res.writableEnded) {
          res.writeHead(200);
          res.end("receipt");
        }
      }, 300).unref();
      return;
    }
    res.writeHead(200);
    res.end("ok");
  });
  t.after(() => mockPortal.close());

  // 1. Login-stage POST timeout before client proxy request is ever sent -> 502 NETWORK_ERROR (NOT 504 RESULT_UNKNOWN)
  hangLoginPost = true;
  const coldTimeoutEnv = {
    COURSELENS_API_KEY: "edge-key",
    PORTAL_URL: `${mockPortal.origin}/jwglxt`,
    PORTAL_USERNAME: "20260002",
    PORTAL_PASSWORD: "pw",
    __ALLOW_LOOPBACK_FOR_TEST: true,
    __UPSTREAM_TIMEOUT_MS: 80,
  };
  coldTimeoutEnv.SESSION_VAULT = createDurableObjectHarness(coldTimeoutEnv).namespace;

  const coldLoginFailRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/proxy", {
      method: "POST",
      headers: {
        Authorization: "Bearer edge-key",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        method: "POST",
        url: `${mockPortal.origin}/jwglxt/xsxk/forbidden_endpoint.html`,
        bodyBase64: bytesToBase64(new TextEncoder().encode("id=1")),
      }),
    }),
    coldTimeoutEnv,
  );
  assert.equal(coldLoginFailRes.status, 502, "Unsent business POST when login times out must be 502, not 504");
  assert.equal((await coldLoginFailRes.json()).status, "NETWORK_ERROR");
  assert.equal(businessPostCount, 0, "Business POST was never sent");

  // 2. Generic HTTP 403 on business POST must NOT trigger re-login or replay the POST
  hangLoginPost = false;
  const liveEnv = {
    COURSELENS_API_KEY: "edge-key",
    PORTAL_URL: `${mockPortal.origin}/jwglxt`,
    PORTAL_USERNAME: "20260002",
    PORTAL_PASSWORD: "pw",
    __ALLOW_LOOPBACK_FOR_TEST: true,
    __UPSTREAM_TIMEOUT_MS: 80,
  };
  liveEnv.SESSION_VAULT = createDurableObjectHarness(liveEnv).namespace;

  loginPostCount = 0;
  const forbiddenRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/proxy", {
      method: "POST",
      headers: {
        Authorization: "Bearer edge-key",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        method: "POST",
        url: `${mockPortal.origin}/jwglxt/xsxk/forbidden_endpoint.html`,
        bodyBase64: bytesToBase64(new TextEncoder().encode("id=1")),
      }),
    }),
    liveEnv,
  );
  assert.equal(forbiddenRes.status, 200);
  const forbiddenPayload = await forbiddenRes.json();
  assert.equal(forbiddenPayload.status, 403);
  assert.equal(loginPostCount, 1, "Initial login only; HTTP 403 must NOT trigger a second re-login");
  assert.equal(businessPostCount, 1, "HTTP 403 POST must NOT be replayed");

  // 3. Business POST that mutated state on hop 0 (302) and timed out on hop 1 (GET) MUST return 504 RESULT_UNKNOWN
  const postRedirectTimeoutRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/proxy", {
      method: "POST",
      headers: {
        Authorization: "Bearer edge-key",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        method: "POST",
        url: `${mockPortal.origin}/jwglxt/xsxk/mutate_then_redirect.html`,
        bodyBase64: bytesToBase64(new TextEncoder().encode("jxb_ids=999")),
      }),
    }),
    liveEnv,
  );
  assert.equal(postRedirectTimeoutRes.status, 504);
  assert.equal((await postRedirectTimeoutRes.json()).status, "RESULT_UNKNOWN");
  assert.equal(redirectMutateCount, 1);
});

test("Blocks SSRF IPv6/trailing-dot bypasses, HTTPS downgrade, public-suffix supercookies, malformed Base64, and oversized payloads", async () => {
  // 1. SSRF bypass vectors (IPv4-mapped IPv6, NAT64, 6to4, febf:: link-local, trailing-dot localhost.)
  const ssrfVectors = [
    "http://[::ffff:127.0.0.1]/jwglxt",
    "http://[64:ff9b::10.0.0.1]/jwglxt",
    "http://[2002:c0a8:0101::1]/jwglxt",
    "http://[febf::1]/jwglxt",
    "http://localhost.:8080/jwglxt",
    "https://metadata.internal/jwglxt",
  ];
  for (const vectorUrl of ssrfVectors) {
    const env = {
      COURSELENS_API_KEY: "ssrf-test-key",
      PORTAL_URL: vectorUrl,
      PORTAL_COOKIES: "JSESSIONID=1",
    };
    env.SESSION_VAULT = createDurableObjectHarness(env).namespace;
    const res = await worker.fetch(
      new Request("https://worker.example.dev/v1/session", {
        headers: { Authorization: "Bearer ssrf-test-key" },
      }),
      env,
    );
    assert.equal(res.status, 403, `SSRF vector must be blocked: ${vectorUrl}`);
    assert.equal((await res.json()).status, "UNTRUSTED_URL");
  }

  // 2. Wildcard ALLOWED_HOSTS=* fails closed, and http:// ALLOWED_HOSTS cannot downgrade https:// PORTAL_URL
  const wildcardEnv = {
    COURSELENS_API_KEY: "ssrf-test-key",
    PORTAL_URL: "https://jwglxt.qust.edu.cn/jwglxt",
    ALLOWED_HOSTS: "*",
  };
  wildcardEnv.SESSION_VAULT = createDurableObjectHarness(wildcardEnv).namespace;
  const wildcardRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/session?offline=1", {
      headers: { Authorization: "Bearer ssrf-test-key" },
    }),
    wildcardEnv,
  );
  assert.equal(wildcardRes.status, 500);
  assert.equal((await wildcardRes.json()).status, "CONFIG_ERROR");

  const downgradeEnv = {
    COURSELENS_API_KEY: "ssrf-test-key",
    PORTAL_URL: "https://jwglxt.qust.edu.cn/jwglxt",
    ALLOWED_HOSTS: "http://legacy.qust.edu.cn",
    PORTAL_COOKIES: "JSESSIONID=1",
  };
  downgradeEnv.SESSION_VAULT = createDurableObjectHarness(downgradeEnv).namespace;
  const downgradeRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/proxy", {
      method: "POST",
      headers: {
        Authorization: "Bearer ssrf-test-key",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        method: "GET",
        url: "http://jwglxt.qust.edu.cn/jwglxt/kbcx",
      }),
    }),
    downgradeEnv,
  );
  assert.equal(downgradeRes.status, 403, "Plaintext HTTP to HTTPS PORTAL_URL must be blocked");
  assert.equal((await downgradeRes.json()).status, "UNTRUSTED_URL");

  // 3. Malformed bodyBase64 -> 400 VALIDATION_FAILED & >2MB payload -> 413 PAYLOAD_TOO_LARGE
  const badB64Res = await worker.fetch(
    new Request("https://worker.example.dev/v1/proxy", {
      method: "POST",
      headers: {
        Authorization: "Bearer ssrf-test-key",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        method: "POST",
        url: "https://jwglxt.qust.edu.cn/jwglxt/kbcx",
        bodyBase64: "%%%NOT_BASE64%%%",
      }),
    }),
    downgradeEnv,
  );
  assert.equal(badB64Res.status, 400);
  assert.equal((await badB64Res.json()).status, "VALIDATION_FAILED");

  const hugeBody = "A".repeat(2 * 1024 * 1024 + 1024);
  const hugeRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/proxy", {
      method: "POST",
      headers: {
        Authorization: "Bearer ssrf-test-key",
        "Content-Type": "application/json",
      },
      body: hugeBody,
    }),
    downgradeEnv,
  );
  assert.equal(hugeRes.status, 413);
  assert.equal((await hugeRes.json()).status, "PAYLOAD_TOO_LARGE");

  // 4. Public-suffix supercookie rejection in ServerCookieJar
  const { ServerCookieJar } = await import("../src/cookie_jar.js");
  const jar = new ServerCookieJar();
  jar.absorbSetCookies(
    [
      "EVIL_SUPER=1; Domain=edu.cn; Path=/",
      "VALID_SUB=2; Domain=qust.edu.cn; Path=/",
      "BAD_CTL=val\r\ninjected; Path=/",
    ],
    "https://jwglxt.qust.edu.cn/jwglxt",
  );
  assert.equal(jar.cookieHeaderFor("https://other.edu.cn/"), "");
  assert.equal(jar.cookieHeaderFor("https://pass.qust.edu.cn/"), "VALID_SUB=2");
});
