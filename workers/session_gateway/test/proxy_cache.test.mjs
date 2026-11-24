import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";

import worker, { PortalSessionVault } from "../src/index.js";
import { bytesToBase64 } from "../src/protocol.js";
import {
  MAX_CACHE_ENTRIES,
  PROXY_CACHE_ENTRY_PREFIX,
  classifyProxyCacheRequest,
  computeProxyCacheKey,
} from "../src/proxy_cache.js";

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
  const origin = `http://127.0.0.1:${addr.port}`;
  return {
    origin,
    close: () =>
      new Promise((resolve) => {
        if (typeof server.closeAllConnections === "function") {
          server.closeAllConnections();
        }
        server.close(resolve);
      }),
  };
}

test("classifyProxyCacheRequest enforces strict read-only allowlist, differentiated TTLs, and mutation invalidation", () => {
  const cacheConfig = {
    enabled: true,
    ttls: {
      catalog: 1800,
      schedule: 1800,
      grades: 300,
      exams: 600,
      progress: 3600,
      enrolled: 600,
      classrooms: 120,
      static: 86400,
    },
  };

  // Allowed read-only categories with distinct TTLs
  const sched = classifyProxyCacheRequest({
    method: "POST",
    url: "https://jw.edu.cn/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151",
    cacheConfig,
  });
  assert.equal(sched.cacheable, true);
  assert.equal(sched.category, "schedule");
  assert.equal(sched.ttlMs, 1800_000);

  const grades = classifyProxyCacheRequest({
    method: "POST",
    url: "https://jw.edu.cn/jwglxt/cjcx/cjcx_cxXsgrcj.html?doType=query&gnmkdm=N305005",
    cacheConfig,
  });
  assert.equal(grades.cacheable, true);
  assert.equal(grades.category, "grades");
  assert.equal(grades.ttlMs, 300_000);

  const exams = classifyProxyCacheRequest({
    method: "POST",
    url: "https://jw.edu.cn/jwglxt/kwgl/kscx_cxXsksxxIndex.html?doType=query&gnmkdm=N358105",
    cacheConfig,
  });
  assert.equal(exams.cacheable, true);
  assert.equal(exams.category, "exams");
  assert.equal(exams.ttlMs, 600_000);

  const progress = classifyProxyCacheRequest({
    method: "GET",
    url: "https://jw.edu.cn/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html?ver=new&gnmkdm=N105515",
    cacheConfig,
  });
  assert.equal(progress.cacheable, true);
  assert.equal(progress.category, "progress");
  assert.equal(progress.ttlMs, 3600_000);

  const filters = classifyProxyCacheRequest({
    method: "GET",
    url: "https://jw.edu.cn/jwglxt/cdjy/cdjy_cxKxcdlb.html?gnmkdm=N2155&layout=default",
    cacheConfig,
  });
  assert.equal(filters.cacheable, true);
  assert.equal(filters.category, "static");
  assert.equal(filters.ttlMs, 86400_000);

  const classrooms = classifyProxyCacheRequest({
    method: "POST",
    url: "https://jw.edu.cn/jwglxt/cdjy/cdjy_cxKxcdlb.html?doType=query&gnmkdm=N2155",
    cacheConfig,
  });
  assert.equal(classrooms.cacheable, true);
  assert.equal(classrooms.category, "classrooms");
  assert.equal(classrooms.ttlMs, 120_000);

  // Hard-denied: course selection read/write, login, captcha, __VIEWSTATE, followRedirects=false
  const selectWrite = classifyProxyCacheRequest({
    method: "POST",
    url: "https://jw.edu.cn/jwglxt/xsxk/zzxkyzbjk_xkBcZyZzxkYzb.html?gnmkdm=N253512",
    cacheConfig,
  });
  assert.equal(selectWrite.cacheable, false);
  assert.deepEqual(selectWrite.invalidates, ["schedule", "enrolled", "progress"]);

  const dropWrite = classifyProxyCacheRequest({
    method: "POST",
    url: "https://jw.edu.cn/jwglxt/xsxk/zzxkyzb_tuikBcZzxkYzb.html?gnmkdm=N253512",
    cacheConfig,
  });
  assert.equal(dropWrite.cacheable, false);
  assert.deepEqual(dropWrite.invalidates, ["schedule", "enrolled", "progress"]);

  const chosenList = classifyProxyCacheRequest({
    method: "POST",
    url: "https://jw.edu.cn/jwglxt/xsxk/zzxkyzb_cxZzxkYzbChoosedDisplay.html?gnmkdm=N253512",
    cacheConfig,
  });
  assert.equal(chosenList.cacheable, false);

  const sectionCap = classifyProxyCacheRequest({
    method: "POST",
    url: "https://jw.edu.cn/jwglxt/xsxk/zzxkyzbjk_cxJxbWithKchZzxkYzb.html?gnmkdm=N253512",
    cacheConfig,
  });
  assert.equal(sectionCap.cacheable, false);

  const viewStatePost = classifyProxyCacheRequest({
    method: "POST",
    url: "https://jw.edu.cn/jwglxt/cjcx/cjcx_cxXsgrcj.html",
    bodyBytes: new TextEncoder().encode("__VIEWSTATE=abc123&xnm=2025"),
    cacheConfig,
  });
  assert.equal(viewStatePost.cacheable, false);

  const noRedirect = classifyProxyCacheRequest({
    method: "GET",
    url: "https://jw.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs",
    followRedirects: false,
    cacheConfig,
  });
  assert.equal(noRedirect.cacheable, false);
});

