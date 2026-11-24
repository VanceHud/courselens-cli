/**
 * Pure JavaScript university portal login, session verification, HostPolicy,
 * SSRF protection, and multi-hop upstream transport for Cloudflare Workers.
 */

import { ServerCookieJar } from "./cookie_jar.js";
import {
  PortalProtocolError,
  base64ToBytes,
  bytesToBase64,
  isHostAllowed,
  isPrivateOrLoopbackHost,
  upgradeSameHostHttpRedirect,
} from "./net_policy.js";

export {
  PortalProtocolError,
  base64ToBytes,
  bytesToBase64,
  isHostAllowed,
  isPrivateOrLoopbackHost,
  upgradeSameHostHttpRedirect,
};

export const MAX_REDIRECTS = 12;
export const MAX_UPSTREAM_RESPONSE_BYTES = 16 * 1024 * 1024;
export const BLOCKED_REDIRECT_HEADER = "X-CourseLens-Blocked-Redirect";
export const DEFAULT_USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const STRIPPED_CLIENT_HEADERS = new Set([
  "cookie",
  "host",
  "content-length",
  "authorization",
  "x-courselens-key",
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "forwarded",
  "x-forwarded-for",
  "x-forwarded-host",
  "x-forwarded-proto",
  "x-real-ip",
]);

export function trimTrailingSlash(str) {
  let s = String(str || "").trim();
  while (s.length > 1 && s.endsWith("/")) {
    s = s.slice(0, -1);
  }
  return s;
}

export function normalizePortalUrl(raw, label = "PORTAL_URL") {
  const s = String(raw || "").trim();
  if (!s) return "";
  let parsed;
  try {
    parsed = new URL(s);
  } catch {
    throw new PortalProtocolError("CONFIG_ERROR", `${label} 不是合法的 http(s) URL`, 500);
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new PortalProtocolError("CONFIG_ERROR", `${label} 仅支持 http:// 或 https:// 协议`, 500);
  }
  if (parsed.username || parsed.password) {
    throw new PortalProtocolError("CONFIG_ERROR", `${label} 严禁包含内嵌 userinfo 字段`, 500);
  }
  parsed.hash = "";
  parsed.search = "";
  const path = parsed.pathname || "";
  const knownSuffixes = [
    "/xtgl/login_slogin.html",
    "/xtgl/index_initMenu.html",
    "/xk/LoginToXk",
    "/default2.aspx",
  ];
  for (const sfx of knownSuffixes) {
    if (path.toLowerCase().endsWith(sfx.toLowerCase())) {
      parsed.pathname = path.slice(0, path.length - sfx.length) || "/";
      break;
    }
  }
  return trimTrailingSlash(parsed.toString());
}

function normalizeAllowedHostEntry(rawItem) {
  const trimmed = String(rawItem || "").trim();
  if (!trimmed) return null;
  if (trimmed.includes("*") || trimmed.includes("@")) {
    throw new PortalProtocolError(
      "CONFIG_ERROR",
      "ALLOWED_HOSTS 严禁使用通配符或包含 userinfo 字段",
      500,
    );
  }
  const hasExplicitScheme = trimmed.includes("://");
  let parsed;
  try {
    parsed = new URL(hasExplicitScheme ? trimmed : `https://${trimmed}`);
  } catch {
    throw new PortalProtocolError("CONFIG_ERROR", "ALLOWED_HOSTS 包含格式非法的域名或地址", 500);
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new PortalProtocolError("CONFIG_ERROR", "ALLOWED_HOSTS 仅支持 http:// 或 https:// 协议", 500);
  }
  if (
    parsed.username ||
    parsed.password ||
    (parsed.pathname && parsed.pathname !== "/") ||
    parsed.search ||
    parsed.hash
  ) {
    throw new PortalProtocolError(
      "CONFIG_ERROR",
      "ALLOWED_HOSTS 仅允许填写纯主机名或带协议/端口的 Origin（严禁附带路径或查询参数）",
      500,
    );
  }
  const cleanHost = parsed.hostname.replace(/\.+$/, "").toLowerCase();
  if (!cleanHost) {
    throw new PortalProtocolError("CONFIG_ERROR", "ALLOWED_HOSTS 包含空主机名", 500);
  }
  const formattedHost = cleanHost.includes(":") && !cleanHost.startsWith("[")
    ? `[${cleanHost}]`
    : cleanHost;
  if (hasExplicitScheme) {
    return {
      entry: `${parsed.protocol}//${formattedHost}${parsed.port ? `:${parsed.port}` : ""}`,
      isHttp: parsed.protocol === "http:",
    };
  }
  return {
    entry: `${formattedHost}${parsed.port ? `:${parsed.port}` : ""}`,
    isHttp: false,
  };
}

export function parsePortalEnvConfig(env = {}) {
  const portalUrl = normalizePortalUrl(env.PORTAL_URL || "", "PORTAL_URL");
  if (!portalUrl) {
    throw new PortalProtocolError(
      "CONFIG_ERROR",
      "Worker 尚未配置 PORTAL_URL 环境变量或 Secret",
      500,
    );
  }
  const casUrl = env.PORTAL_CAS_URL
    ? normalizePortalUrl(env.PORTAL_CAS_URL, "PORTAL_CAS_URL")
    : "";
  const username = String(env.PORTAL_USERNAME || "").trim();
  const rawPassword = String(env.PORTAL_PASSWORD || "");
  const password =
    rawPassword.trim().toUpperCase() === "COOKIE_ONLY" ? "" : rawPassword;
  const seedCookies = String(env.PORTAL_COOKIES || "").trim();
  const hasPasswordAuth = Boolean(username && password);
  const hasStaticCredentials = Boolean(hasPasswordAuth || seedCookies);

  const rawSys = String(env.PORTAL_SYSTEM || "auto").trim();
  const upperSys = rawSys.toUpperCase();
  const system = ["ZF", "ZF_OLD", "QZ", "QZ_OLD"].includes(upperSys)
    ? upperSys
    : "auto";

  const portalParsed = new URL(portalUrl);
  const hostLower = portalParsed.hostname.replace(/\.+$/, "").toLowerCase();
  const isQust =
    hostLower === "jwglxt.qust.edu.cn" ||
    hostLower === "jwglxt2.qust.edu.cn" ||
    hostLower.endsWith(".qust.edu.cn");

  const schoolId = String(env.SCHOOL_ID || "").trim() || (isQust ? "qust" : deriveSchoolId(hostLower));
  const schoolName =
    String(env.SCHOOL_NAME || "").trim() || (isQust ? "青岛科技大学" : schoolId.toUpperCase());

  const hostSet = new Set();
  const formatUrlOriginEntry = (u) => {
    const clean = u.hostname.replace(/\.+$/, "").toLowerCase();
    const hostPart = clean.includes(":") && !clean.startsWith("[") ? `[${clean}]` : clean;
    return `${u.protocol}//${hostPart}${u.port ? `:${u.port}` : ""}`;
  };
  hostSet.add(formatUrlOriginEntry(portalParsed));

  if (hostLower === "jwglxt.qust.edu.cn" || hostLower === "jwglxt2.qust.edu.cn") {
    hostSet.add(`${portalParsed.protocol}//jwglxt.qust.edu.cn`);
    hostSet.add(`${portalParsed.protocol}//jwglxt2.qust.edu.cn`);
  }

  let requireSecure = portalParsed.protocol === "https:";
  if (casUrl) {
    const casParsed = new URL(casUrl);
    hostSet.add(formatUrlOriginEntry(casParsed));
    if (casParsed.protocol !== "https:") requireSecure = false;
  }

  const rawExtraHosts = String(env.ALLOWED_HOSTS || "").trim();
  if (rawExtraHosts) {
    for (const part of rawExtraHosts.split(",")) {
      const normalized = normalizeAllowedHostEntry(part);
      if (!normalized) continue;
      if (normalized.isHttp) requireSecure = false;
      hostSet.add(normalized.entry);
    }
  }

  // Default 0 = lazy keep-alive mode (zero background Durable Object alarms while idle).
  const keepaliveSec = parseNonNegativeInt(env.KEEPALIVE_INTERVAL_SEC, 0);
  const keepaliveMaxIdleSec = parseNonNegativeInt(env.KEEPALIVE_MAX_IDLE_SEC, 86400);
  const sessionVerifyTtlSec = parseNonNegativeInt(env.SESSION_VERIFY_TTL_SEC, 120);

  const proxyCacheEnabled = parseBoolFlag(env.PROXY_CACHE_ENABLED, true);
  const cacheTtls = {
    catalog: parseNonNegativeInt(env.CACHE_TTL_CATALOG_SEC, 1800),
    schedule: parseNonNegativeInt(env.CACHE_TTL_SCHEDULE_SEC, 1800),
    grades: parseNonNegativeInt(env.CACHE_TTL_GRADES_SEC, 300),
    exams: parseNonNegativeInt(env.CACHE_TTL_EXAMS_SEC, 600),
    progress: parseNonNegativeInt(env.CACHE_TTL_PROGRESS_SEC, 3600),
    enrolled: parseNonNegativeInt(env.CACHE_TTL_ENROLLED_SEC, 600),
    classrooms: parseNonNegativeInt(env.CACHE_TTL_CLASSROOMS_SEC, 120),
    static: parseNonNegativeInt(env.CACHE_TTL_STATIC_SEC, 86400),
  };

  return {
    portalUrl,
    casUrl,
    system,
    username,
    password,
    seedCookies,
    hasPasswordAuth,
    hasStaticCredentials,
    schoolId,
    schoolName,
    allowedHosts: Array.from(hostSet),
    requireSecure,
    keepaliveMs: keepaliveSec * 1000,
    keepaliveMaxIdleMs: keepaliveMaxIdleSec * 1000,
    sessionVerifyTtlMs: sessionVerifyTtlSec * 1000,
    cache: {
      enabled: proxyCacheEnabled,
      ttls: cacheTtls,
    },
  };
}

