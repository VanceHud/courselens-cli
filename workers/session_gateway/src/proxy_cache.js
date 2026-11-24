/**
 * Dual-layer (DO RAM + AES-256-GCM encrypted DO SQLite) response cache for
 * `PortalSessionVault` (`/v1/proxy`).
 *
 * Security & correctness guarantees:
 * 1. Default-deny allowlist: only explicitly recognized read-only academic query
 *    endpoints are cacheable. All course selection/capacity/verification (`xsxk/*`),
 *    login/captcha, stateful ASP.NET WebForms (`__VIEWSTATE`), `followRedirects: false`,
 *    non-200, or session-expired responses are strictly NEVER cached.
 * 2. Differentiated per-category TTLs with env var overrides (set TTL=0 to disable).
 * 3. L2 persistence uses the caller's AES-256-GCM vault cipher so academic responses
 *    remain encrypted at rest across Durable Object hibernation/eviction.
 * 4. Bounded storage (max 512 KB/entry, 64 entries, 4 MB total) with lazy expiration
 *    and LRU eviction — zero background Durable Object alarms required.
 */

import { bytesToBase64 } from "./net_policy.js";

export const PROXY_CACHE_INDEX_KEY = "v1:pcache:index";
export const PROXY_CACHE_ENTRY_PREFIX = "v1:pcache:";
export const MAX_CACHE_ENTRY_BYTES = 512 * 1024;
export const MAX_CACHE_ENTRIES = 64;
export const MAX_CACHE_TOTAL_BYTES = 4 * 1024 * 1024;

export const CACHE_CATEGORIES = Object.freeze([
  "catalog",
  "schedule",
  "grades",
  "exams",
  "progress",
  "enrolled",
  "classrooms",
  "static",
]);

export const DEFAULT_CACHE_TTLS_SEC = Object.freeze({
  catalog: 1800, // 30m: home calendar / term metadata / menus
  schedule: 1800, // 30m: timetable & practical courses
  grades: 300, // 5m: grades & sub-items
  exams: 600, // 10m: exam schedule & seats
  progress: 3600, // 1h: degree audit & training plan courses
  enrolled: 600, // 10m: all-weather enrolled course roster (N255010)
  classrooms: 120, // 2m: empty classroom query results (N2155)
  static: 86400, // 24h: campus bell schedules & empty-classroom filter metadata
});

const VOLATILE_QUERY_PARAMS = new Set(["_", "nd", "timestamp"]);
const VOLATILE_FORM_PARAMS = new Set(["_search", "nd"]);

function decodeSmallUtf8(bytes) {
  if (!bytes || bytes.byteLength === 0 || bytes.byteLength > 64 * 1024) {
    return "";
  }
  try {
    return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
  } catch {
    return "";
  }
}

function hasStatefulWebFormsToken(bodyText) {
  if (!bodyText) return false;
  const lower = bodyText.toLowerCase();
  return (
    lower.includes("__viewstate") ||
    lower.includes("__eventvalidation") ||
    lower.includes("__eventtarget")
  );
}

/**
 * Classifies a `/v1/proxy` request into a read-only cache category or denies caching.
 * Also reports which cache categories must be invalidated after a mutating request completes.
 */