test("computeProxyCacheKey canonicalizes param ordering and strips volatile noise while distinguishing terms", async () => {
  const k1 = await computeProxyCacheKey({
    method: "POST",
    url: "https://jw.edu.cn/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151&_=1760000001",
    bodyBytes: new TextEncoder().encode("xqm=3&xnm=2026&nd=999"),
  });
  const k2 = await computeProxyCacheKey({
    method: "POST",
    url: "https://jw.edu.cn/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151&_=1760009999",
    bodyBytes: new TextEncoder().encode("xnm=2026&xqm=3"),
  });
  const kDifferentTerm = await computeProxyCacheKey({
    method: "POST",
    url: "https://jw.edu.cn/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151",
    bodyBytes: new TextEncoder().encode("xnm=2025&xqm=12"),
  });
  assert.equal(k1, k2);
  assert.notEqual(k1, kDifferentTerm);
});

test("Dual-layer DO cache: differentiated TTLs, encrypted L2 persistence across eviction, single-flight dedup, bypassCache, mutation invalidation & /v1/cache API", async (t) => {
  const upstreamHits = {
    schedule: 0,
    grades: 0,
    enrolled: 0,
    selectionChosen: 0,
    selectionWrite: 0,
  };
  let scheduleVersion = 1;
  let gradesVersion = 1;

  const mockPortal = await startLocalMockServer((req, res) => {
    const reqUrl = new URL(req.url, "http://127.0.0.1");
    req.resume();
    req.on("end", () => {
      if (reqUrl.pathname === "/jwglxt/xtgl/index_cxYhxxIndex.html") {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end('<div class="infoContentTitle">测试同学-20260001</div>');
        return;
      }
      if (reqUrl.pathname === "/jwglxt/kbcx/xskbcx_cxXsgrkb.html") {
        upstreamHits.schedule += 1;
        setTimeout(() => {
          res.writeHead(200, {
            "Content-Type": "application/json; charset=utf-8",
            "Set-Cookie": "SHOULD_NOT_BE_CACHED=1; Path=/",
          });
          res.end(JSON.stringify({ kbList: [{ kcmc: `高等数学-v${scheduleVersion}` }] }));
        }, 25);
        return;
      }
      if (reqUrl.pathname === "/jwglxt/cjcx/cjcx_cxXsgrcj.html") {
        upstreamHits.grades += 1;
        res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
        res.end(JSON.stringify({ items: [{ kcmc: "操作系统", cj: `${90 + gradesVersion}` }] }));
        return;
      }
      if (reqUrl.pathname === "/jwglxt/xkcx/xkmdcx_cxXkmdcxIndex.html") {
        upstreamHits.enrolled += 1;
        res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
        res.end(JSON.stringify({ items: [{ kcmc: "编译原理" }] }));
        return;
      }
      if (reqUrl.pathname === "/jwglxt/xsxk/zzxkyzb_cxZzxkYzbChoosedDisplay.html") {
        upstreamHits.selectionChosen += 1;
        res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
        res.end(JSON.stringify({ tmpList: [{ kcmc: "实时选课已选" }] }));
        return;
      }
      if (reqUrl.pathname === "/jwglxt/xsxk/zzxkyzbjk_xkBcZyZzxkYzb.html") {
        upstreamHits.selectionWrite += 1;
        res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
        res.end(JSON.stringify({ flag: "1", msg: "选课成功" }));
        return;
      }
      res.writeHead(404);
      res.end("not found");
    });
  });
  t.after(() => mockPortal.close());

  let virtualNow = 1_780_000_000_000;
  const env = {
    COURSELENS_API_KEY: "cache-test-key",
    PORTAL_URL: `${mockPortal.origin}/jwglxt`,
    PORTAL_USERNAME: "20260001",
    PORTAL_COOKIES: "JSESSIONID=CACHE_SEED",
    CACHE_TTL_SCHEDULE_SEC: "1800", // 30m
    CACHE_TTL_GRADES_SEC: "300", // 5m
    CACHE_TTL_ENROLLED_SEC: "600", // 10m
    __ALLOW_LOOPBACK_FOR_TEST: true,
    __NOW_FN: () => virtualNow,
  };
  const harness = createDurableObjectHarness(env);
  env.SESSION_VAULT = harness.namespace;

  const callProxy = (path, { body = "xnm=2026&xqm=3", bypassCache = false, extraHeaders = {}, selection = false, confirmed = false } = {}) =>
    worker.fetch(
      new Request(`https://worker.example.dev/v1/${selection ? "selection" : "proxy"}`, {
        method: "POST",
        headers: {
          Authorization: "Bearer cache-test-key",
          "Content-Type": "application/json",
          ...extraHeaders,
        },
        body: JSON.stringify({
          method: "POST",
          confirmed,
          url: `${mockPortal.origin}${path}`,
          bodyBase64: bytesToBase64(new TextEncoder().encode(body)),
          ...(bypassCache ? { bypassCache: true } : {}),
        }),
      }),
      env,
    );

  // 1. Concurrent identical schedule requests deduplicate via single-flight into 1 upstream call
  const concurrent = await Promise.all([
    callProxy("/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151"),
    callProxy("/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151"),
    callProxy("/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151"),
  ]);
  assert.equal(upstreamHits.schedule, 1, "Concurrent identical requests must coalesce into 1 upstream call");
  const cacheStatuses = concurrent.map((r) => r.headers.get("x-courselens-cache"));
  assert.equal(cacheStatuses.filter((s) => s === "MISS").length, 1);
  assert.equal(cacheStatuses.filter((s) => s === "HIT").length, 2);

  // 2. Subsequent call hits L1 RAM cache with 0 upstream requests
  virtualNow += 60_000; // +1 min
  const l1HitRes = await callProxy("/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151");
  assert.equal(l1HitRes.headers.get("x-courselens-cache"), "HIT");
  assert.equal(l1HitRes.headers.get("x-courselens-cache-category"), "schedule");
  assert.equal(l1HitRes.headers.get("x-courselens-cache-age"), "60");
  const l1Body = await l1HitRes.json();
  assert.equal(l1Body.cache.layer, "L1");
  assert.equal(upstreamHits.schedule, 1);

  // Verify L2 DO storage is encrypted at rest (no plaintext course name stored!)
  let encryptedEntriesFound = 0;
  for (const [k, v] of harness.backingMap.entries()) {
    if (k.startsWith(PROXY_CACHE_ENTRY_PREFIX) && k !== "v1:pcache:index") {
      encryptedEntriesFound += 1;
      assert.equal(v.alg, "AES-256-GCM");
      assert.equal(JSON.stringify(v).includes("高等数学"), false, "Cached payload must be encrypted at rest");
    }
  }
  assert.equal(encryptedEntriesFound, 1);

  // 3. Evict DO from memory -> next request hits L2 encrypted DO SQLite with 0 upstream requests!
  harness.evictAndRecreateVault();
  virtualNow += 60_000; // +2 min total
  const l2HitRes = await callProxy("/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151");
  assert.equal(l2HitRes.headers.get("x-courselens-cache"), "HIT");
  const l2Body = await l2HitRes.json();
  assert.equal(l2Body.cache.layer, "L2");
  assert.equal(upstreamHits.schedule, 1, "L2 hit after DO hibernation must not hit upstream");

  // 4. Differentiated TTLs: grades expire after 5m while schedule (30m) is STILL cached!
  const grade1 = await callProxy("/jwglxt/cjcx/cjcx_cxXsgrcj.html?doType=query&gnmkdm=N305005");
  assert.equal(grade1.headers.get("x-courselens-cache"), "MISS");
  assert.equal(upstreamHits.grades, 1);

  virtualNow += 6 * 60_000; // +6 min (past 5m grades TTL, still well inside 30m schedule TTL)
  gradesVersion = 2;
  const grade2 = await callProxy("/jwglxt/cjcx/cjcx_cxXsgrcj.html?doType=query&gnmkdm=N305005");
  assert.equal(grade2.headers.get("x-courselens-cache"), "MISS");
  assert.equal(upstreamHits.grades, 2, "Grades must expire after 5m TTL");
  const grade2Json = await grade2.json();
  assert.equal(
    JSON.parse(Buffer.from(grade2Json.bodyBase64, "base64").toString("utf8")).items[0].cj,
    "92",
  );

  const schedStillHit = await callProxy("/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151");
  assert.equal(schedStillHit.headers.get("x-courselens-cache"), "HIT");
  assert.equal(upstreamHits.schedule, 1, "Schedule (30m TTL) must still be cached after 8m");

  // 5. Explicit bypassCache (both JSON body & header) forces fresh fetch and refreshes cache
  scheduleVersion = 2;
  const bypassRes = await callProxy("/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151", {
    bypassCache: true,
  });
  assert.equal(bypassRes.headers.get("x-courselens-cache"), "BYPASS");
  assert.equal(upstreamHits.schedule, 2);
  const bypassData = JSON.parse(
    Buffer.from((await bypassRes.json()).bodyBase64, "base64").toString("utf8"),
  );
  assert.equal(bypassData.kbList[0].kcmc, "高等数学-v2");

  // Next normal request now serves refreshed v2 from cache!
  const postBypassHit = await callProxy("/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151");
  assert.equal(postBypassHit.headers.get("x-courselens-cache"), "HIT");
  assert.equal(upstreamHits.schedule, 2);
  const postBypassData = JSON.parse(
    Buffer.from((await postBypassHit.json()).bodyBase64, "base64").toString("utf8"),
  );
  assert.equal(postBypassData.kbList[0].kcmc, "高等数学-v2");

  // Header bypass works too
  scheduleVersion = 3;
  const headerBypass = await callProxy("/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151", {
    extraHeaders: { "X-CourseLens-Cache": "bypass" },
  });
  assert.equal(headerBypass.headers.get("x-courselens-cache"), "BYPASS");
  assert.equal(upstreamHits.schedule, 3);

  // 6. Course selection endpoints (xsxk/*) are NEVER cached, and selection write invalidates schedule & enrolled!
  const chosen1 = await callProxy("/jwglxt/xsxk/zzxkyzb_cxZzxkYzbChoosedDisplay.html?gnmkdm=N253512");
  const chosen2 = await callProxy("/jwglxt/xsxk/zzxkyzb_cxZzxkYzbChoosedDisplay.html?gnmkdm=N253512");
  assert.equal(chosen1.headers.get("x-courselens-cache"), "SKIP");
  assert.equal(chosen2.headers.get("x-courselens-cache"), "SKIP");
  assert.equal(upstreamHits.selectionChosen, 2, "Selection chosen display must NEVER be cached");

  await callProxy("/jwglxt/xkcx/xkmdcx_cxXkmdcxIndex.html?doType=query&gnmkdm=N255010");
  assert.equal(upstreamHits.enrolled, 1);

  // Execute course selection write -> invalidates schedule & enrolled, preserves grades
  const writePath = "/jwglxt/xsxk/zzxkyzbjk_xkBcZyZzxkYzb.html?gnmkdm=N253512";
  assert.equal((await callProxy(writePath, { confirmed: true })).status, 403);
  assert.equal((await callProxy(writePath, { selection: true })).status, 400);
  assert.equal(upstreamHits.selectionWrite, 0);
  const writeRes = await callProxy(writePath, {
    selection: true,
    confirmed: true,
    body: "jxb_ids=JXB1&kch_id=CS101",
  });
  assert.equal(writeRes.headers.get("x-courselens-cache"), "SKIP");
  assert.equal(upstreamHits.selectionWrite, 1);

  const schedAfterSelect = await callProxy("/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151");
  assert.equal(schedAfterSelect.headers.get("x-courselens-cache"), "MISS");
  assert.equal(upstreamHits.schedule, 4);

  const enrolledAfterSelect = await callProxy(
    "/jwglxt/xkcx/xkmdcx_cxXkmdcxIndex.html?doType=query&gnmkdm=N255010",
  );
  assert.equal(enrolledAfterSelect.headers.get("x-courselens-cache"), "MISS");
  assert.equal(upstreamHits.enrolled, 2);

  // Grades were NOT invalidated by course selection
  const gradeStillHit = await callProxy("/jwglxt/cjcx/cjcx_cxXsgrcj.html?doType=query&gnmkdm=N305005");
  assert.equal(gradeStillHit.headers.get("x-courselens-cache"), "HIT");
  assert.equal(upstreamHits.grades, 2);

  // 7. GET /v1/cache & DELETE /v1/cache management endpoints
  const statsRes = await worker.fetch(
    new Request("https://worker.example.dev/v1/cache", {
      headers: { Authorization: "Bearer cache-test-key" },
    }),
    env,
  );
  assert.equal(statsRes.status, 200);
  const statsJson = await statsRes.json();
  assert.equal(statsJson.ok, true);
  assert.equal(statsJson.enabled, true);
  assert.equal(statsJson.stats.entryCount, 3); // schedule + enrolled + grades
  assert.equal(statsJson.stats.l2Hits, 1);
  assert.equal(statsJson.stats.l1Hits, 3);
  assert.equal(statsJson.stats.hits, 4);
  assert.equal(statsJson.stats.bypasses, 2);

  // Clear only grades category
  const delGrades = await worker.fetch(
    new Request("https://worker.example.dev/v1/cache?category=grades", {
      method: "DELETE",
      headers: { Authorization: "Bearer cache-test-key" },
    }),
    env,
  );
  assert.equal(delGrades.status, 200);
  assert.equal((await delGrades.json()).clearedCount, 1);

  // Clear remaining via DELETE /v1/session
  const delSession = await worker.fetch(
    new Request("https://worker.example.dev/v1/session", {
      method: "DELETE",
      headers: { Authorization: "Bearer cache-test-key" },
    }),
    env,
  );
  assert.equal(delSession.status, 200);
  const statsAfterLogout = await (
    await worker.fetch(
      new Request("https://worker.example.dev/v1/cache", {
        headers: { Authorization: "Bearer cache-test-key" },
      }),
      env,
    )
  ).json();
  assert.equal(statsAfterLogout.stats.entryCount, 0);
});