function parseNonNegativeInt(raw, fallback) {
  if (raw === undefined || raw === null || String(raw).trim() === "") {
    return fallback;
  }
  const parsed = Number.parseInt(String(raw).trim(), 10);
  if (Number.isNaN(parsed) || parsed < 0) return fallback;
  return parsed;
}

function parseBoolFlag(raw, fallback) {
  if (raw === undefined || raw === null || String(raw).trim() === "") {
    return fallback;
  }
  const lower = String(raw).trim().toLowerCase();
  if (["0", "false", "no", "off"].includes(lower)) return false;
  if (["1", "true", "yes", "on"].includes(lower)) return true;
  return fallback;
}

function deriveSchoolId(hostname) {
  const parts = hostname.split(".").filter(Boolean);
  const eduIdx = parts.indexOf("edu");
  if (eduIdx > 0) return parts[eduIdx - 1];
  if (parts.length >= 2) return parts[parts.length - 2];
  return parts[0] || "custom";
}

export async function computeConfigFingerprint(config) {
  const material = JSON.stringify([
    config.portalUrl,
    config.casUrl,
    config.system,
    config.username,
    config.password,
    config.seedCookies,
  ]);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(material));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export async function readBoundedResponseBytes(
  response,
  maxBytes = MAX_UPSTREAM_RESPONSE_BYTES,
) {
  const clHeader = response.headers && typeof response.headers.get === "function"
    ? response.headers.get("content-length")
    : null;
  if (clHeader) {
    const declared = Number.parseInt(clHeader, 10);
    if (Number.isFinite(declared) && declared > maxBytes) {
      if (response.body && typeof response.body.cancel === "function") {
        try {
          await response.body.cancel();
        } catch {
          // Ignore cancel error.
        }
      }
      throw new PortalProtocolError(
        "NETWORK_ERROR",
        `教务上游响应体超过安全大小上限（${maxBytes} bytes）`,
        502,
      );
    }
  }

  if (!response.body || typeof response.body.getReader !== "function") {
    const buf = new Uint8Array(await response.arrayBuffer());
    if (buf.byteLength > maxBytes) {
      throw new PortalProtocolError(
        "NETWORK_ERROR",
        `教务上游响应体超过安全大小上限（${maxBytes} bytes）`,
        502,
      );
    }
    return buf;
  }

  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value && value.byteLength > 0) {
        total += value.byteLength;
        if (total > maxBytes) {
          try {
            await reader.cancel();
          } catch {
            // Ignore cancel error.
          }
          throw new PortalProtocolError(
            "NETWORK_ERROR",
            `教务上游响应体超过安全大小上限（${maxBytes} bytes）`,
            502,
          );
        }
        chunks.push(value);
      }
    }
  } finally {
    try {
      reader.releaseLock();
    } catch {
      // Ignore release error.
    }
  }

  if (chunks.length === 0) return new Uint8Array(0);
  if (chunks.length === 1) return chunks[0];
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    merged.set(c, offset);
    offset += c.byteLength;
  }
  return merged;
}

function serializeHeadersWithoutCookies(headers) {
  const out = {};
  headers.forEach((value, key) => {
    if (key.toLowerCase() === "set-cookie") return;
    out[key] = [value];
  });
  return out;
}

export function firstHeaderValue(headers, targetLower) {
  if (!headers || typeof headers !== "object") return "";
  for (const [k, v] of Object.entries(headers)) {
    if (k.toLowerCase() === targetLower) {
      if (Array.isArray(v) && v.length > 0) return String(v[0]);
      if (typeof v === "string") return v;
    }
  }
  return "";
}

/**
 * Executes an HTTP request against the allowed portal hosts, injecting `jar`
 * cookies on every hop, absorbing `Set-Cookie` into `jar`, and stripping
 * `Set-Cookie` from the returned headers.
 */