export function classifyProxyCacheRequest({
  method,
  url,
  bodyBytes = null,
  followRedirects = true,
  cacheConfig = null,
}) {
  const methodUpper = String(method || "GET").toUpperCase();
  let parsed;
  try {
    parsed = new URL(String(url || ""));
  } catch {
    return { cacheable: false, category: "none", ttlMs: 0, invalidates: [] };
  }

  const pathLower = (parsed.pathname || "").toLowerCase();
  const doTypeLower = (parsed.searchParams.get("doType") || "").trim().toLowerCase();

  // Course selection / drop writes MUST never be cached and invalidate schedule/enrolled/progress.
  if (
    pathLower.includes("/xsxk/") &&
    (pathLower.includes("xkbc") ||
      pathLower.includes("tuikbc") ||
      pathLower.includes("tuike") ||
      pathLower.includes("xksave") ||
      pathLower.includes("selectcourse") ||
      pathLower.includes("dropcourse"))
  ) {
    return {
      cacheable: false,
      category: "none",
      ttlMs: 0,
      invalidates: ["schedule", "enrolled", "progress"],
    };
  }

  // Hard-deny: all course selection (`xsxk/*`), auth/login/captcha, non-redirect-following probes.
  if (
    pathLower.includes("/xsxk/") ||
    pathLower.includes("login") ||
    pathLower.includes("logout") ||
    pathLower.includes("kaptcha") ||
    pathLower.includes("captcha") ||
    pathLower.includes("verifycode") ||
    pathLower.includes("publickey") ||
    followRedirects === false
  ) {
    return { cacheable: false, category: "none", ttlMs: 0, invalidates: [] };
  }

  if (!cacheConfig || cacheConfig.enabled === false) {
    return { cacheable: false, category: "none", ttlMs: 0, invalidates: [] };
  }

  // Hard-deny stateful ASP.NET WebForms POST postbacks (ViewState tokens vary per session/page).
  if (methodUpper === "POST") {
    const bodyText = decodeSmallUtf8(bodyBytes);
    if (hasStatefulWebFormsToken(bodyText)) {
      return { cacheable: false, category: "none", ttlMs: 0, invalidates: [] };
    }
  }

  let category = "none";

  // 1. Static metadata (campus bell schedules & empty-classroom filter dropdowns)
  if (
    pathLower.endsWith("/kbcx/xskbcx_cxrjc.html") ||
    (methodUpper === "GET" &&
      pathLower.endsWith("/cdjy/cdjy_cxkxcdlb.html") &&
      doTypeLower !== "query")
  ) {
    category = "static";
  }
  // 2. Empty classroom query results (N2155)
  else if (
    methodUpper === "POST" &&
    pathLower.endsWith("/cdjy/cdjy_cxkxcdlb.html") &&
    doTypeLower === "query"
  ) {
    category = "classrooms";
  }
  // 3. Timetable / schedule queries
  else if (
    pathLower.endsWith("/kbcx/xskbcx_cxxsgrkb.html") ||
    pathLower.endsWith("/kbcx/xskbcx_cxxskb.html") ||
    pathLower.endsWith("/xskb/xskb_list.do") ||
    (methodUpper === "POST" && pathLower.endsWith("/kbcx/xskbcx_cxxskbcxindex.html"))
  ) {
    category = "schedule";
  }
  // 4. Home calendar / menu / identity card / term catalog
  else if (
    pathLower.endsWith("/xtgl/index_initmenu.html") ||
    pathLower.endsWith("/xtgl/index_cxareaone.html") ||
    pathLower.endsWith("/xtgl/index_cxareafive.html") ||
    pathLower.endsWith("/xtgl/index_cxareasix.html") ||
    pathLower.endsWith("/xtgl/index_cxyhxxindex.html") ||
    (methodUpper === "GET" && pathLower.endsWith("/kbcx/xskbcx_cxxskbcxindex.html")) ||
    (methodUpper === "GET" &&
      (pathLower.endsWith("/framework/xsmain.jsp") ||
        pathLower.endsWith("/framework/xsmainv.htmlx") ||
        pathLower.endsWith("/framework/xsmainv_new.htmlx") ||
        pathLower.endsWith("/xs_main.aspx")))
  ) {
    category = "catalog";
  }
  // 5. Grades & grade sub-items
  else if (
    pathLower.endsWith("/cjcx/cjcx_cxxsgrcj.html") ||
    pathLower.endsWith("/cjcx/cjcx_cxdgxscj.html") ||
    pathLower.endsWith("/cjcx/cjcx_cxxskccjlist.html") ||
    pathLower.endsWith("/cjcx/cjcx_cxxsxmcjlist.html") ||
    pathLower.endsWith("/cjcx/cjcx_cxcjxqgjh.html") ||
    pathLower.endsWith("/kscj/cjcx_list") ||
    (methodUpper === "GET" && pathLower.endsWith("/kscj/cjcx_frm"))
  ) {
    category = "grades";
  }
  // 6. Exam schedules & seats
  else if (
    pathLower.endsWith("/kwgl/kscx_cxxsksxxindex.html") ||
    pathLower.endsWith("/xsks/xsksap_list") ||
    (methodUpper === "GET" && pathLower.endsWith("/xsks/xsksap_query"))
  ) {
    category = "exams";
  }
  // 7. Academic progress & degree audit plan courses (N105515)
  else if (
    pathLower.endsWith("/xsxy/xsxyqk_cxxsxyqkindex.html") ||
    pathLower.endsWith("/xsxy/xsxyqk_cxjxzxjhxfyqkcxx.html")
  ) {
    category = "progress";
  }
  // 8. All-weather enrolled courses roster (N255010)
  else if (pathLower.endsWith("/xkcx/xkmdcx_cxxkmdcxindex.html")) {
    category = "enrolled";
  }

  if (category === "none") {
    return { cacheable: false, category: "none", ttlMs: 0, invalidates: [] };
  }

  const ttls = cacheConfig.ttls || DEFAULT_CACHE_TTLS_SEC;
  const ttlSec = Number.isFinite(Number(ttls[category]))
    ? Math.max(0, Math.floor(Number(ttls[category])))
    : (DEFAULT_CACHE_TTLS_SEC[category] || 0);

  if (ttlSec <= 0) {
    return { cacheable: false, category, ttlMs: 0, invalidates: [] };
  }

  return {
    cacheable: true,
    category,
    ttlMs: ttlSec * 1000,
    invalidates: [],
  };
}

