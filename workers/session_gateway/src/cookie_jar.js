/**
 * Serializable RFC 6265 CookieJar persisted inside PortalSessionVault Durable Object.
 */

export const MAX_COOKIE_PAIR_BYTES = 4096;
export const MAX_JAR_COOKIES = 128;

const TWO_LABEL_PUBLIC_SUFFIXES = new Set([
  "edu.cn",
  "ac.cn",
  "gov.cn",
  "org.cn",
  "com.cn",
  "net.cn",
  "mil.cn",
  "edu.hk",
  "org.hk",
  "com.hk",
  "gov.hk",
  "net.hk",
  "edu.mo",
  "gov.mo",
  "org.mo",
  "com.mo",
  "edu.tw",
  "org.tw",
  "com.tw",
  "gov.tw",
  "net.tw",
  "ac.uk",
  "co.uk",
  "org.uk",
  "gov.uk",
  "edu.au",
  "com.au",
  "org.au",
  "gov.au",
  "ac.jp",
  "co.jp",
  "or.jp",
  "go.jp",
  "edu.sg",
  "com.sg",
  "edu.my",
  "com.my",
]);

const IPV4_LITERAL_RE = /^\d{1,3}(\.\d{1,3}){3}$/;
const INVALID_COOKIE_NAME_RE = /[\x00-\x20\x7f;="(),/:<>?@[\\\]{}]/;
const INVALID_COOKIE_VALUE_RE = /[\x00-\x1f\x7f;]/;

export function isValidCookieName(name) {
  return (
    typeof name === "string" &&
    name.length > 0 &&
    !name.startsWith("$") &&
    !INVALID_COOKIE_NAME_RE.test(name)
  );
}

export function isValidCookieValue(value) {
  return typeof value === "string" && !INVALID_COOKIE_VALUE_RE.test(value);
}

export function isPublicSuffixOrInvalidCookieDomain(rawDomain) {
  const domain = String(rawDomain || "")
    .trim()
    .replace(/^\.+|\.+$/g, "")
    .toLowerCase();
  if (!domain) return true;
  if (
    domain === "localhost" ||
    domain.includes(":") ||
    domain.startsWith("[") ||
    IPV4_LITERAL_RE.test(domain)
  ) {
    return true;
  }
  const labels = domain.split(".");
  if (labels.length < 2 || labels.some((l) => !l)) {
    return true;
  }
  return TWO_LABEL_PUBLIC_SUFFIXES.has(domain);
}

export function defaultCookiePath(urlPathname) {
  if (!urlPathname || !urlPathname.startsWith("/")) return "/";
  if (urlPathname === "/") return "/";
  const lastSlash = urlPathname.lastIndexOf("/");
  if (lastSlash <= 0) return "/";
  return urlPathname.slice(0, lastSlash);
}

export function cookieDomainMatch(host, domain) {
  if (host === domain) return true;
  if (!domain || host.length <= domain.length) return false;
  return host.endsWith(domain) && host[host.length - domain.length - 1] === ".";
}

export function cookiePathMatch(urlPath, cookiePath) {
  const target = urlPath || "/";
  if (target === cookiePath) return true;
  if (!target.startsWith(cookiePath)) return false;
  if (cookiePath.endsWith("/")) return true;
  return target.length > cookiePath.length && target[cookiePath.length] === "/";
}

export function parseSetCookieLine(line, requestUrl, nowMs = Date.now()) {
  if (typeof line !== "string" && line != null) {
    line = String(line);
  }
  if (!line || /[\r\n\x00]/.test(line)) return null;

  const sourceUrl = requestUrl instanceof URL ? requestUrl : safeParseUrl(requestUrl);
  if (!sourceUrl) return null;

  const parts = String(line).split(";");
  const head = parts[0] || "";
  const eq = head.indexOf("=");
  if (eq <= 0) return null;

  const name = head.slice(0, eq).trim();
  if (!isValidCookieName(name)) return null;

  let value = head.slice(eq + 1).trim();
  while (value.startsWith('"')) value = value.slice(1);
  while (value.endsWith('"')) value = value.slice(0, -1);
  if (!isValidCookieValue(value)) return null;
  if (name.length + value.length > MAX_COOKIE_PAIR_BYTES) return null;

  let attrDomain = null;
  let attrPath = null;
  let secure = false;
  let maxAgeSec = null;
  let expiresMs = null;

  for (let i = 1; i < parts.length; i++) {
    const seg = parts[i];
    const sep = seg.indexOf("=");
    const attrName = (sep < 0 ? seg : seg.slice(0, sep)).trim().toLowerCase();
    const attrVal = sep < 0 ? "" : seg.slice(sep + 1).trim();
    if (attrName === "domain") {
      const cleaned = attrVal.replace(/^\.+|\.+$/g, "").toLowerCase();
      if (cleaned) attrDomain = cleaned;
    } else if (attrName === "path") {
      if (attrVal.startsWith("/") && !/[\x00-\x1f\x7f;]/.test(attrVal)) {
        attrPath = attrVal;
      }
    } else if (attrName === "secure") {
      secure = true;
    } else if (attrName === "max-age") {
      const parsedSec = Number.parseInt(attrVal, 10);
      if (!Number.isNaN(parsedSec)) maxAgeSec = parsedSec;
    } else if (attrName === "expires") {
      const parsedTime = Date.parse(attrVal);
      if (!Number.isNaN(parsedTime)) expiresMs = parsedTime;
    }
  }

  const reqHost = sourceUrl.hostname.replace(/\.+$/, "").toLowerCase();
  // RFC 6265 §5.3 Step 5: Reject public-suffix supercookies (unless exact match to request host, which becomes host-only).
  if (attrDomain !== null && isPublicSuffixOrInvalidCookieDomain(attrDomain)) {
    if (attrDomain === reqHost) {
      attrDomain = null;
    } else {
      return null;
    }
  }

  const hostOnly = attrDomain === null;
  const domain = attrDomain || reqHost;
  if (!hostOnly && !cookieDomainMatch(reqHost, domain)) {
    return null;
  }

  const effectiveExpiresMs = maxAgeSec !== null
    ? (maxAgeSec <= 0 ? nowMs - 1000 : nowMs + maxAgeSec * 1000)
    : expiresMs;
  const deleted =
    value.trim().toLowerCase() === "deleteme" ||
    (effectiveExpiresMs !== null && effectiveExpiresMs <= nowMs);

  return {
    name,
    value,
    domain,
    path: attrPath || defaultCookiePath(sourceUrl.pathname),
    hostOnly,
    secure,
    expiresMs: effectiveExpiresMs,
    deleted,
    seq: 0,
    updatedSeq: 0,
  };
}

function safeParseUrl(raw) {
  try {
    return new URL(String(raw));
  } catch {
    return null;
  }
}

export class ServerCookieJar {
  constructor() {
    this._store = new Map();
    this._seqCounter = 0;
  }

  clear() {
    this._store.clear();
    this._seqCounter = 0;
  }

  clone(nowMs = Date.now()) {
    return ServerCookieJar.fromJSON(this.toJSON(nowMs), nowMs);
  }

  replaceFrom(otherJar, nowMs = Date.now()) {
    this._store.clear();
    this._seqCounter = 0;
    if (!(otherJar instanceof ServerCookieJar)) return;
    let maxSeq = 0;
    for (const [key, entry] of otherJar._store.entries()) {
      if (entry.deleted || (entry.expiresMs !== null && entry.expiresMs <= nowMs)) {
        continue;
      }
      this._store.set(key, { ...entry });
      if (entry.seq >= maxSeq) maxSeq = entry.seq + 1;
      if (entry.updatedSeq >= maxSeq) maxSeq = entry.updatedSeq + 1;
    }
    this._seqCounter = Math.max(maxSeq, otherJar._seqCounter);
    this._evictExcessIfNeeded(nowMs);
  }

  _evictExcessIfNeeded(nowMs = Date.now()) {
    if (this._store.size <= MAX_JAR_COOKIES) return;
    for (const [key, entry] of this._store.entries()) {
      if (entry.deleted || (entry.expiresMs !== null && entry.expiresMs <= nowMs)) {
        this._store.delete(key);
      }
    }
    if (this._store.size <= MAX_JAR_COOKIES) return;
    const entries = Array.from(this._store.entries()).sort(
      (a, b) => (a[1].updatedSeq || 0) - (b[1].updatedSeq || 0),
    );
    const excess = this._store.size - MAX_JAR_COOKIES;
    for (let i = 0; i < excess; i++) {
      this._store.delete(entries[i][0]);
    }
  }

  absorbSetCookie(line, sourceUrlStr, nowMs = Date.now()) {
    const parsed = parseSetCookieLine(line, sourceUrlStr, nowMs);
    if (!parsed) return false;
    const key = `${parsed.domain}|${parsed.path}|${parsed.name}`;
    if (parsed.deleted) {
      this._store.delete(key);
      return true;
    }
    const prev = this._store.get(key);
    parsed.seq = prev ? prev.seq : this._seqCounter++;
    parsed.updatedSeq = this._seqCounter++;
    this._store.set(key, parsed);
    this._evictExcessIfNeeded(nowMs);
    return true;
  }

  absorbSetCookies(lines, sourceUrlStr, nowMs = Date.now()) {
    if (!Array.isArray(lines)) return 0;
    let changed = 0;
    for (const line of lines) {
      if (line && this.absorbSetCookie(line, sourceUrlStr, nowMs)) {
        changed += 1;
      }
    }
    return changed;
  }

  absorbSeedCookies(rawSeed, baseUrlStr, nowMs = Date.now()) {
    const trimmed = String(rawSeed || "").trim();
    if (!trimmed) return 0;
    const baseUrl = safeParseUrl(baseUrlStr);
    if (!baseUrl) return 0;

    const pairs = [];
    if (trimmed.startsWith("{")) {
      try {
        const obj = JSON.parse(trimmed);
        if (obj && typeof obj === "object" && !Array.isArray(obj)) {
          for (const [k, v] of Object.entries(obj)) {
            if (typeof k === "string" && k.trim() && v != null) {
              pairs.push([k.trim(), String(v).trim()]);
            }
          }
        }
      } catch {
        // Fall back to semicolon-separated header parsing below.
      }
    }

    if (pairs.length === 0) {
      const cleaned = trimmed.replace(/^cookie\s*:\s*/i, "");
      for (const seg of cleaned.split(";")) {
        const eq = seg.indexOf("=");
        if (eq <= 0) continue;
        const k = seg.slice(0, eq).trim();
        const v = seg.slice(eq + 1).trim();
        if (k) pairs.push([k, v]);
      }
    }

    let count = 0;
    const host = baseUrl.hostname.replace(/\.+$/, "").toLowerCase();
    const secure = baseUrl.protocol === "https:";
    for (const [name, rawVal] of pairs) {
      let value = rawVal;
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.slice(1, -1);
      }
      if (!isValidCookieName(name) || !isValidCookieValue(value)) continue;
      if (name.length + value.length > MAX_COOKIE_PAIR_BYTES) continue;
      if (value.toLowerCase() === "deleteme") continue;
      const key = `${host}|/|${name}`;
      const prev = this._store.get(key);
      this._store.set(key, {
        name,
        value,
        domain: host,
        path: "/",
        hostOnly: true,
        secure,
        expiresMs: null,
        deleted: false,
        seq: prev ? prev.seq : this._seqCounter++,
        updatedSeq: this._seqCounter++,
      });
      count += 1;
    }
    this._evictExcessIfNeeded(nowMs);
    return count;
  }

  matchingEntries(targetUrlStr, nowMs = Date.now()) {
    const u = safeParseUrl(targetUrlStr);
    if (!u) return [];
    const host = u.hostname.replace(/\.+$/, "").toLowerCase();
    const isHttps = u.protocol === "https:";
    const path = u.pathname || "/";
    const matched = [];

    for (const [key, entry] of this._store.entries()) {
      if (entry.deleted || (entry.expiresMs !== null && entry.expiresMs <= nowMs)) {
        this._store.delete(key);
        continue;
      }
      if (entry.hostOnly) {
        if (host !== entry.domain) continue;
      } else if (!cookieDomainMatch(host, entry.domain)) {
        continue;
      }
      if (entry.secure && !isHttps) continue;
      if (!cookiePathMatch(path, entry.path)) continue;
      matched.push(entry);
    }

    matched.sort((a, b) => (b.path.length - a.path.length) || (a.seq - b.seq));
    return matched;
  }

  cookieHeaderFor(targetUrlStr, nowMs = Date.now()) {
    return this.matchingEntries(targetUrlStr, nowMs)
      .map((c) => `${c.name}=${c.value}`)
      .join("; ");
  }

  size(nowMs = Date.now()) {
    for (const [key, entry] of this._store.entries()) {
      if (entry.deleted || (entry.expiresMs !== null && entry.expiresMs <= nowMs)) {
        this._store.delete(key);
      }
    }
    return this._store.size;
  }

  hasActiveCookies(nowMs = Date.now()) {
    return this.size(nowMs) > 0;
  }

  toJSON(nowMs = Date.now()) {
    const list = [];
    for (const [key, entry] of this._store.entries()) {
      if (entry.deleted || (entry.expiresMs !== null && entry.expiresMs <= nowMs)) {
        this._store.delete(key);
        continue;
      }
      list.push({
        name: entry.name,
        value: entry.value,
        domain: entry.domain,
        path: entry.path,
        hostOnly: Boolean(entry.hostOnly),
        secure: Boolean(entry.secure),
        expiresMs: entry.expiresMs ?? null,
        seq: Number(entry.seq || 0),
        updatedSeq: Number(entry.updatedSeq || 0),
      });
    }
    return list;
  }

  static fromJSON(serialized, nowMs = Date.now()) {
    const jar = new ServerCookieJar();
    if (!Array.isArray(serialized)) return jar;
    let maxSeq = 0;
    for (const item of serialized) {
      if (!item || typeof item !== "object") continue;
      const name = String(item.name || "").trim();
      const value = String(item.value ?? "");
      const domain = String(item.domain || "").trim().replace(/^\.+|\.+$/g, "").toLowerCase();
      if (!isValidCookieName(name) || !isValidCookieValue(value) || !domain) continue;
      if (name.length + value.length > MAX_COOKIE_PAIR_BYTES) continue;
      const hostOnly = item.hostOnly !== false;
      if (!hostOnly && isPublicSuffixOrInvalidCookieDomain(domain)) continue;
      const expiresMs = typeof item.expiresMs === "number" ? item.expiresMs : null;
      if (expiresMs !== null && expiresMs <= nowMs) continue;
      const rawPath = String(item.path || "/");
      const path = rawPath.startsWith("/") && !/[\x00-\x1f\x7f;]/.test(rawPath) ? rawPath : "/";
      const seq = Number.isFinite(item.seq) ? item.seq : maxSeq++;
      const updatedSeq = Number.isFinite(item.updatedSeq) ? item.updatedSeq : seq;
      if (seq >= maxSeq) maxSeq = seq + 1;
      if (updatedSeq >= maxSeq) maxSeq = updatedSeq + 1;
      jar._store.set(`${domain}|${path}|${name}`, {
        name,
        value,
        domain,
        path,
        hostOnly,
        secure: Boolean(item.secure),
        expiresMs,
        deleted: false,
        seq,
        updatedSeq,
      });
    }
    jar._seqCounter = maxSeq;
    jar._evictExcessIfNeeded(nowMs);
    return jar;
  }
}
