import assert from "node:assert/strict";
import crypto from "node:crypto";
import http from "node:http";
import test from "node:test";

import worker, { PortalSessionVault } from "../src/index.js";
import { bytesToBase64, parsePortalEnvConfig, safeJsonParse } from "../src/protocol.js";

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

async function startLocalMockServer(handler) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const addr = server.address();
  return {
    origin: `http://127.0.0.1:${addr.port}`,
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

function readReqBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
  });
}

test("Cloud Task Center defaults ALL periodic tasks OFF, preserves lazy keep-alive, and supports task list/detail/monitors", async (t) => {
  let gradeHitCount = 0;
  let examHitCount = 0;
  let loginSeedHits = 0;
  let publishedGrades = [
    { xnm: "2025", xqm: "3", kch: "CS101", kcmc: "程序设计基础", cj: "91", jd: "4.1", xf: "4.0" },
  ];
  let publishedExams = [
    {
      xnm: "2025",
      xqm: "3",
      kcmc: "高等数学A",
      kssj: "2026-01-12(09:00-11:00)",
      cdxqmc: "崂山校区",
      cdmc: "弘毅楼A201",
      zwh: "15",
    },
  ];
  const webhookDelivered = [];

  const mockServer = await startLocalMockServer(async (req, res) => {
    const u = new URL(req.url, "http://127.0.0.1");
    const cookieHdr = req.headers.cookie || "";

    if (u.pathname === "/webhook/generic" && req.method === "POST") {
      const raw = await readReqBody(req);
      webhookDelivered.push({
        sig: req.headers["x-courselens-signature"] || "",
        ts: req.headers["x-courselens-timestamp"] || "",
        raw,
        json: JSON.parse(raw),
      });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end('{"ok":true}');
      return;
    }

    if (u.pathname === "/jwglxt/xtgl/index_cxYhxxIndex.html") {
      loginSeedHits += 1;
      if (!cookieHdr.includes("JSESSIONID=VALID_LAZY")) {
        res.writeHead(901);
        res.end("sessionOut");
        return;
      }
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end('<div class="infoContentTitle">陈同学-20240088</div>');
      return;
    }

    if (u.pathname === "/jwglxt/cjcx/cjcx_cxXsgrcj.html") {
      gradeHitCount += 1;
      if (!cookieHdr.includes("JSESSIONID=VALID_LAZY")) {
        res.writeHead(901);
        res.end("sessionOut");
        return;
      }
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ items: publishedGrades }));
      return;
    }

    if (u.pathname === "/jwglxt/kwgl/kscx_cxXsksxxIndex.html") {
      examHitCount += 1;
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ items: publishedExams }));
      return;
    }

    res.writeHead(404);
    res.end("not found");
  });
  t.after(() => mockServer.close());

  let virtualNow = 1_780_000_000_000;
  const env = {
    COURSELENS_API_KEY: "task-center-key",
    PORTAL_URL: `${mockServer.origin}/jwglxt`,
    PORTAL_USERNAME: "20240088",
    PORTAL_COOKIES: "JSESSIONID=VALID_LAZY",
    ALLOWED_HOSTS: `${mockServer.origin}`,
    __ALLOW_LOOPBACK_FOR_TEST: true,
    __NOW_FN: () => virtualNow,
  };
  const harness = createDurableObjectHarness(env);
  env.SESSION_VAULT = harness.namespace;
  const authHdr = {
    Authorization: "Bearer task-center-key",
    "Content-Type": "application/json",
  };

  // 1. Inspect initial GET /v1/tasks -> ALL tasks must be disabled by default and zero alarm scheduled
  const initListRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/tasks", { headers: authHdr }),
    env,
  );
  assert.equal(initListRes.status, 200);
  const initList = await initListRes.json();
  assert.equal(initList.activeTaskCount, 0);
  assert.equal(initList.nextAlarmAt, null);
  assert.equal(harness.getScheduledAlarm(), null);
  for (const tk of initList.tasks) {
    assert.equal(tk.enabled, false, `Task ${tk.taskId} must default to OFF`);
    assert.equal(tk.status, "DISABLED");
  }

  // 2. Lazy re-authentication on /v1/proxy works seamlessly while ALL cloud tasks are OFF!
  const lazyProxyRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/proxy", {
      method: "POST",
      headers: authHdr,
      body: JSON.stringify({
        method: "POST",
        url: `${mockServer.origin}/jwglxt/cjcx/cjcx_cxXsgrcj.html`,
        bodyBase64: bytesToBase64(new TextEncoder().encode("xnm=2025&xqm=3")),
      }),
    }),
    env,
  );
  assert.equal(lazyProxyRes.status, 200);
  assert.ok(loginSeedHits >= 1);
  assert.equal(gradeHitCount >= 1, true);
  assert.equal(harness.getScheduledAlarm(), null, "Lazy proxy must keep zero alarms when tasks are OFF");

  // 3. Configure HMAC-signed Generic Webhook and verify secret encryption + URL masking
  const putWh = await worker.fetch(
    new Request("https://worker.example.dev/v1/webhook", {
      method: "PUT",
      headers: authHdr,
      body: JSON.stringify({
        url: `${mockServer.origin}/webhook/generic`,
        provider: "generic",
        secret: "hmac_super_secret_999",
      }),
    }),
    env,
  );
  assert.equal(putWh.status, 200);
  const whInfo = await putWh.json();
  assert.equal(whInfo.configured, true);
  assert.equal(whInfo.hasSecret, true);
  const rawStorageDump = JSON.stringify(Array.from(harness.backingMap.entries()));
  assert.equal(rawStorageDump.includes("hmac_super_secret_999"), false, "Webhook secret must be encrypted at rest");

  // 4. Enable ONLY `monitor:grades` via PATCH /v1/tasks/monitor:grades (keep `monitor:exams` OFF)
  const enableGradesRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/tasks/monitor%3Agrades", {
      method: "PATCH",
      headers: authHdr,
      body: JSON.stringify({ enabled: true, intervalSec: 600 }),
    }),
    env,
  );
  assert.equal(enableGradesRes.status, 200);
  const enabledDetail = await enableGradesRes.json();
  assert.equal(enabledDetail.enabled, true);
  assert.equal(enabledDetail.intervalSec, 600);
  assert.equal(harness.getScheduledAlarm(), virtualNow + 600_000);

  // 5. First alarm run -> silent baseline initialization (0 webhook alerts, 0 exam hits because exams is OFF!)
  const examHitsBefore = examHitCount;
  virtualNow += 600_000;
  await harness.getVault().alarm();
  assert.equal(examHitCount, examHitsBefore, "Disabled monitor:exams must never be queried");
  assert.equal(webhookDelivered.length, 0, "First baseline initialization must not spam Webhook");

  const detailAfterBase = await (
    await worker.fetch(
      new Request("https://worker.example.dev/v1/tasks/monitor:grades", { headers: authHdr }),
      env,
    )
  ).json();
  assert.equal(detailAfterBase.metrics.baselineInitialized, true);
  assert.equal(detailAfterBase.metrics.trackedItemCount, 1);
  assert.equal(detailAfterBase.logs[0].status, "BASELINE_INIT");

  // 6. Publish a new grade and fire second alarm -> detects diff, records recentChanges, sends HMAC Webhook!
  publishedGrades.push({
    xnm: "2025",
    xqm: "3",
    kch: "CS202",
    kcmc: "计算机组成原理",
    cj: "95",
    jd: "4.5",
    xf: "3.5",
  });
  virtualNow += 600_000;
  await harness.getVault().alarm();
  assert.equal(webhookDelivered.length, 1);
  assert.equal(webhookDelivered[0].json.event, "grade_change");
  assert.match(webhookDelivered[0].json.body, /计算机组成原理/);
  const expectedHmac = crypto
    .createHmac("sha256", "hmac_super_secret_999")
    .update(`${webhookDelivered[0].ts}.${webhookDelivered[0].raw}`)
    .digest("hex");
  assert.equal(webhookDelivered[0].sig, `sha256=${expectedHmac}`);

  const detailAfterChange = await (
    await worker.fetch(
      new Request("https://worker.example.dev/v1/tasks/monitor:grades", { headers: authHdr }),
      env,
    )
  ).json();
  assert.equal(detailAfterChange.metrics.changeCount, 1);
  assert.equal(detailAfterChange.recentChanges.length, 1);
  assert.equal(detailAfterChange.recentChanges[0].courseName, "计算机组成原理");
  assert.equal(detailAfterChange.logs[0].status, "CHANGED");

  // 6b. Top-level PATCH /v1/monitor { resetBaseline: true } resets baseline without disabling monitor:grades
  const resetRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/monitor", {
      method: "PATCH",
      headers: authHdr,
      body: JSON.stringify({ resetBaseline: true }),
    }),
    env,
  );
  assert.equal(resetRes.status, 200);
  const resetJson = await resetRes.json();
  assert.equal(resetJson.grades.enabled, true);
  assert.equal(resetJson.grades.baselineInitialized, false);
  assert.equal(resetJson.grades.intervalSec, 600);
  assert.equal(resetJson.exams.intervalSec, 3600);

  // 6c. Targeted gradesEnabled + intervalSec does not overwrite exams.intervalSec
  const scopedPatch = await worker.fetch(
    new Request("https://worker.example.dev/v1/monitor", {
      method: "PATCH",
      headers: authHdr,
      body: JSON.stringify({ gradesEnabled: true, intervalSec: 900 }),
    }),
    env,
  );
  const scopedJson = await scopedPatch.json();
  assert.equal(scopedJson.grades.intervalSec, 900);
  assert.equal(scopedJson.exams.intervalSec, 3600);

  // 7. Turn `monitor:grades` switch back OFF -> pending alarm must be immediately deleted!
  await worker.fetch(
    new Request("https://worker.example.dev/v1/tasks/monitor:grades", {
      method: "PATCH",
      headers: authHdr,
      body: JSON.stringify({ enabled: false }),
    }),
    env,
  );
  assert.equal(harness.getScheduledAlarm(), null, "Disabling last active task must deleteAlarm()");
});