test("Worker proxy cache enforces MAX_CACHE_ENTRIES LRU eviction and never caches non-200 or session-expired bodies", async (t) => {
  let hits = 0;
  let returnMode = "ok";

  const mockPortal = await startLocalMockServer((req, res) => {
    const reqUrl = new URL(req.url, "http://127.0.0.1");
    req.resume();
    req.on("end", () => {
      if (reqUrl.pathname === "/jwglxt/xtgl/index_cxYhxxIndex.html") {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end('<div class="infoContentTitle">LRU同学-20260002</div>');
        return;
      }
      hits += 1;
      if (returnMode === "500") {
        res.writeHead(500, { "Content-Type": "text/plain" });
        res.end("server error");
        return;
      }
      if (returnMode === "login-html") {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end('<html><body><form action="/jwglxt/xtgl/login_slogin.html"><input name="yhm"><input type="password" name="mm"></form></body></html>');
        return;
      }
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ kbList: [{ kcmc: `课程-${reqUrl.searchParams.get("i")}` }] }));
    });
  });
  t.after(() => mockPortal.close());

  let virtualNow = 1_790_000_000_000;
  const env = {
    COURSELENS_API_KEY: "lru-test-key",
    PORTAL_URL: `${mockPortal.origin}/jwglxt`,
    PORTAL_USERNAME: "20260002",
    PORTAL_COOKIES: "JSESSIONID=LRU_SEED",
    __ALLOW_LOOPBACK_FOR_TEST: true,
    __NOW_FN: () => virtualNow,
  };
  const harness = createDurableObjectHarness(env);
  env.SESSION_VAULT = harness.namespace;

  const fetchItem = (i) =>
    worker.fetch(
      new Request("https://worker.example.dev/v1/proxy", {
        method: "POST",
        headers: {
          Authorization: "Bearer lru-test-key",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          method: "POST",
          url: `${mockPortal.origin}/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151&i=${i}`,
          bodyBase64: bytesToBase64(new TextEncoder().encode(`xnm=2026&xqm=3&page=${i}`)),
        }),
      }),
      env,
    );

  // Non-200 responses must never be cached
  returnMode = "500";
  await fetchItem("err");
  await fetchItem("err");
  assert.equal(hits, 2, "HTTP 500 must never be cached");

  // Login-page HTML returned with HTTP 200 must never be cached
  returnMode = "login-html";
  const hitsBeforeLoginHtml = hits;
  await fetchItem("expired");
  await fetchItem("expired");
  assert.ok(hits >= hitsBeforeLoginHtml + 2, "Login HTML body must never be cached");

  // Fill past MAX_CACHE_ENTRIES -> LRU evicts oldest entries cleanly
  returnMode = "ok";
  for (let i = 0; i < MAX_CACHE_ENTRIES + 4; i += 1) {
    virtualNow += 1000;
    const res = await fetchItem(i);
    assert.equal(res.status, 200);
  }

  const stats = await (
    await worker.fetch(
      new Request("https://worker.example.dev/v1/cache", {
        headers: { Authorization: "Bearer lru-test-key" },
      }),
      env,
    )
  ).json();
  assert.equal(stats.stats.entryCount, MAX_CACHE_ENTRIES);
  assert.equal(stats.stats.evictions, 4);
});