export async function executeWithCookieJar({
  method = "GET",
  url,
  headers = {},
  bodyBytes = null,
  followRedirects = true,
  jar,
  policy,
  fetchImpl = fetch,
  timeoutMs = 22000,
  allowPrivateLoopback = false,
  nowFn = Date.now,
  maxResponseBytes = MAX_UPSTREAM_RESPONSE_BYTES,
  uncertainWrite = false,
  allowRequest = null,
}) {
  const normalizedMethod = String(method || "GET").toUpperCase();
  if (normalizedMethod !== "GET" && normalizedMethod !== "POST") {
    throw new PortalProtocolError("UNTRUSTED_URL", "仅支持 GET / POST 请求", 400);
  }

  if (!isHostAllowed(url, policy.allowedHosts, policy.requireSecure) ||
      (allowRequest && !allowRequest(normalizedMethod, url))) {
    throw new PortalProtocolError(
      "UNTRUSTED_URL",
      `目标域名不在当前 Worker 绑定的高校白名单内：${url}`,
      403,
    );
  }

  const startedWithPost = normalizedMethod === "POST";
  let initialOrigin = "";
  try {
    initialOrigin = new URL(String(url)).origin;
  } catch {
    initialOrigin = "";
  }

  let currentUrl = String(url);
  let currentMethod = normalizedMethod;
  let currentBody = bodyBytes;
  let convertedPostToGet = false;
  let cookiesMutated = false;
  let firstHopWasLoginRedirect = false;

  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    let parsed;
    try {
      parsed = new URL(currentUrl);
    } catch {
      throw new PortalProtocolError("UNTRUSTED_URL", `非法 URL：${currentUrl}`, 400);
    }
    if (
      (parsed.protocol !== "http:" && parsed.protocol !== "https:") ||
      parsed.username ||
      parsed.password
    ) {
      throw new PortalProtocolError("UNTRUSTED_URL", `拒绝危险 URL：${currentUrl}`, 403);
    }
    if (!allowPrivateLoopback && isPrivateOrLoopbackHost(parsed.hostname)) {
      throw new PortalProtocolError(
        "UNTRUSTED_URL",
        `拒绝访问内网或环回地址：${parsed.hostname}`,
        403,
      );
    }

    const isCrossOriginHop = hop > 0 && initialOrigin && parsed.origin !== initialOrigin;
    const outgoingHeaders = new Headers();
    let hasUserAgent = false;
    if (headers && typeof headers === "object") {
      for (const [k, v] of Object.entries(headers)) {
        if (v == null) continue;
        const lower = k.toLowerCase();
        if (STRIPPED_CLIENT_HEADERS.has(lower) || lower.startsWith("cf-")) continue;
        if (convertedPostToGet && lower === "content-type") continue;
        if (isCrossOriginHop && (lower === "origin" || lower === "referer")) continue;
        if (lower === "user-agent") hasUserAgent = true;
        outgoingHeaders.set(k, Array.isArray(v) ? String(v[0] ?? "") : String(v));
      }
    }
    if (!hasUserAgent) {
      outgoingHeaders.set("User-Agent", DEFAULT_USER_AGENT);
    }

    const nowMs = nowFn();
    const cookieHeader = jar.cookieHeaderFor(currentUrl, nowMs);
    if (cookieHeader) {
      outgoingHeaders.set("Cookie", cookieHeader);
    }

    const controller = new AbortController();
    const timer = timeoutMs > 0
      ? setTimeout(() => controller.abort(new Error("UPSTREAM_TIMEOUT")), timeoutMs)
      : null;

    try {
      let upstream;
      try {
        upstream = await fetchImpl(currentUrl, {
          method: currentMethod,
          headers: outgoingHeaders,
          body: currentBody && currentMethod === "POST" ? currentBody : undefined,
          redirect: "manual",
          signal: controller.signal,
        });
      } catch (err) {
        const isTimeout =
          controller.signal.aborted ||
          String(err && err.name) === "AbortError" ||
          String(err && err.message).includes("UPSTREAM_TIMEOUT");
        // Security Redline #3: Never auto-retry or mask an in-flight POST timeout,
        // nor a failure on a redirect hop after hop 0 POST was already accepted by upstream.
        if (startedWithPost && (uncertainWrite || isTimeout || hop > 0)) {
          throw new PortalProtocolError(
            "RESULT_UNKNOWN",
            "连接教务上游写接口超时或重定向中断，结果未知（已阻断自动重发，请核实已选名单）",
            504,
          );
        }
        throw new PortalProtocolError(
          "NETWORK_ERROR",
          isTimeout ? `连接教务上游超时：${currentUrl}` : `连接教务上游失败：${err}`,
          502,
        );
      }

      const setCookies = typeof upstream.headers.getSetCookie === "function"
        ? upstream.headers.getSetCookie()
        : (upstream.headers.get("set-cookie") ? [upstream.headers.get("set-cookie")] : []);

      if (jar.absorbSetCookies(setCookies, currentUrl, nowFn()) > 0) {
        cookiesMutated = true;
      }

      const status = upstream.status;
      const location = upstream.headers.get("location");
      const isRedirect =
        status === 301 || status === 302 || status === 303 || status === 307 || status === 308;

      if (!followRedirects || !isRedirect || !location) {
        const bodyBuf = await readBoundedResponseBytes(upstream, maxResponseBytes);
        return {
          status,
          finalUrl: currentUrl,
          headers: serializeHeadersWithoutCookies(upstream.headers),
          bodyBytes: bodyBuf,
          cookiesMutated,
          hopCount: hop,
          firstHopWasLoginRedirect,
        };
      }

      if (hop === MAX_REDIRECTS) {
        if (startedWithPost) {
          throw new PortalProtocolError(
            "RESULT_UNKNOWN",
            "写请求后教务重定向超过上限，结果未知（已阻断自动重发）",
            504,
          );
        }
        throw new PortalProtocolError("NETWORK_ERROR", "教务上游重定向次数超过上限", 502);
      }

      let resolvedNextUrl;
      try {
        resolvedNextUrl = new URL(location, currentUrl).toString();
      } catch {
        throw new PortalProtocolError("UNTRUSTED_URL", `非法重定向地址：${location}`, 400);
      }

      const nextUrl = upgradeSameHostHttpRedirect(currentUrl, resolvedNextUrl);
      if (hop === 0 && isLoginUrlPath(nextUrl)) {
        firstHopWasLoginRedirect = true;
      }

      const nextHostname = new URL(nextUrl).hostname;
      const nextMethod = status === 301 || status === 302 || status === 303
        ? "GET" : currentMethod;
      if (
        !isHostAllowed(nextUrl, policy.allowedHosts, policy.requireSecure) ||
        (allowRequest && !allowRequest(nextMethod, nextUrl)) ||
        (nextMethod === "POST" && new URL(nextUrl).origin !== parsed.origin) ||
        (!allowPrivateLoopback && isPrivateOrLoopbackHost(nextHostname))
      ) {
        const bodyBuf = await readBoundedResponseBytes(upstream, maxResponseBytes);
        const outHeaders = serializeHeadersWithoutCookies(upstream.headers);
        outHeaders[BLOCKED_REDIRECT_HEADER] = [nextUrl];
        return {
          status,
          finalUrl: currentUrl,
          headers: outHeaders,
          bodyBytes: bodyBuf,
          cookiesMutated,
          hopCount: hop,
          firstHopWasLoginRedirect,
        };
      }

      // Drain unused redirect body to release connection resources cleanly.
      if (upstream.body && typeof upstream.body.cancel === "function") {
        try {
          await upstream.body.cancel();
        } catch {
          // Ignore cancel error.
        }
      }

      if (status === 301 || status === 302 || status === 303) {
        if (currentMethod === "POST") {
          convertedPostToGet = true;
        }
        currentMethod = "GET";
        currentBody = null;
      }
      currentUrl = nextUrl;
    } catch (error) {
      if (uncertainWrite && startedWithPost && error?.status !== "RESULT_UNKNOWN") {
        throw new PortalProtocolError("RESULT_UNKNOWN", "选退课响应未能完整读取，请核对已选名单", 504);
      }
      throw error;
    } finally {
      if (timer !== null) clearTimeout(timer);
    }
  }

  throw new PortalProtocolError("NETWORK_ERROR", "重定向异常终止", 502);
}