function canonicalizeUrl(rawUrl) {
  const parsed = new URL(String(rawUrl));
  const pairs = [];
  for (const [k, v] of parsed.searchParams.entries()) {
    if (VOLATILE_QUERY_PARAMS.has(k.toLowerCase())) continue;
    pairs.push([k, v]);
  }
  pairs.sort((a, b) => (a[0] === b[0] ? a[1].localeCompare(b[1]) : a[0].localeCompare(b[0])));
  const qs = pairs
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");
  return `${parsed.origin}${parsed.pathname}${qs ? `?${qs}` : ""}`;
}

function canonicalizeBody(bodyBytes) {
  if (!bodyBytes || bodyBytes.byteLength === 0) return "";
  if (bodyBytes.byteLength <= 64 * 1024 && !bodyBytes.includes(0)) {
    const text = new TextDecoder("utf-8", { fatal: false }).decode(bodyBytes);
    // Treat typical form-urlencoded bodies canonically so field order differences still share cache.
    if (text.includes("=") && !text.trim().startsWith("{") && !text.trim().startsWith("[")) {
      const params = new URLSearchParams(text);
      const pairs = [];
      for (const [k, v] of params.entries()) {
        const lower = k.toLowerCase();
        if (VOLATILE_FORM_PARAMS.has(lower)) continue;
        // Strip dynamic epoch-ms timestamps while keeping static `time=0`.
        if (lower === "time" && /^\d{12,}$/.test(v.trim())) continue;
        pairs.push([k, v]);
      }
      pairs.sort((a, b) =>
        a[0] === b[0] ? a[1].localeCompare(b[1]) : a[0].localeCompare(b[0]),
      );
      return pairs
        .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
        .join("&");
    }
  }
  return `b64:${bytesToBase64(bodyBytes)}`;
}

/**
 * Computes a deterministic 128-bit (32 hex chars) SHA-256 cache key for a proxy request.
 */
export async function computeProxyCacheKey({ method, url, bodyBytes = null, scope = "" }) {
  const methodUpper = String(method || "GET").toUpperCase();
  const canonUrl = canonicalizeUrl(url);
  const canonBody = canonicalizeBody(bodyBytes);
  const material = `${scope}\n${methodUpper}\n${canonUrl}\n${canonBody}`;
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(material)),
  );
  let hex = "";
  for (let i = 0; i < 16; i += 1) {
    hex += digest[i].toString(16).padStart(2, "0");
  }
  return hex;
}

export function sanitizeCachedHeaders(headers = {}) {
  const clean = {};
  if (!headers || typeof headers !== "object") return clean;
  for (const [k, v] of Object.entries(headers)) {
    if (k.toLowerCase() === "set-cookie") continue;
    clean[k] = Array.isArray(v) ? v.map(String) : [String(v)];
  }
  return clean;
}