test("Replacing a session fences delayed responses and scopes subsequent cache reads", { timeout: 5000 }, async (t) => {
  let releasePriorResponse;
  let priorRequested;
  const requested = new Promise((resolve) => { priorRequested = resolve; });
  const mock = await startLocalMockServer((req, res) => {
    const isNew = (req.headers.cookie || "").includes("NEW_ACCOUNT");
    const path = new URL(req.url, "http://127.0.0.1").pathname;
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    if (path.endsWith("/index_cxYhxxIndex.html")) {
      res.end(isNew ? '<div class="infoContentTitle">新账号-20260002</div>'
        : '<div class="infoContentTitle">旧账号-20260001</div>');
    } else if (path.endsWith("/cjcx_cxXsgrcj.html")) {
      res.setHeader("Content-Type", "application/json");
      if (isNew) {
        res.end('{"items":[{"name":"new-account"}]}');
      } else {
        releasePriorResponse = () => res.end('{"items":[{"name":"old-account"}]}');
        priorRequested();
      }
    } else {
      res.end("ok");
    }
  });
  t.after(() => mock.close());
  const env = {
    COURSELENS_API_KEY: "cache-rotation-key",
    PORTAL_URL: `${mock.origin}/jwglxt`,
    PORTAL_COOKIES: "JSESSIONID=OLD_ACCOUNT",
    __ALLOW_LOOPBACK_FOR_TEST: true,
  };
  const harness = createDurableObjectHarness(env);
  env.SESSION_VAULT = harness.namespace;
  const call = (path, body) => worker.fetch(new Request(`https://worker.example.dev${path}`, {
    method: "POST",
    headers: { Authorization: "Bearer cache-rotation-key", "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }), env);
  const grades = () => call("/v1/proxy", {
    method: "POST",
    url: `${env.PORTAL_URL}/cjcx/cjcx_cxXsgrcj.html?doType=query`,
  });

  const prior = grades();
  await requested;
  try {
    const pushed = await call("/v1/session/cookies", { cookies: "JSESSIONID=NEW_ACCOUNT" });
    assert.equal(pushed.status, 200);
  } finally {
    releasePriorResponse();
  }
  assert.equal((await prior).status, 401);
  const current = await grades();
  assert.equal(current.headers.get("x-courselens-cache"), "MISS");
  const cached = await grades();
  assert.equal(cached.headers.get("x-courselens-cache"), "HIT");
  assert.match(Buffer.from((await cached.json()).bodyBase64, "base64").toString(), /new-account/);
});

test("Redirected selection write returns 504 RESULT_UNKNOWN without replay and invalidates primed academic caches", async (t) => {
  const hits = {
    schedule: 0,
    enrolled: 0,
    progress: 0,
    grades: 0,
    dropWrite: 0,
    receipt: 0,
  };
  let dropped = false;

  const mockPortal = await startLocalMockServer((req, res) => {
    const reqUrl = new URL(req.url, "http://127.0.0.1");
    req.resume();
    req.on("end", () => {
      if (reqUrl.pathname === "/jwglxt/xtgl/index_cxYhxxIndex.html") {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end('<div class="infoContentTitle">退课缓存测试-20260003</div>');
        return;
      }
      if (reqUrl.pathname === "/jwglxt/kbcx/xskbcx_cxXsgrkb.html") {
        hits.schedule += 1;
        res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
        res.end(
          JSON.stringify({
            kbList: dropped ? [{ kcmc: "保留课程" }] : [{ kcmc: "保留课程" }, { kcmc: "待退课程" }],
          }),
        );
        return;
      }
      if (reqUrl.pathname === "/jwglxt/xkcx/xkmdcx_cxXkmdcxIndex.html") {
        hits.enrolled += 1;
        res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
        res.end(JSON.stringify({ items: dropped ? [{ kcmc: "保留课程" }] : [{ kcmc: "待退课程" }] }));
        return;
      }
      if (reqUrl.pathname === "/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html") {
        hits.progress += 1;
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end(dropped ? "<div>已修学分:12</div>" : "<div>已修学分:15</div>");
        return;
      }
      if (reqUrl.pathname === "/jwglxt/cjcx/cjcx_cxXsgrcj.html") {
        hits.grades += 1;
        res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
        res.end(JSON.stringify({ items: [{ kcmc: "线性代数", cj: "94" }] }));
        return;
      }
      if (reqUrl.pathname === "/jwglxt/xsxk/zzxkyzb_tuikBcZzxkYzb.html" && req.method === "POST") {
        hits.dropWrite += 1;
        // Portal commits the drop and redirects to a receipt page.
        dropped = true;
        res.writeHead(302, { Location: "/jwglxt/xsxk/drop_receipt.html" });
        res.end();
        return;
      }
      if (reqUrl.pathname === "/jwglxt/xsxk/drop_receipt.html") {
        hits.receipt += 1;
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end("receipt");
        return;
      }
      res.writeHead(404);
      res.end("not found");
    });
  });
  t.after(() => mockPortal.close());

  const env = {
    COURSELENS_API_KEY: "redirect-invalidation-key",
    PORTAL_URL: `${mockPortal.origin}/jwglxt`,
    PORTAL_USERNAME: "20260003",
    PORTAL_COOKIES: "JSESSIONID=DROP_CACHE_SID",
    __ALLOW_LOOPBACK_FOR_TEST: true,
  };
  const harness = createDurableObjectHarness(env);
  env.SESSION_VAULT = harness.namespace;

  const callProxy = (method, path, { body = null, selection = false, confirmed = false } = {}) =>
    worker.fetch(
      new Request(`https://worker.example.dev/v1/${selection ? "selection" : "proxy"}`, {
        method: "POST",
        headers: {
          Authorization: "Bearer redirect-invalidation-key",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          method,
          confirmed,
          url: `${mockPortal.origin}${path}`,
          ...(body !== null ? { bodyBase64: bytesToBase64(new TextEncoder().encode(body)) } : {}),
        }),
      }),
      env,
    );

  // 1. Prime schedule, enrolled, progress, and grades caches (L1 + encrypted L2)
  const sched1 = await callProxy("POST", "/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151", {
    body: "xnm=2026&xqm=3",
  });
  assert.equal(sched1.headers.get("x-courselens-cache"), "MISS");
  assert.match(Buffer.from((await sched1.json()).bodyBase64, "base64").toString("utf8"), /待退课程/);

  const schedHit = await callProxy("POST", "/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151", {
    body: "xnm=2026&xqm=3",
  });
  assert.equal(schedHit.headers.get("x-courselens-cache"), "HIT");
  assert.equal(hits.schedule, 1);

  await callProxy("POST", "/jwglxt/xkcx/xkmdcx_cxXkmdcxIndex.html?doType=query&gnmkdm=N255010", {
    body: "xnm=2026&xqm=3",
  });
  await callProxy("GET", "/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html?ver=new&gnmkdm=N105515");
  await callProxy("POST", "/jwglxt/cjcx/cjcx_cxXsgrcj.html?doType=query&gnmkdm=N305005", {
    body: "xnm=2026&xqm=3",
  });
  assert.equal(hits.enrolled, 1);
  assert.equal(hits.progress, 1);
  assert.equal(hits.grades, 1);

  // 2. Confirmed drop commits and redirects -> 504 RESULT_UNKNOWN, no replay, no redirect follow
  const dropRes = await callProxy("POST", "/jwglxt/xsxk/zzxkyzb_tuikBcZzxkYzb.html?gnmkdm=N253512", {
    selection: true,
    confirmed: true,
    body: "jxb_ids=JXB_DROP&kch_id=CS202",
  });
  assert.equal(dropRes.status, 504);
  assert.equal((await dropRes.json()).status, "RESULT_UNKNOWN");
  assert.equal(hits.dropWrite, 1, "Ambiguous redirected write must never be replayed");
  assert.equal(hits.receipt, 0, "Redirect target after selection write must not be followed");

  // 3. Evict DO to verify both L1 and persisted L2 caches were invalidated for schedule/enrolled/progress
  harness.evictAndRecreateVault();

  const schedAfterDrop = await callProxy("POST", "/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151", {
    body: "xnm=2026&xqm=3",
  });
  assert.equal(schedAfterDrop.headers.get("x-courselens-cache"), "MISS");
  assert.equal(hits.schedule, 2);
  const schedAfterDropText = Buffer.from((await schedAfterDrop.json()).bodyBase64, "base64").toString("utf8");
  assert.doesNotMatch(schedAfterDropText, /待退课程/);
  assert.match(schedAfterDropText, /保留课程/);

  const enrolledAfterDrop = await callProxy(
    "POST",
    "/jwglxt/xkcx/xkmdcx_cxXkmdcxIndex.html?doType=query&gnmkdm=N255010",
    { body: "xnm=2026&xqm=3" },
  );
  assert.equal(enrolledAfterDrop.headers.get("x-courselens-cache"), "MISS");
  assert.equal(hits.enrolled, 2);

  const progressAfterDrop = await callProxy(
    "GET",
    "/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html?ver=new&gnmkdm=N105515",
  );
  assert.equal(progressAfterDrop.headers.get("x-courselens-cache"), "MISS");
  assert.equal(hits.progress, 2);

  // 4. Unrelated grades cache remains intact in L2
  const gradesAfterDrop = await callProxy(
    "POST",
    "/jwglxt/cjcx/cjcx_cxXsgrcj.html?doType=query&gnmkdm=N305005",
    { body: "xnm=2026&xqm=3" },
  );
  assert.equal(gradesAfterDrop.headers.get("x-courselens-cache"), "HIT");
  assert.equal(hits.grades, 1);
});