export function decodePortalText(bytes, contentType = "") {
  let charset = "utf-8";
  const ctMatch = /charset\s*=\s*["']?([A-Za-z0-9_-]+)/i.exec(contentType || "");
  if (ctMatch) {
    charset = ctMatch[1].toLowerCase();
  } else {
    const headLen = Math.min(bytes.length, 2048);
    let ascii = "";
    for (let i = 0; i < headLen; i++) {
      ascii += String.fromCharCode(bytes[i]);
    }
    const metaMatch = /charset\s*=\s*["']?([A-Za-z0-9_-]+)/i.exec(ascii);
    if (metaMatch) charset = metaMatch[1].toLowerCase();
  }
  if (charset === "gb2312" || charset === "gbk" || charset === "gb18030") {
    try {
      return new TextDecoder("gbk", { fatal: false }).decode(bytes);
    } catch {
      return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
    }
  }
  return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
}

export function isLoginUrlPath(urlStr) {
  try {
    const p = trimTrailingSlash(new URL(urlStr).pathname).toLowerCase();
    return (
      p.endsWith("/login_slogin.html") ||
      p.endsWith("/cas/login") ||
      p.endsWith("/xk/logintoxk") ||
      p.endsWith("/default2.aspx")
    );
  } catch {
    return false;
  }
}

export function isSessionExpiredExchange(exchange) {
  const status = exchange.status;
  // HTTP 901 is Zhengfang jwglxt's dedicated AJAX session-expired status code.
  // Note: generic HTTP 403 is intentionally excluded because portals/WAFs return 403 for
  // closed selection rounds or forbidden actions on an otherwise valid session.
  if (status === 901 || status === 401) {
    return true;
  }
  if (isLoginUrlPath(exchange.finalUrl)) {
    return true;
  }
  if (status >= 300 && status < 400) {
    const loc = firstHeaderValue(exchange.headers, "location");
    const blocked = firstHeaderValue(exchange.headers, BLOCKED_REDIRECT_HEADER.toLowerCase());
    for (const candidate of [loc, blocked]) {
      if (!candidate) continue;
      try {
        const resolved = new URL(candidate, exchange.finalUrl).toString();
        if (isLoginUrlPath(resolved)) return true;
      } catch {
        // Ignore malformed redirect header.
      }
    }
  }
  if (status === 200 && exchange.bodyBytes && exchange.bodyBytes.length > 0) {
    const ct = firstHeaderValue(exchange.headers, "content-type").toLowerCase();
    const looksLikeMarkupOrText =
      !ct ||
      ct.includes("html") ||
      ct.includes("text") ||
      ct.includes("json");
    if (looksLikeMarkupOrText) {
      const text = decodePortalText(exchange.bodyBytes, ct);
      if (isLoginPageHtml(text)) return true;
      if (text.trim() === '"sessionOut"' || text.trim() === "sessionOut") return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// Crypto Primitives (BigInt PKCS#1 v1.5 RSA, CAS Hex RSA, Qingzhi scode)
// ---------------------------------------------------------------------------

function bytesToBigInt(bytes) {
  let hex = "";
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i] & 0xff;
    hex += (b < 16 ? "0" : "") + b.toString(16);
  }
  return hex ? BigInt("0x" + hex) : 0n;
}

function bigIntToFixedBytes(num, length) {
  let hex = num.toString(16);
  if (hex.length > length * 2) {
    throw new PortalProtocolError("NETWORK_ERROR", "RSA 密文长度超出分组上限", 502);
  }
  while (hex.length < length * 2) {
    hex = "0" + hex;
  }
  const out = new Uint8Array(length);
  for (let i = 0; i < length; i++) {
    out[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function modPow(base, exp, mod) {
  if (mod <= 0n) throw new PortalProtocolError("NETWORK_ERROR", "RSA 模数必须为正整数", 502);
  if (mod === 1n) return 0n;
  let result = 1n;
  let b = ((base % mod) + mod) % mod;
  let e = exp;
  while (e > 0n) {
    if ((e & 1n) === 1n) {
      result = (result * b) % mod;
    }
    e >>= 1n;
    if (e > 0n) {
      b = (b * b) % mod;
    }
  }
  return result;
}

function stripLeadingZeroBytes(bytes) {
  let idx = 0;
  while (idx < bytes.length && bytes[idx] === 0) {
    idx += 1;
  }
  return bytes.subarray(idx);
}

function fillNonZeroRandom(target, offset, length) {
  let filled = 0;
  const scratch = new Uint8Array(Math.max(length * 2, 32));
  while (filled < length) {
    crypto.getRandomValues(scratch);
    for (let i = 0; i < scratch.length && filled < length; i++) {
      if (scratch[i] !== 0) {
        target[offset + filled] = scratch[i];
        filled += 1;
      }
    }
  }
  scratch.fill(0);
}

export function rsaEncryptPkcs1(password, modulusBase64, exponentBase64) {
  const modBytes = stripLeadingZeroBytes(base64ToBytes(modulusBase64));
  const expBytes = stripLeadingZeroBytes(base64ToBytes(exponentBase64));
  if (modBytes.length < 11) {
    throw new PortalProtocolError("NETWORK_ERROR", "教务公钥模数过短，无法执行 PKCS#1 v1.5 填充", 502);
  }
  if (expBytes.length === 0) {
    throw new PortalProtocolError("NETWORK_ERROR", "教务公钥指数为空", 502);
  }
  const modulus = bytesToBigInt(modBytes);
  const exponent = bytesToBigInt(expBytes);
  const blockSize = modBytes.length;
  const plainBytes = new TextEncoder().encode(password);
  if (plainBytes.length === 0 || plainBytes.length > blockSize - 11) {
    plainBytes.fill(0);
    throw new PortalProtocolError("CONFIG_ERROR", "登录密码长度不满足教务 RSA 分组要求", 500);
  }
  const padLength = blockSize - plainBytes.length - 3;
  const block = new Uint8Array(blockSize);
  try {
    block[0] = 0x00;
    block[1] = 0x02;
    fillNonZeroRandom(block, 2, padLength);
    block[2 + padLength] = 0x00;
    block.set(plainBytes, 3 + padLength);
    const cipherInt = modPow(bytesToBigInt(block), exponent, modulus);
    return bytesToBase64(bigIntToFixedBytes(cipherInt, blockSize));
  } finally {
    plainBytes.fill(0);
    block.fill(0);
  }
}

export function zhengfangRsaEncrypt(password, modulusHex, exponentHex) {
  const cleanMod = String(modulusHex || "").trim();
  const cleanExp = String(exponentHex || "").trim();
  if (!/^[0-9a-fA-F]+$/.test(cleanMod) || !/^[0-9a-fA-F]+$/.test(cleanExp)) {
    throw new PortalProtocolError("NETWORK_ERROR", "CAS 公钥不是合法的十六进制串", 502);
  }
  const modulus = BigInt("0x" + cleanMod);
  const exponent = BigInt("0x" + cleanExp);
  const bitLength = modulus.toString(2).length;
  const unitCount = Math.floor((bitLength + 15) / 16);
  const blockUnits = 2 * (unitCount - 1);
  if (blockUnits <= 0) {
    throw new PortalProtocolError("NETWORK_ERROR", "CAS 公钥模数过短", 502);
  }
  const units = [];
  for (let i = password.length - 1; i >= 0; i--) {
    units.push(password.charCodeAt(i));
  }
  const rem = units.length % blockUnits;
  if (rem !== 0) {
    for (let p = 0; p < blockUnits - rem; p++) units.push(0);
  }
  try {
    const blocks = [];
    for (let offset = 0; offset < units.length; offset += blockUnits) {
      let acc = 0n;
      for (let pairIdx = offset + blockUnits - 2; pairIdx >= offset; pairIdx -= 2) {
        const digit = units[pairIdx] + (units[pairIdx + 1] << 8);
        acc = (acc << 16n) + BigInt(digit);
      }
      blocks.push(modPow(acc, exponent, modulus).toString(16));
    }
    return blocks.join(" ");
  } finally {
    units.fill(0);
  }
}

export function encodeQingzhiScode(username, password, scode, sxh) {
  const code = `${username}%%%${password}`;
  let encoded = "";
  let sc = String(scode || "");
  const sx = String(sxh || "");
  for (let i = 0; i < code.length; i++) {
    if (i < 20) {
      let step = Number.parseInt(sx.slice(i, i + 1), 10);
      if (Number.isNaN(step) || step < 0) step = 0;
      encoded += code.slice(i, i + 1) + sc.slice(0, step);
      sc = sc.slice(step);
    } else {
      encoded += code.slice(i);
      break;
    }
  }
  return encoded;
}

// ---------------------------------------------------------------------------
// HTML & Identity Parsing Helpers
// ---------------------------------------------------------------------------

function decodeHtmlEntities(str) {
  return String(str || "")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&#(\d+);/g, (_, dec) => {
      const code = Number.parseInt(dec, 10);
      return Number.isNaN(code) ? _ : String.fromCharCode(code);
    })
    .replace(/&#x([0-9a-fA-F]+);/g, (_, hex) => {
      const code = Number.parseInt(hex, 16);
      return Number.isNaN(code) ? _ : String.fromCharCode(code);
    });
}

const SCRIPT_BLOCK_RE = /<script\b[^>]*>[\s\S]*?<\/script>/gi;
const STYLE_BLOCK_RE = /<style\b[^>]*>[\s\S]*?<\/style>/gi;

function stripScriptsAndComments(html) {
  return String(html || "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(SCRIPT_BLOCK_RE, "")
    .replace(STYLE_BLOCK_RE, "");
}

export function safeJsonParse(body) {
  try {
    return JSON.parse(String(body || ""));
  } catch {
    return null;
  }
}

export function stripHtmlToText(fragment) {
  const withoutScripts = stripScriptsAndComments(fragment)
    .replace(/<br\s*\/?>/gi, " ")
    .replace(/<\/?(?:p|div|tr|td|th|li|ul|ol|h[1-6])\b[^>]*>/gi, " ")
    .replace(/<[^>]+>/g, "");
  return decodeHtmlEntities(withoutScripts).replace(/\s+/g, " ").trim();
}

function parseAttrs(attrText) {
  const attrs = {};
  const re = /([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\s*=(?:\s*(?:"([^"]*)"|'([^']*)'|(?![A-Za-z_:][-A-Za-z0-9_:.]*\s*=)([^\s"'=<>]+)))?)?/g;
  let m;
  while ((m = re.exec(attrText)) !== null) {
    const key = m[1].toLowerCase();
    const rawVal = m[2] !== undefined ? m[2] : (m[3] !== undefined ? m[3] : (m[4] !== undefined ? m[4] : ""));
    attrs[key] = decodeHtmlEntities(rawVal);
  }
  return attrs;
}

export function findTags(html, tagName) {
  const cleaned = stripScriptsAndComments(html);
  const re = new RegExp(`<${tagName}\\b([^>]*)>`, "gi");
  const list = [];
  let m;
  while ((m = re.exec(cleaned)) !== null) {
    list.push({ attrs: parseAttrs(m[1] || ""), index: m.index });
  }
  return list;
}

export function extractHiddenInputs(html) {
  const out = {};
  for (const item of findTags(html, "input")) {
    const a = item.attrs;
    const type = String(a.type || "").toLowerCase();
    if (type && type !== "hidden") continue;
    const val = a.value !== undefined ? String(a.value) : "";
    if (a.name) out[a.name] = val;
    if (a.id && !(a.id in out)) out[a.id] = val;
  }
  return out;
}

export function findElementsText(html, predicate) {
  const cleaned = stripScriptsAndComments(html);
  const openRe = /<([A-Za-z][A-Za-z0-9:-]*)\b([^>]*)>/g;
  const results = [];
  let m;
  while ((m = openRe.exec(cleaned)) !== null) {
    const tag = m[1].toLowerCase();
    const rawAttr = m[2] || "";
    const selfClosing =
      rawAttr.trim().endsWith("/") ||
      tag === "input" ||
      tag === "img" ||
      tag === "br" ||
      tag === "meta" ||
      tag === "hr";
    const attrs = parseAttrs(rawAttr);
    if (!predicate(tag, attrs)) continue;
    if (selfClosing) {
      results.push({ tag, attrs, text: "" });
      continue;
    }
    let depth = 1;
    const scanRe = new RegExp(`<(\\/?)${tag}\\b([^>]*)>`, "gi");
    scanRe.lastIndex = openRe.lastIndex;
    let closeIdx = cleaned.length;
    let sm;
    while ((sm = scanRe.exec(cleaned)) !== null) {
      const isClose = sm[1] === "/";
      const innerSelfClose = !isClose && (sm[2] || "").trim().endsWith("/");
      if (isClose) {
        depth -= 1;
        if (depth === 0) {
          closeIdx = sm.index;
          break;
        }
      } else if (!innerSelfClose) {
        depth += 1;
      }
    }
    const innerHtml = cleaned.slice(openRe.lastIndex, closeIdx);
    results.push({ tag, attrs, text: stripHtmlToText(innerHtml) });
  }
  return results;
}

export function getElementTextById(html, targetId) {
  const matches = findElementsText(html, (_, attrs) => attrs.id === targetId);
  return matches.length > 0 ? matches[0].text : "";
}

function hasClassToken(attrs, className) {
  const cls = (attrs.class || "").trim();
  if (!cls) return false;
  return cls.split(/\s+/).includes(className);
}

function isHiddenControlAttrs(attrs) {
  if ("disabled" in attrs || "hidden" in attrs) return true;
  if ((attrs.type || "").toLowerCase() === "hidden") return true;
  const style = attrs.style || "";
  return /(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)\b/i.test(style);
}

function extractMetaRefreshTarget(html, baseUrl) {
  const metas = findTags(html, "meta");
  for (const meta of metas) {
    const attrs = meta.attrs;
    if ((attrs["http-equiv"] || "").trim().toLowerCase() !== "refresh") continue;
    const content = attrs.content || "";
    const m = /url\s*=\s*(?:['"]([^'"]+)['"]|([^\s;>]+))/i.exec(content);
    const rawTarget = ((m && (m[1] || m[2])) || "").trim();
    if (rawTarget) {
      try {
        return baseUrl ? new URL(rawTarget, baseUrl).toString() : rawTarget;
      } catch {
        return rawTarget;
      }
    }
  }
  return null;
}

function extractScriptVar(html, varName) {
  const re = new RegExp(`(?:var\\s+)?${varName}\\s*=\\s*['"]([^'"]*)['"]`);
  const m = re.exec(String(html || ""));
  return m ? m[1] : null;
}

function extractContextBeforeModule(urlPath) {
  if (!urlPath) return null;
  const markers = ["/xtgl/", "/kbcx/", "/cjcx/", "/xsxk/", "/kwgl/", "/xsxy/", "/cdjy/", "/xkcx/"];
  for (const marker of markers) {
    const idx = urlPath.indexOf(marker);
    if (idx > 0) return urlPath.slice(0, idx);
  }
  return null;
}

function normalizeContextPath(raw) {
  let p = String(raw || "").trim();
  if (!p || p === "/") return null;
  const fromMod = extractContextBeforeModule(p);
  if (fromMod) return fromMod;
  if (!p.startsWith("/")) p = "/" + p;
  while (p.length > 1 && p.endsWith("/")) p = p.slice(0, -1);
  if (p.includes("?") || p.includes(".html") || p.includes(".aspx")) return null;
  return p;
}

function detectJwglxtContextPath(html, finalUrl) {
  for (const name of ["_path", "_systemPath"]) {
    const norm = normalizeContextPath(extractScriptVar(html, name));
    if (norm) return norm;
  }
  const refresh = extractMetaRefreshTarget(html, "");
  if (refresh) {
    let candidatePath = refresh;
    try {
      candidatePath = new URL(refresh, "https://placeholder.local").pathname;
    } catch {
      // Keep raw string.
    }
    const normRefresh = normalizeContextPath(candidatePath);
    if (normRefresh) return normRefresh;
  }
  if (finalUrl) {
    try {
      return extractContextBeforeModule(new URL(finalUrl).pathname);
    } catch {
      return null;
    }
  }
  return null;
}

function hasNoContextPath(urlStr) {
  try {
    const p = new URL(urlStr).pathname;
    return !p || p === "/";
  } catch {
    return false;
  }
}

export function isLoginPageHtml(html) {
  const inputs = findTags(html, "input");
  for (const item of inputs) {
    const a = item.attrs;
    const t = (a.type || "").toLowerCase();
    const n = a.name || "";
    if (t === "password" || n === "mm" || n === "TextBox2" || n === "userPassword") {
      return true;
    }
  }
  return /(?:top\.|window\.|parent\.)?location(?:\.href)?\s*=\s*['"][^'"]*(?:login_slogin|default2\.aspx|LoginToXk)/i.test(
    String(html || ""),
  );
}

function detectSystemFromHtml(html) {
  const lower = String(html || "").toLowerCase();
  if (lower.includes("login_getpublickey") || (lower.includes("csrftoken") && lower.includes("xtgl"))) {
    return "ZF";
  }
  if (lower.includes("var scode") && lower.includes("var sxh") && lower.includes("logintoxk")) {
    return "QZ";
  }
  if (lower.includes("flag=sess") || (lower.includes("encodeinp") && lower.includes("%%%"))) {
    return "QZ";
  }
  return null;
}

function parseJwglxtLoginPage(html) {
  const inputs = findTags(html, "input");
  let csrfToken = "";
  let language = "zh_CN";
  let mmsfjm = "1";
  let dlsfbxyzm = "0";
  let yzmVisible = false;

  for (const item of inputs) {
    const a = item.attrs;
    const name = a.name || "";
    const id = a.id || "";
    if ((name === "csrftoken" || id === "csrftoken") && !csrfToken) {
      csrfToken = (a.value || "").trim();
    }
    if (name === "language" && (a.value || "").trim()) {
      language = a.value.trim();
    }
    if (name === "mmsfjm") {
      mmsfjm = (a.value || "").trim();
    }
    if (name === "dlsfbxyzm") {
      dlsfbxyzm = (a.value || "").trim();
    }
    if ((name === "yzm" || id === "yzm") && !isHiddenControlAttrs(a)) {
      yzmVisible = true;
    }
  }

  if (!csrfToken) return null;

  if (!yzmVisible) {
    const yzmDivs = findElementsText(html, (_, attrs) => attrs.id === "yzmDiv" && !isHiddenControlAttrs(attrs));
    if (yzmDivs.length > 0) yzmVisible = true;
  }

  let formAction = "";
  for (const form of findTags(html, "form")) {
    const act = (form.attrs.action || "").trim();
    if (act) {
      formAction = act;
      break;
    }
  }

  return {
    csrfToken,
    formAction,
    language,
    encryptPassword: mmsfjm !== "0",
    captchaRequired: dlsfbxyzm === "1" || yzmVisible,
  };
}

function classifyJwglxtSubmit(finalUrl, html) {
  const tips = getElementTextById(html, "tips") || getElementTextById(html, "errormsg");
  if (tips) {
    return {
      ok: false,
      captchaRequired: tips.includes("验证码"),
      message: tips,
    };
  }
  if (/(?:top\.|window\.|parent\.)?location(?:\.href)?\s*=\s*['"][^'"]*login_slogin/i.test(String(html || ""))) {
    return { ok: false, captchaRequired: false, message: "教务系统未接受本次登录，重定向回了登录页" };
  }
  const pageCheck = parseJwglxtLoginPage(html);
  if (pageCheck && isLoginPageHtml(html)) {
    return {
      ok: false,
      captchaRequired: Boolean(pageCheck.captchaRequired),
      message: "教务系统未接受本次登录，请核对 PORTAL_USERNAME 与 PORTAL_PASSWORD",
    };
  }
  if (isLoginUrlPath(finalUrl) && isLoginPageHtml(html)) {
    return { ok: false, captchaRequired: false, message: "登录响应仍停留在登录页，未能建立有效会话" };
  }
  return { ok: true, captchaRequired: false, message: "" };
}

function normalizeStudentName(raw, dropRole) {
  let collapsed = String(raw || "").replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim();
  if (!dropRole) return collapsed;
  for (const role of ["同学", "学生", "教师", "老师"]) {
    if (collapsed.endsWith(role)) {
      collapsed = collapsed.slice(0, collapsed.length - role.length).trim();
      break;
    }
  }
  return collapsed;
}

export function parsePortalIdentity(html) {
  if (isLoginPageHtml(html)) {
    return { studentId: "", name: "", department: "", className: "" };
  }
  let studentId = "";
  let name = "";
  let department = "";
  let className = "";

  const headings = findElementsText(
    html,
    (_, attrs) =>
      hasClassToken(attrs, "infoContentTitle") ||
      hasClassToken(attrs, "userInfo") ||
      hasClassToken(attrs, "user-info"),
  );
  for (const h of headings) {
    const hm = /^(.+?)(?:-|\[)([A-Za-z0-9]{6,})\]?$/.exec(h.text);
    if (hm) {
      name = hm[1].trim();
      studentId = hm[2].trim();
      break;
    }
  }

  for (const item of findTags(html, "input")) {
    const a = item.attrs;
    const iname = a.name || "";
    const iid = a.id || "";
    const ival = (a.value || "").trim();
    if (!name && (iname === "xm" || iname === "studentName" || iid === "studentName") && ival) {
      name = normalizeStudentName(ival, false);
    }
    if (
      !studentId &&
      (iname === "xh" || iname === "xh_id" || iname === "studentId" || iid === "studentId" || iid === "sessionUserKey" || iid === "xh_id") &&
      ival
    ) {
      studentId = ival;
    }
  }

  if (!name) {
    const nameEls = findElementsText(
      html,
      (_, attrs) =>
        hasClassToken(attrs, "media-heading") ||
        attrs.id === "xhxm" ||
        hasClassToken(attrs, "user-name") ||
        attrs.id === "studentName" ||
        attrs.id === "Top1_divLoginName" ||
        hasClassToken(attrs, "Nsb_top_menu_nc"),
    );
    for (const el of nameEls) {
      if (el.text) {
        const cleaned = normalizeStudentName(el.text, true);
        if (cleaned) {
          name = cleaned;
          break;
        }
      }
    }
  }

  const pTags = findElementsText(html, (tag) => tag === "p" || tag === "span" || tag === "li");
  for (const p of pTags) {
    const t = p.text;
    if (!department) {
      const dm = /^(?:学院|院系|所属学院|部门)\s*[：:]\s*(.+)$/.exec(t);
      if (dm) department = dm[1].trim();
    }
    if (!className) {
      const cm = /^(?:班级|行政班|专业班级)\s*[：:]\s*(.+)$/.exec(t);
      if (cm) className = cm[1].trim();
    }
    if (!department && !className && t.includes(" ") && /学院|系|部/.test(t) && /\d{2,}/.test(t) && t.length <= 40) {
      const segs = t.split(/\s+/);
      if (segs.length === 2) {
        department = segs[0];
        className = segs[1];
      }
    }
  }

  if (!studentId) {
    for (const id of ["xh_id", "sessionUserKey", "studentId"]) {
      const txt = getElementTextById(html, id);
      if (txt) {
        studentId = txt;
        break;
      }
    }
  }

  if (!studentId) {
    for (const img of findTags(html, "img")) {
      const sm = /[?&]xh_id=([A-Za-z0-9_-]+)/.exec(img.attrs.src || "");
      if (sm) {
        studentId = sm[1];
        break;
      }
    }
  }

  return { studentId, name, department, className };
}

function mergeIdentity(base, extra) {
  return {
    studentId: base.studentId || extra.studentId || "",
    name: base.name || extra.name || "",
    department: base.department || extra.department || "",
    className: base.className || extra.className || "",
  };
}

export function encodeFormBytes(pairs) {
  const str = pairs
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");
  return new TextEncoder().encode(str);
}

function appendQueryParam(urlStr, key, val) {
  const sep = urlStr.includes("?") ? "&" : "?";
  return `${urlStr}${sep}${encodeURIComponent(key)}=${encodeURIComponent(String(val))}`;
}

// ---------------------------------------------------------------------------
// Server-Side Portal Authentication & Keep-Alive Probe
// ---------------------------------------------------------------------------

export async function authenticatePortalSession({
  config,
  jar,
  fetchImpl = fetch,
  timeoutMs = 22000,
  allowPrivateLoopback = false,
  nowFn = Date.now,
}) {
  let reqSeq = 0;
  const nextStamp = () => String(nowFn() + reqSeq++);
  const policy = {
    allowedHosts: config.allowedHosts,
    requireSecure: config.requireSecure,
  };
  // Populate an isolated staging CookieJar so mid-login failures or concurrent readers
  // never observe half-authenticated cookies or wipe an existing valid session.
  const stagingJar = new ServerCookieJar();

  async function requestText(opts) {
    const headers = { ...(opts.headers || {}) };
    let bodyBytes = null;
    if (opts.formPairs) {
      headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8";
      bodyBytes = encodeFormBytes(opts.formPairs);
    }
    let ex;
    try {
      ex = await executeWithCookieJar({
        method: opts.method || "GET",
        url: opts.url,
        headers,
        bodyBytes,
        followRedirects: opts.followRedirects !== false,
        jar: stagingJar,
        policy,
        fetchImpl,
        timeoutMs,
        allowPrivateLoopback,
        nowFn,
      });
    } catch (err) {
      // Login POST timeouts happen before any client business request is dispatched;
      // surface them as retryable 502 NETWORK_ERROR rather than 504 RESULT_UNKNOWN.
      if (err instanceof PortalProtocolError && err.status === "RESULT_UNKNOWN") {
        throw new PortalProtocolError(
          "NETWORK_ERROR",
          "教务登录认证请求超时，业务请求尚未发出",
          502,
        );
      }
      throw err;
    }
    if (opts.followRedirects !== false) {
      const blocked = firstHeaderValue(ex.headers, BLOCKED_REDIRECT_HEADER.toLowerCase());
      if (blocked) {
        throw new PortalProtocolError(
          "UNTRUSTED_URL",
          `拦截到跳出学校域名白名单的重定向：${blocked}（若需走统一身份认证，请配置 PORTAL_CAS_URL）`,
          403,
        );
      }
    }
    const ct = firstHeaderValue(ex.headers, "content-type");
    return {
      ...ex,
      text: decodePortalText(ex.bodyBytes, ct),
    };
  }

  // 1. Optional seed cookies check before credential login (or when password is not set).
  if (config.seedCookies) {
    stagingJar.clear();
    stagingJar.absorbSeedCookies(config.seedCookies, config.portalUrl, nowFn());
    const probed = await probeSessionAlive({
      effectiveBaseUrl: config.portalUrl,
      systemId:
        config.system === "auto"
          ? (config.portalUrl.toLowerCase().includes("/jsxsd") ? "QZ" : "ZF")
          : config.system,
      jar: stagingJar,
      policy,
      fetchImpl,
      timeoutMs,
      allowPrivateLoopback,
      nowFn,
    });
    if (probed.alive) {
      if (jar && typeof jar.replaceFrom === "function") {
        jar.replaceFrom(stagingJar, nowFn());
      }
      return {
        effectiveBaseUrl: probed.effectiveBaseUrl || config.portalUrl,
        systemId: probed.systemId,
        identity: mergeIdentity(probed.identity, {
          studentId: config.username,
          name: "",
          department: "",
          className: "",
        }),
        jar: stagingJar,
      };
    }
    if (!config.username || !config.password) {
      throw new PortalProtocolError(
        "SESSION_EXPIRED",
        "PORTAL_COOKIES 种子会话已过期，且未配置 PORTAL_USERNAME / PORTAL_PASSWORD 自动重登凭据",
        401,
      );
    }
  }

  if (!config.username || !config.password) {
    throw new PortalProtocolError(
      "SESSION_EXPIRED",
      "当前 Worker 未配置静态教务账号密码或有效种子 Cookie；请通过客户端上报会话 Cookie（POST /v1/session/cookies）或配置 PORTAL_USERNAME + PORTAL_PASSWORD",
      401,
    );
  }

  stagingJar.clear();

  let result;
  if (config.casUrl) {
    result = await runCasFlow({ config, requestText, nextStamp, jar: stagingJar, nowFn });
  } else {
    const lowerUrl = config.portalUrl.toLowerCase();
    if (
      config.system === "QZ" ||
      config.system === "QZ_OLD" ||
      (config.system === "auto" && lowerUrl.includes("/jsxsd"))
    ) {
      result = await runQingzhiFlow({ config, requestText, jar: stagingJar, nowFn });
    } else {
      let inferred = null;
      if (config.system === "auto" && hasNoContextPath(config.portalUrl)) {
        try {
          const probeRes = await requestText({ method: "GET", url: `${config.portalUrl}/` });
          inferred = detectSystemFromHtml(probeRes.text);
          const refreshUrl = extractMetaRefreshTarget(probeRes.text, probeRes.finalUrl);
          if (!inferred && refreshUrl) {
            const rPath = new URL(refreshUrl).pathname.toLowerCase();
            if (rPath.startsWith("/jsxsd")) inferred = "QZ";
            else if (rPath.startsWith("/jwglxt")) inferred = "ZF";
          }
        } catch {
          // Fall through to Zhengfang flow.
        }
      }
      if (inferred === "QZ") {
        result = await runQingzhiFlow({ config, requestText, jar: stagingJar, nowFn });
      } else {
        result = await runZhengfangJwglxtFlow({
          config,
          requestText,
          nextStamp,
          jar: stagingJar,
          nowFn,
        });
      }
    }
  }

  if (jar && typeof jar.replaceFrom === "function") {
    jar.replaceFrom(stagingJar, nowFn());
  }
  return {
    ...result,
    jar: stagingJar,
  };
}

async function runZhengfangJwglxtFlow({ config, requestText, nextStamp, jar, nowFn = Date.now }) {
  let effectiveRoot = config.portalUrl;
  const origin = new URL(effectiveRoot).origin;

  const adoptContextIfBare = (html, finalUrl) => {
    if (!hasNoContextPath(effectiveRoot)) return;
    const discovered = detectJwglxtContextPath(html, finalUrl);
    if (discovered) {
      effectiveRoot = origin + discovered;
    }
  };

  let initialPage = null;
  try {
    const loginEx = await requestText({
      method: "GET",
      url: `${effectiveRoot}/xtgl/login_slogin.html?time=${nextStamp()}`,
      headers: { Accept: "text/html,application/xhtml+xml,application/json,*/*;q=0.8" },
    });
    if (loginEx.status === 200) {
      adoptContextIfBare(loginEx.text, loginEx.finalUrl);
      initialPage = parseJwglxtLoginPage(loginEx.text);
    }
  } catch (err) {
    if (!hasNoContextPath(effectiveRoot)) throw err;
  }

  if (!initialPage) {
    if (!hasNoContextPath(effectiveRoot)) {
      throw new PortalProtocolError(
        "NETWORK_ERROR",
        `未能从正方登录页提取 csrftoken（${effectiveRoot}）`,
        502,
      );
    }
    let discoveredCtx = "/jwglxt";
    try {
      const rootRes = await requestText({ method: "GET", url: `${origin}/` });
      const ctxFromRoot = detectJwglxtContextPath(rootRes.text, rootRes.finalUrl);
      if (ctxFromRoot) discoveredCtx = ctxFromRoot;
    } catch {
      // Default to /jwglxt.
    }
    effectiveRoot = origin + discoveredCtx;
    const loginEx = await requestText({
      method: "GET",
      url: `${effectiveRoot}/xtgl/login_slogin.html?time=${nextStamp()}`,
      headers: { Accept: "text/html,application/xhtml+xml,application/json,*/*;q=0.8" },
    });
    adoptContextIfBare(loginEx.text, loginEx.finalUrl);
    initialPage = parseJwglxtLoginPage(loginEx.text);
    if (!initialPage) {
      throw new PortalProtocolError(
        "NETWORK_ERROR",
        `未能解析正方教务登录页 csrftoken（探测路径：${effectiveRoot}）`,
        502,
      );
    }
  }

  const loginPageUrl = `${effectiveRoot}/xtgl/login_slogin.html`;
  if (initialPage.captchaRequired) {
    throw new PortalProtocolError(
      "CAPTCHA_REQUIRED",
      "教务账号当前触发图形验证码校验，无头 Worker 无法自动识别验证码（可稍后重试或配置 PORTAL_COOKIES 种子会话）",
      403,
    );
  }

  let submittedPassword = config.password;
  if (initialPage.encryptPassword) {
    const pkEx = await requestText({
      method: "GET",
      url: `${effectiveRoot}/xtgl/login_getPublicKey.html?time=${nextStamp()}`,
      headers: {
        Referer: loginPageUrl,
        "X-Requested-With": "XMLHttpRequest",
        Accept: "application/json, text/javascript, */*; q=0.01",
      },
    });
    let pkJson;
    try {
      pkJson = JSON.parse(pkEx.text);
    } catch {
      throw new PortalProtocolError("NETWORK_ERROR", "教务 RSA 公钥接口返回格式异常", 502);
    }
    const modB64 = String((pkJson && pkJson.modulus) || "").trim();
    const expB64 = String((pkJson && pkJson.exponent) || "").trim();
    if (!modB64 || !expB64) {
      throw new PortalProtocolError("NETWORK_ERROR", "教务公钥缺少 modulus 或 exponent", 502);
    }
    submittedPassword = rsaEncryptPkcs1(config.password, modB64, expB64);
  }

  const resolvedAction = new URL(initialPage.formAction || loginPageUrl, loginPageUrl).toString();
  const submitRes = await requestText({
    method: "POST",
    url: appendQueryParam(resolvedAction, "time", nextStamp()),
    headers: {
      Referer: loginPageUrl,
      Origin: origin,
    },
    formPairs: [
      ["csrftoken", initialPage.csrfToken],
      ["language", initialPage.language],
      ["ydType", ""],
      ["yhm", config.username],
      ["mm", submittedPassword],
    ],
  });
  adoptContextIfBare(submitRes.text, submitRes.finalUrl);

  const outcome = classifyJwglxtSubmit(submitRes.finalUrl, submitRes.text);
  if (!outcome.ok) {
    throw new PortalProtocolError(
      outcome.captchaRequired ? "CAPTCHA_REQUIRED" : "INVALID_CREDENTIALS",
      outcome.message,
      outcome.captchaRequired ? 403 : 401,
    );
  }

  let identity = parsePortalIdentity(submitRes.text);
  let verifiedPage = submitRes.status === 200 && !isLoginPageHtml(submitRes.text);
  const initMenuUrl = `${effectiveRoot}/xtgl/index_initMenu.html?jsdm=xs`;

  try {
    const menuRes = await requestText({
      method: "GET",
      url: initMenuUrl,
      headers: { Referer: submitRes.finalUrl },
    });
    if (menuRes.status === 200 && !isLoginPageHtml(menuRes.text)) {
      verifiedPage = true;
      identity = mergeIdentity(identity, parsePortalIdentity(menuRes.text));
    }
  } catch {
    // Non-fatal if portal omits initMenu.
  }

  if (!identity.name || !identity.department) {
    try {
      const cardRes = await requestText({
        method: "GET",
        url: `${effectiveRoot}/xtgl/index_cxYhxxIndex.html?xt=jw&localeKey=zh_CN&gnmkdm=index`,
        headers: {
          Referer: initMenuUrl,
          "X-Requested-With": "XMLHttpRequest",
        },
      });
      if (cardRes.status === 200 && !isLoginPageHtml(cardRes.text)) {
        verifiedPage = true;
        identity = mergeIdentity(identity, parsePortalIdentity(cardRes.text));
      }
    } catch {
      // Non-fatal.
    }
  }

  if (!verifiedPage && !identity.studentId && !identity.name) {
    throw new PortalProtocolError(
      "SESSION_EXPIRED",
      "教务登录未报错，但首页菜单校验未识别到已认证会话",
      502,
    );
  }
  if (!jar.hasActiveCookies(nowFn())) {
    throw new PortalProtocolError(
      "SESSION_EXPIRED",
      "登录完成后未捕获到有效教务 Set-Cookie 会话",
      502,
    );
  }

  return {
    effectiveBaseUrl: effectiveRoot,
    systemId: "ZF",
    identity: mergeIdentity(identity, {
      studentId: config.username,
      name: "",
      department: "",
      className: "",
    }),
  };
}

async function runCasFlow({ config, requestText, nextStamp, jar, nowFn = Date.now }) {
  let casRoot = config.casUrl;
  if (casRoot.toLowerCase().endsWith("/cas/login")) {
    casRoot = casRoot.slice(0, -10);
  } else if (casRoot.toLowerCase().endsWith("/cas")) {
    casRoot = casRoot.slice(0, -4);
  }
  casRoot = trimTrailingSlash(casRoot);

  let effectivePortal = config.portalUrl;
  const serviceLoginUrl = `${casRoot}/cas/login?service=${encodeURIComponent(effectivePortal)}`;
  const casPageRes = await requestText({ method: "GET", url: serviceLoginUrl });

  let execution = "";
  let lt = "";
  const extraHidden = [];
  for (const item of findTags(casPageRes.text, "input")) {
    const a = item.attrs;
    const n = a.name || "";
    const v = a.value || "";
    if (n === "execution" && !execution) execution = v.trim();
    else if (n === "lt" && !lt) lt = v.trim();
    else if (
      (a.type || "").toLowerCase() === "hidden" &&
      n &&
      n !== "username" &&
      n !== "password" &&
      n !== "_eventId"
    ) {
      extraHidden.push([n, v]);
    }
  }
  if (!execution && !lt) {
    throw new PortalProtocolError("NETWORK_ERROR", "CAS 统一认证登录页未包含 execution 或 lt 令牌", 502);
  }

  let formAction = `${casRoot}/cas/login`;
  for (const form of findTags(casPageRes.text, "form")) {
    const fa = form.attrs;
    if (fa.id === "fm1" || fa.action) {
      if (fa.action) {
        formAction = new URL(fa.action, casPageRes.finalUrl || serviceLoginUrl).toString();
      }
      if (fa.id === "fm1") break;
    }
  }

  let submittedPassword = config.password;
  try {
    const pubRes = await requestText({ method: "GET", url: `${casRoot}/cas/v2/getPubKey` });
    if (pubRes.status === 200) {
      const pubJson = JSON.parse(pubRes.text);
      if (pubJson && pubJson.modulus && pubJson.exponent) {
        try {
          const kapRes = await requestText({ method: "GET", url: `${casRoot}/cas/v2/getKaptchaStatus` });
          if (kapRes.status === 200 && kapRes.text.trim().toLowerCase() === "true") {
            throw new PortalProtocolError("CAPTCHA_REQUIRED", "CAS 统一身份认证触发验证码校验", 403);
          }
        } catch (err) {
          if (err instanceof PortalProtocolError && err.status === "CAPTCHA_REQUIRED") throw err;
        }
        submittedPassword = zhengfangRsaEncrypt(
          config.password,
          String(pubJson.modulus),
          String(pubJson.exponent),
        );
      }
    }
  } catch (err) {
    if (err instanceof PortalProtocolError && err.status === "CAPTCHA_REQUIRED") throw err;
  }

  const pairs = [
    ["username", config.username],
    ["password", submittedPassword],
  ];
  if (execution) pairs.push(["execution", execution]);
  if (lt) pairs.push(["lt", lt]);
  pairs.push(["_eventId", "submit"]);
  for (const h of extraHidden) pairs.push(h);

  const submitCas = await requestText({
    method: "POST",
    url: formAction,
    headers: { Referer: serviceLoginUrl },
    formPairs: pairs,
    followRedirects: false,
  });

  if (submitCas.status < 300 || submitCas.status > 399) {
    const casErr =
      getElementTextById(submitCas.text, "errormsg") ||
      getElementTextById(submitCas.text, "msg") ||
      "CAS 统一身份认证未通过，请核对 PORTAL_USERNAME 与 PORTAL_PASSWORD";
    throw new PortalProtocolError("INVALID_CREDENTIALS", casErr.slice(0, 200), 401);
  }

  const loc = firstHeaderValue(submitCas.headers, "location");
  if (loc) {
    const ticketUrl = new URL(loc, formAction).toString();
    await requestText({ method: "GET", url: ticketUrl });
  } else {
    await requestText({ method: "GET", url: serviceLoginUrl });
  }

  let homeRes = await requestText({ method: "GET", url: effectivePortal });
  if (hasNoContextPath(effectivePortal)) {
    const discovered = detectJwglxtContextPath(homeRes.text, homeRes.finalUrl);
    if (discovered) {
      effectivePortal = new URL(effectivePortal).origin + discovered;
      homeRes = await requestText({ method: "GET", url: effectivePortal });
    }
  }
  if (isLoginPageHtml(homeRes.text)) {
    throw new PortalProtocolError("SESSION_EXPIRED", "CAS 票据交换后教务端仍返回登录页", 502);
  }
  if (!jar.hasActiveCookies(nowFn())) {
    throw new PortalProtocolError("SESSION_EXPIRED", "CAS 认证后未捕获到有效教务 Cookie", 502);
  }

  const identity = parsePortalIdentity(homeRes.text);
  const detectedSys =
    config.system === "auto"
      ? (effectivePortal.toLowerCase().includes("/jsxsd") ? "QZ" : "ZF")
      : config.system;

  return {
    effectiveBaseUrl: effectivePortal,
    systemId: detectedSys,
    identity: mergeIdentity(identity, {
      studentId: config.username,
      name: "",
      department: "",
      className: "",
    }),
  };
}

async function runQingzhiFlow({ config, requestText, jar, nowFn = Date.now }) {
  let effectiveRoot = config.portalUrl;
  const origin = new URL(effectiveRoot).origin;
  const candidates = [`${effectiveRoot}/xk/LoginToXk`, `${effectiveRoot}/`];
  if (hasNoContextPath(effectiveRoot)) {
    candidates.push(`${origin}/jsxsd/xk/LoginToXk`, `${origin}/jsxsd/`);
  }

  let loginRes = null;
  for (const candidateUrl of candidates) {
    try {
      const res = await requestText({ method: "GET", url: candidateUrl });
      if (res.status === 200 && (detectSystemFromHtml(res.text) === "QZ" || isLoginPageHtml(res.text))) {
        loginRes = res;
        const finalPath = new URL(res.finalUrl).pathname;
        if (finalPath.startsWith("/jsxsd") && hasNoContextPath(effectiveRoot)) {
          effectiveRoot = `${origin}/jsxsd`;
        }
        break;
      }
    } catch (err) {
      if (err instanceof PortalProtocolError && err.status === "UNTRUSTED_URL") {
        throw err;
      }
      // Try next candidate.
    }
  }

  if (!loginRes) {
    throw new PortalProtocolError("NETWORK_ERROR", "未能定位强智教务登录页", 502);
  }

  let scode = extractScriptVar(loginRes.text, "scode");
  let sxh = extractScriptVar(loginRes.text, "sxh");
  if ((!scode || !sxh) && loginRes.text.toLowerCase().includes("flag=sess")) {
    const sessRes = await requestText({
      method: "POST",
      url: `${effectiveRoot}/Logon.do?method=logon&flag=sess`,
      headers: {
        Referer: loginRes.finalUrl,
        "X-Requested-With": "XMLHttpRequest",
      },
      formPairs: [],
    });
    const parts = sessRes.text.trim().split("#");
    if (parts.length >= 2) {
      scode = parts[0];
      sxh = parts[1];
    }
  }

  const encoded = scode && sxh
    ? encodeQingzhiScode(config.username, config.password, scode, sxh)
    : `${bytesToBase64(new TextEncoder().encode(config.username))}%%%${bytesToBase64(new TextEncoder().encode(config.password))}`;

  let actionUrl = `${effectiveRoot}/xk/LoginToXk`;
  for (const form of findTags(loginRes.text, "form")) {
    const act = (form.attrs.action || "").trim();
    if (act) {
      actionUrl = new URL(act, loginRes.finalUrl).toString();
      break;
    }
  }

  const submitRes = await requestText({
    method: "POST",
    url: actionUrl,
    headers: {
      Referer: loginRes.finalUrl,
      Origin: origin,
    },
    formPairs: [
      ["userAccount", config.username],
      ["userPassword", ""],
      ["encoded", encoded],
    ],
  });

  const qzErr = getElementTextById(submitRes.text, "showMsg");
  if (qzErr || isLoginPageHtml(submitRes.text)) {
    throw new PortalProtocolError(
      qzErr && qzErr.includes("验证码") ? "CAPTCHA_REQUIRED" : "INVALID_CREDENTIALS",
      qzErr || "强智教务未接受本次登录，请核对学号与密码",
      401,
    );
  }
  if (!jar.hasActiveCookies(nowFn())) {
    throw new PortalProtocolError("SESSION_EXPIRED", "强智登录后未捕获到有效 Cookie", 502);
  }

  const identity = parsePortalIdentity(submitRes.text);
  return {
    effectiveBaseUrl: effectiveRoot,
    systemId: config.system === "QZ_OLD" ? "QZ_OLD" : "QZ",
    identity: mergeIdentity(identity, {
      studentId: config.username,
      name: "",
      department: "",
      className: "",
    }),
  };
}

export async function probeSessionAlive({
  effectiveBaseUrl,
  systemId = "ZF",
  jar,
  policy,
  fetchImpl = fetch,
  timeoutMs = 15000,
  allowPrivateLoopback = false,
  nowFn = Date.now,
}) {
  if (!jar.hasActiveCookies(nowFn())) {
    return { alive: false, cookiesMutated: false, identity: { studentId: "", name: "", department: "", className: "" } };
  }
  const root = trimTrailingSlash(effectiveBaseUrl);
  const upperSys = String(systemId || "ZF").toUpperCase();
  const probeUrls = upperSys.startsWith("QZ")
    ? [`${root}/framework/xsMain.jsp`, `${root}/`]
    : [
        `${root}/xtgl/index_cxYhxxIndex.html?xt=jw&localeKey=zh_CN&gnmkdm=index`,
        `${root}/xtgl/index_initMenu.html?jsdm=xs`,
      ];

  let anyCookiesMutated = false;
  for (const probeUrl of probeUrls) {
    try {
      const ex = await executeWithCookieJar({
        method: "GET",
        url: probeUrl,
        headers: { Accept: "text/html,application/xhtml+xml,application/json,*/*;q=0.8" },
        followRedirects: true,
        jar,
        policy,
        fetchImpl,
        timeoutMs,
        allowPrivateLoopback,
        nowFn,
      });
      if (ex.cookiesMutated) anyCookiesMutated = true;
      if (ex.status === 200 && !isSessionExpiredExchange(ex)) {
        const ct = firstHeaderValue(ex.headers, "content-type");
        const text = decodePortalText(ex.bodyBytes, ct);
        return {
          alive: true,
          effectiveBaseUrl: root,
          systemId: upperSys,
          cookiesMutated: anyCookiesMutated,
          identity: parsePortalIdentity(text),
        };
      }
    } catch (err) {
      if (err instanceof PortalProtocolError && err.status === "UNTRUSTED_URL") {
        throw err;
      }
      // Try next probe endpoint.
    }
  }
  return {
    alive: false,
    cookiesMutated: anyCookiesMutated,
    identity: { studentId: "", name: "", department: "", className: "" },
  };
}