/**
 * Dual-layer DO proxy cache:
 * - L1: fast in-memory Map (`<1ms`, 0 SQLite I/O)
 * - L2: AES-256-GCM encrypted DO SQLite storage (survives DO hibernation/eviction)
 */
export class ProxyResponseCache {
  constructor({ storage, encryptFn, decryptFn, getEpochFn }) {
    this._storage = storage;
    this._encryptFn = encryptFn;
    this._decryptFn = decryptFn;
    this._getEpochFn = getEpochFn;

    this._l1 = new Map();
    this._index = new Map();
    this._indexHydrated = false;
    this._stats = {
      hits: 0,
      l1Hits: 0,
      l2Hits: 0,
      misses: 0,
      bypasses: 0,
      evictions: 0,
    };
  }

  async ensureIndexHydrated() {
    if (this._indexHydrated) return;
    const saved = await this._storage.get(PROXY_CACHE_INDEX_KEY);
    this._index.clear();
    if (saved && typeof saved === "object" && Array.isArray(saved.entries)) {
      for (const item of saved.entries) {
        if (
          item &&
          typeof item === "object" &&
          typeof item.key === "string" &&
          item.key.length > 0 &&
          Number.isFinite(item.cachedAtMs) &&
          Number.isFinite(item.expiresAtMs)
        ) {
          this._index.set(item.key, {
            key: item.key,
            category: String(item.category || "unknown"),
            cachedAtMs: Number(item.cachedAtMs),
            expiresAtMs: Number(item.expiresAtMs),
            approxBytes: Math.max(0, Number(item.approxBytes) || 0),
            lastAccessMs: Number(item.lastAccessMs) || Number(item.cachedAtMs),
          });
        }
      }
    }
    this._indexHydrated = true;
  }

  async _persistIndex(expectedEpoch) {
    if (this._getEpochFn() !== expectedEpoch) return false;
    const entries = Array.from(this._index.values());
    if (entries.length === 0) {
      await this._storage.delete(PROXY_CACHE_INDEX_KEY);
    } else {
      await this._storage.put(PROXY_CACHE_INDEX_KEY, { v: 1, entries });
    }
    return true;
  }

  recordMiss() {
    this._stats.misses += 1;
  }

  recordBypass() {
    this._stats.bypasses += 1;
  }

  recordInFlightHit() {
    this._stats.hits += 1;
    this._stats.l1Hits += 1;
  }

