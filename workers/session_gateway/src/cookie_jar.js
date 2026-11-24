/**
 * Serializable RFC 6265 CookieJar persisted inside PortalSessionVault Durable Object.
 */

import {
  MAX_COOKIE_PAIR_BYTES,
  cookieDomainMatch,
  cookiePathMatch,
  defaultCookiePath,
  isPublicSuffixOrInvalidCookieDomain,
  isValidCookieName,
  isValidCookieValue,
  parseSetCookieLine,
  safeParseUrl,
} from "./net_policy.js";

export {
  MAX_COOKIE_PAIR_BYTES,
  cookieDomainMatch,
  cookiePathMatch,
  defaultCookiePath,
  isPublicSuffixOrInvalidCookieDomain,
  isValidCookieName,
  isValidCookieValue,
  parseSetCookieLine,
};

export const MAX_JAR_COOKIES = 128;

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