test("Dynamic Cookie Push (POST /v1/session/cookies) and COOKIE_ONLY sentinel work without static credentials and enforce HostPolicy", async (t) => {
  // Verify COOKIE_ONLY sentinel in parsePortalEnvConfig for One-Click Deploy users
  const parsedCookieOnly = parsePortalEnvConfig({
    PORTAL_URL: "https://jwglxt.example.edu.cn/jwglxt",
    PORTAL_USERNAME: "20250999",
    PORTAL_PASSWORD: "COOKIE_ONLY",
  });
  assert.equal(parsedCookieOnly.password, "");
  assert.equal(parsedCookieOnly.hasPasswordAuth, false);
  assert.equal(parsedCookieOnly.hasStaticCredentials, false);

  const mockPortal = await startLocalMockServer((req, res) => {
    const u = new URL(req.url, "http://127.0.0.1");
    const cookieHdr = req.headers.cookie || "";
    if (u.pathname === "/jwglxt/xtgl/index_cxYhxxIndex.html") {
      if (cookieHdr.includes("JSESSIONID=QR_SSO_SESSION_777")) {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end('<div class="infoContentTitle">扫码同学-20250999</div><p>学院：信息学院</p>');
        return;
      }
      res.writeHead(901);
      res.end("sessionOut");
      return;
    }
    res.writeHead(200);
    res.end("ok");
  });
  t.after(() => mockPortal.close());

  const env = {
    COURSELENS_API_KEY: "dynamic-cookie-key",
    PORTAL_URL: `${mockPortal.origin}/jwglxt`,
    PORTAL_USERNAME: "20250999",
    PORTAL_PASSWORD: "COOKIE_ONLY",
    __ALLOW_LOOPBACK_FOR_TEST: true,
  };
  const harness = createDurableObjectHarness(env);
  env.SESSION_VAULT = harness.namespace;
  const authHdr = {
    Authorization: "Bearer dynamic-cookie-key",
    "Content-Type": "application/json",
  };

  // 1. Before cookie push, GET /v1/session returns clear 401 SESSION_EXPIRED guidance (not 500 crash)
  const preSession = await worker.fetch(
    new Request("https://worker.example.dev/v1/session", { headers: authHdr }),
    env,
  );
  assert.equal(preSession.status, 401);
  assert.equal((await preSession.json()).status, "SESSION_EXPIRED");

  // 2. Untrusted portalUrl injection is blocked by HostPolicy (403 UNTRUSTED_URL)
  const evilPush = await worker.fetch(
    new Request("https://worker.example.dev/v1/session/cookies", {
      method: "POST",
      headers: authHdr,
      body: JSON.stringify({
        portalUrl: "https://evil.attacker.example/jwglxt",
        cookies: "JSESSIONID=QR_SSO_SESSION_777",
      }),
    }),
    env,
  );
  assert.equal(evilPush.status, 403);

  // 3. Valid cookie push establishes session, encrypts cookies at rest, and survives DO eviction
  const okPush = await worker.fetch(
    new Request("https://worker.example.dev/v1/session/cookies", {
      method: "POST",
      headers: authHdr,
      body: JSON.stringify({
        cookies: "JSESSIONID=QR_SSO_SESSION_777; route=node2",
      }),
    }),
    env,
  );
  assert.equal(okPush.status, 200);
  const pushJson = await okPush.json();
  assert.equal(pushJson.authenticated, true);
  assert.equal(pushJson.alive, true);
  assert.equal(pushJson.studentInfo.name, "扫码同学");
  assert.equal(pushJson.injectedCookieCount, 2);

  const rawDump = JSON.stringify(Array.from(harness.backingMap.entries()));
  assert.equal(rawDump.includes("QR_SSO_SESSION_777"), false, "Injected cookie must be encrypted at rest");

  harness.evictAndRecreateVault();
  const postEvict = await worker.fetch(
    new Request("https://worker.example.dev/v1/session", { headers: authHdr }),
    env,
  );
  assert.equal(postEvict.status, 200);
  assert.equal((await postEvict.json()).studentInfo.studentId, "20250999");
});

test("safeJsonParse returns parsed JSON or null without throwing", () => {
  assert.deepEqual(safeJsonParse('{"flag":"1"}'), { flag: "1" });
  assert.deepEqual(safeJsonParse("[1,2]"), [1, 2]);
  assert.equal(safeJsonParse("<html>login</html>"), null);
  assert.equal(safeJsonParse(""), null);
  assert.equal(safeJsonParse(null), null);
  assert.equal(safeJsonParse(undefined), null);
});