  async get(cacheKey, config, nowMs) {
    await this.ensureIndexHydrated();
    const epoch = this._getEpochFn();

    // 1. Check L1 RAM Map
    const l1Entry = this._l1.get(cacheKey);
    if (l1Entry) {
      if (nowMs >= l1Entry.cachedAtMs && nowMs < l1Entry.expiresAtMs) {
        l1Entry.lastAccessMs = nowMs;
        const idxMeta = this._index.get(cacheKey);
        if (idxMeta) idxMeta.lastAccessMs = nowMs;
        this._stats.hits += 1;
        this._stats.l1Hits += 1;
        return {
          hit: true,
          layer: "L1",
          entry: l1Entry,
          ageSec: Math.max(0, Math.floor((nowMs - l1Entry.cachedAtMs) / 1000)),
          ttlSec: Math.max(0, Math.floor((l1Entry.expiresAtMs - l1Entry.cachedAtMs) / 1000)),
        };
      }
      // Expired in L1: evict from L1 + L2
      this._l1.delete(cacheKey);
      if (this._index.delete(cacheKey)) {
        await this._storage.delete(`${PROXY_CACHE_ENTRY_PREFIX}${cacheKey}`);
        await this._persistIndex(epoch);
      }
      return { hit: false };
    }

    // 2. Check L2 encrypted DO storage via index
    const meta = this._index.get(cacheKey);
    if (!meta) return { hit: false };

    if (nowMs < meta.cachedAtMs || nowMs >= meta.expiresAtMs) {
      this._index.delete(cacheKey);
      await this._storage.delete(`${PROXY_CACHE_ENTRY_PREFIX}${cacheKey}`);
      await this._persistIndex(epoch);
      return { hit: false };
    }

    const encrypted = await this._storage.get(`${PROXY_CACHE_ENTRY_PREFIX}${cacheKey}`);
    if (this._getEpochFn() !== epoch) return { hit: false };

    const decrypted = await this._decryptFn(encrypted, config);
    if (
      !decrypted ||
      decrypted.status !== "ok" ||
      !decrypted.value ||
      typeof decrypted.value !== "object" ||
      typeof decrypted.value.bodyBase64 !== "string"
    ) {
      this._index.delete(cacheKey);
      await this._storage.delete(`${PROXY_CACHE_ENTRY_PREFIX}${cacheKey}`);
      await this._persistIndex(epoch);
      return { hit: false };
    }

    const entry = {
      key: cacheKey,
      category: String(decrypted.value.category || meta.category),
      status: Number(decrypted.value.status) || 200,
      finalUrl: String(decrypted.value.finalUrl || ""),
      headers: sanitizeCachedHeaders(decrypted.value.headers),
      bodyBase64: decrypted.value.bodyBase64,
      cachedAtMs: Number(decrypted.value.cachedAtMs) || meta.cachedAtMs,
      expiresAtMs: Number(decrypted.value.expiresAtMs) || meta.expiresAtMs,
      approxBytes: Number(decrypted.value.approxBytes) || meta.approxBytes,
      lastAccessMs: nowMs,
    };

    if (nowMs < entry.cachedAtMs || nowMs >= entry.expiresAtMs) {
      this._index.delete(cacheKey);
      await this._storage.delete(`${PROXY_CACHE_ENTRY_PREFIX}${cacheKey}`);
      await this._persistIndex(epoch);
      return { hit: false };
    }

    this._l1.set(cacheKey, entry);
    meta.lastAccessMs = nowMs;
    this._stats.hits += 1;
    this._stats.l2Hits += 1;
    return {
      hit: true,
      layer: "L2",
      entry,
      ageSec: Math.max(0, Math.floor((nowMs - entry.cachedAtMs) / 1000)),
      ttlSec: Math.max(0, Math.floor((entry.expiresAtMs - entry.cachedAtMs) / 1000)),
    };
  }

  async set(
    cacheKey,
    { category, status, finalUrl, headers, bodyBase64, rawByteLength, ttlMs },
    config,
    nowMs,
    expectedEpoch,
  ) {
    if (this._getEpochFn() !== expectedEpoch) return false;
    if (!Number.isFinite(ttlMs) || ttlMs <= 0) return false;
    const approxBytes = Number.isFinite(rawByteLength)
      ? Math.max(0, Math.floor(rawByteLength))
      : Math.floor((bodyBase64 || "").length * 0.75);
    if (approxBytes <= 0 || approxBytes > MAX_CACHE_ENTRY_BYTES) {
      return false;
    }

    await this.ensureIndexHydrated();
    if (this._getEpochFn() !== expectedEpoch) return false;

    const cleanHeaders = sanitizeCachedHeaders(headers);
    const record = {
      key: cacheKey,
      category,
      status,
      finalUrl,
      headers: cleanHeaders,
      bodyBase64,
      cachedAtMs: nowMs,
      expiresAtMs: nowMs + ttlMs,
      approxBytes,
      lastAccessMs: nowMs,
    };

    const encrypted = await this._encryptFn(record, config);
    if (this._getEpochFn() !== expectedEpoch) return false;

    // 1. Prune expired entries first
    const keysToDelete = [];
    for (const [k, meta] of this._index.entries()) {
      if (k !== cacheKey && (nowMs < meta.cachedAtMs || nowMs >= meta.expiresAtMs)) {
        keysToDelete.push(k);
      }
    }
    for (const k of keysToDelete) {
      this._index.delete(k);
      this._l1.delete(k);
      await this._storage.delete(`${PROXY_CACHE_ENTRY_PREFIX}${k}`);
    }

    // 2. Enforce entry count & total bytes budget via LRU eviction
    let currentBytes = 0;
    for (const [k, meta] of this._index.entries()) {
      if (k !== cacheKey) currentBytes += meta.approxBytes;
    }
    const candidates = Array.from(this._index.values())
      .filter((m) => m.key !== cacheKey)
      .sort((a, b) => (a.lastAccessMs || a.cachedAtMs) - (b.lastAccessMs || b.cachedAtMs));

    let effectiveCount = candidates.length;
    for (const victim of candidates) {
      if (
        effectiveCount < MAX_CACHE_ENTRIES &&
        currentBytes + approxBytes <= MAX_CACHE_TOTAL_BYTES
      ) {
        break;
      }
      this._index.delete(victim.key);
      this._l1.delete(victim.key);
      await this._storage.delete(`${PROXY_CACHE_ENTRY_PREFIX}${victim.key}`);
      currentBytes -= victim.approxBytes;
      effectiveCount -= 1;
      this._stats.evictions += 1;
    }

    if (this._getEpochFn() !== expectedEpoch) return false;

    await this._storage.put(`${PROXY_CACHE_ENTRY_PREFIX}${cacheKey}`, encrypted);
    this._l1.set(cacheKey, record);
    this._index.set(cacheKey, {
      key: cacheKey,
      category,
      cachedAtMs: record.cachedAtMs,
      expiresAtMs: record.expiresAtMs,
      approxBytes,
      lastAccessMs: nowMs,
    });
    await this._persistIndex(expectedEpoch);
    return true;
  }

  async invalidateCategories(categories = []) {
    if (!Array.isArray(categories) || categories.length === 0) return 0;
    await this.ensureIndexHydrated();
    const targetSet = new Set(categories.map((c) => String(c || "").trim().toLowerCase()));
    const epoch = this._getEpochFn();
    let cleared = 0;

    for (const [key, meta] of Array.from(this._index.entries())) {
      if (targetSet.has(String(meta.category || "").toLowerCase())) {
        this._index.delete(key);
        this._l1.delete(key);
        await this._storage.delete(`${PROXY_CACHE_ENTRY_PREFIX}${key}`);
        cleared += 1;
      }
    }
    for (const [key, entry] of Array.from(this._l1.entries())) {
      if (targetSet.has(String(entry.category || "").toLowerCase())) {
        this._l1.delete(key);
      }
    }
    if (cleared > 0) {
      await this._persistIndex(epoch);
    }
    return cleared;
  }

  async clearAll() {
    await this.ensureIndexHydrated();
    const keys = Array.from(this._index.keys());
    const cleared = keys.length;
    this._l1.clear();
    this._index.clear();
    for (const key of keys) {
      await this._storage.delete(`${PROXY_CACHE_ENTRY_PREFIX}${key}`);
    }
    await this._storage.delete(PROXY_CACHE_INDEX_KEY);
    return cleared;
  }

  async getStatsPayload(config, nowMs) {
    await this.ensureIndexHydrated();
    const ttls = (config && config.cache && config.cache.ttls) || DEFAULT_CACHE_TTLS_SEC;
    const enabled = Boolean(config && config.cache && config.cache.enabled !== false);

    const byCategory = new Map();
    for (const cat of CACHE_CATEGORIES) {
      byCategory.set(cat, {
        category: cat,
        ttlSec: Number.isFinite(Number(ttls[cat]))
          ? Math.max(0, Math.floor(Number(ttls[cat])))
          : (DEFAULT_CACHE_TTLS_SEC[cat] || 0),
        activeEntries: 0,
        bytes: 0,
      });
    }

    let entryCount = 0;
    let totalBytes = 0;
    for (const meta of this._index.values()) {
      if (nowMs < meta.cachedAtMs || nowMs >= meta.expiresAtMs) continue;
      entryCount += 1;
      totalBytes += meta.approxBytes;
      const bucket = byCategory.get(meta.category);
      if (bucket) {
        bucket.activeEntries += 1;
        bucket.bytes += meta.approxBytes;
      }
    }

    return {
      ok: true,
      enabled,
      limits: {
        maxEntryBytes: MAX_CACHE_ENTRY_BYTES,
        maxEntries: MAX_CACHE_ENTRIES,
        maxTotalBytes: MAX_CACHE_TOTAL_BYTES,
      },
      stats: {
        entryCount,
        totalBytes,
        l1Entries: this._l1.size,
        hits: this._stats.hits,
        l1Hits: this._stats.l1Hits,
        l2Hits: this._stats.l2Hits,
        misses: this._stats.misses,
        bypasses: this._stats.bypasses,
        evictions: this._stats.evictions,
      },
      categories: Array.from(byCategory.values()),
    };
  }
}
