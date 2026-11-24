/**
 * Network policy helpers shared by both Cloudflare Workers (stateless relay
 * `relay/cloudflare_worker.js` and stateful `workers/session_gateway`):
 * HostPolicy allowlist, SSRF private/reserved address checks, same-host
 * redirect upgrade, RFC 6265 Set-Cookie parsing and Base64 codecs.
 *
 * The reserved address ranges are mirrored by `CourseLensRelayServer.isPrivateOrLoopbackAddress`
 * in `tools/relay_server.dart`; both are pinned by `test/fixtures/ssrf_reserved_ranges.json`.
 */

export class PortalProtocolError extends Error {
  constructor(status, message, httpStatus = 502) {
    super(message);
    this.name = "PortalProtocolError";
    this.status = status;
    this.httpStatus = httpStatus;
  }
}

export function isHostAllowed(targetUrl, allowedHosts, requireSecure) {
  let u;
  try {
    u = new URL(targetUrl);
  } catch {
    return false;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return false;
  if (u.username || u.password) return false;
  if (requireSecure && u.protocol !== "https:") return false;

  const targetHost = u.hostname.replace(/\.+$/, "").toLowerCase();
  if (!targetHost) return false;
  const targetPort = u.port ? Number(u.port) : (u.protocol === "https:" ? 443 : 80);

  for (const rawEntry of allowedHosts) {
    const trimmed = String(rawEntry || "").trim();
    if (!trimmed || trimmed.includes("*") || trimmed.includes("@")) continue;
    const hasExplicitScheme = trimmed.includes("://");
    const candidate = hasExplicitScheme ? trimmed : `https://${trimmed}`;
    let entryUrl;
    try {
      entryUrl = new URL(candidate);
    } catch {
      continue;
    }
    if (entryUrl.protocol !== "http:" && entryUrl.protocol !== "https:") continue;
    if (
      entryUrl.username ||
      entryUrl.password ||
      (entryUrl.pathname && entryUrl.pathname !== "/") ||
      entryUrl.search ||
      entryUrl.hash
    ) {
      continue;
    }
    const entryHost = entryUrl.hostname.replace(/\.+$/, "").toLowerCase();
    if (entryHost !== targetHost) continue;

    if (hasExplicitScheme) {
      // Never allow plaintext HTTP downgrade on an origin explicitly configured as https://
      if (entryUrl.protocol === "https:" && u.protocol !== "https:") continue;
      if (entryUrl.port) {
        if (entryUrl.protocol !== u.protocol || Number(entryUrl.port) !== targetPort) {
          continue;
        }
      } else if (entryUrl.protocol === "https:") {
        if (targetPort !== 443) continue;
      } else {
        // Explicit http:// without custom port: allow http:80 and transparent https:443 upgrade only.
        const validDefaultPort =
          (u.protocol === "http:" && targetPort === 80) ||
          (u.protocol === "https:" && targetPort === 443);
        if (!validDefaultPort) continue;
      }
    } else if (entryUrl.port) {
      if (Number(entryUrl.port) !== targetPort) continue;
    } else {
      const validDefaultPort =
        (u.protocol === "https:" && targetPort === 443) ||
        (u.protocol === "http:" && targetPort === 80);
      if (!validDefaultPort) continue;
    }
    return true;
  }
  return false;
}

function isPrivateOrReservedIpv4Octets(a, b, c, d) {
  if (
    !Number.isInteger(a) ||
    !Number.isInteger(b) ||
    !Number.isInteger(c) ||
    !Number.isInteger(d) ||
    a < 0 ||
    a > 255 ||
    b < 0 ||
    b > 255 ||
    c < 0 ||
    c > 255 ||
    d < 0 ||
    d > 255
  ) {
    return true;
  }
  if (a === 0 || a === 10 || a === 127) return true;
  if (a === 100 && b >= 64 && b <= 127) return true; // RFC 6598 CGNAT 100.64.0.0/10
  if (a === 169 && b === 254) return true; // Link-local / Cloud Metadata 169.254.0.0/16
  if (a === 172 && b >= 16 && b <= 31) return true; // RFC 1918 172.16.0.0/12
  if (a === 192 && b === 0 && c === 0) return true; // IETF Protocol Assignments 192.0.0.0/24
  if (a === 192 && b === 0 && c === 2) return true; // TEST-NET-1 192.0.2.0/24
  if (a === 192 && b === 168) return true; // RFC 1918 192.168.0.0/16
  if (a === 198 && (b === 18 || b === 19)) return true; // Benchmarking 198.18.0.0/15
  if (a === 198 && b === 51 && c === 100) return true; // TEST-NET-2
  if (a === 203 && b === 0 && c === 113) return true; // TEST-NET-3
  if (a >= 224) return true; // Multicast 224.0.0.0/4 & Reserved/Broadcast 240.0.0.0/4
  return false;
}

function parseIpv6Words(rawIpv6) {
  const zoneIdx = rawIpv6.indexOf("%");
  const addr = zoneIdx >= 0 ? rawIpv6.slice(0, zoneIdx) : rawIpv6;
  if (!addr || !addr.includes(":")) return null;

  let working = addr;
  // Convert trailing dotted IPv4 (e.g. ::ffff:127.0.0.1) into two 16-bit hex groups.
  const lastColon = working.lastIndexOf(":");
  const tail = working.slice(lastColon + 1);
  if (tail.includes(".")) {
    const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(tail);
    if (!v4) return null;
    const octets = [Number(v4[1]), Number(v4[2]), Number(v4[3]), Number(v4[4])];
    if (octets.some((o) => o < 0 || o > 255)) return null;
    const hi = ((octets[0] << 8) | octets[1]).toString(16);
    const lo = ((octets[2] << 8) | octets[3]).toString(16);
    working = `${working.slice(0, lastColon + 1)}${hi}:${lo}`;
  }

  const dblParts = working.split("::");
  if (dblParts.length > 2) return null;

  const parseSide = (side) => {
    if (!side) return [];
    const groups = side.split(":");
    const words = [];
    for (const g of groups) {
      if (!/^[0-9a-f]{1,4}$/i.test(g)) return null;
      words.push(Number.parseInt(g, 16));
    }
    return words;
  };

  if (dblParts.length === 1) {
    const words = parseSide(dblParts[0]);
    return words && words.length === 8 ? words : null;
  }

  const left = parseSide(dblParts[0]);
  const right = parseSide(dblParts[1]);
  if (!left || !right || left.length + right.length >= 8) return null;
  const zeros = new Array(8 - left.length - right.length).fill(0);
  return [...left, ...zeros, ...right];
}

function checkEmbeddedV4Words(hiWord, loWord) {
  return isPrivateOrReservedIpv4Octets(
    (hiWord >> 8) & 0xff,
    hiWord & 0xff,
    (loWord >> 8) & 0xff,
    loWord & 0xff,
  );
}

export function isPrivateOrLoopbackHost(hostname) {
  const h = String(hostname || "")
    .trim()
    .replace(/^\[|\]$/g, "")
    .replace(/\.+$/g, "")
    .toLowerCase();
  if (
    !h ||
    h === "localhost" ||
    h.endsWith(".localhost") ||
    h.endsWith(".local") ||
    h.endsWith(".internal")
  ) {
    return true;
  }

  if (h.includes(":")) {
    const words = parseIpv6Words(h);
    // Fail closed if IPv6 literal cannot be parsed cleanly.
    if (!words) return true;
    const [w0, w1, w2, w3, w4, w5, w6, w7] = words;

    // ::/128 unspecified or ::1/128 loopback
    if (w0 === 0 && w1 === 0 && w2 === 0 && w3 === 0 && w4 === 0 && w5 === 0 && w6 === 0 && (w7 === 0 || w7 === 1)) {
      return true;
    }
    // ::/96 IPv4-compatible IPv6 & ::ffff:0:0/96 IPv4-mapped IPv6
    if (w0 === 0 && w1 === 0 && w2 === 0 && w3 === 0 && w4 === 0 && (w5 === 0 || w5 === 0xffff)) {
      return checkEmbeddedV4Words(w6, w7);
    }
    // ::ffff:0:0:0/96 IPv4-translated addresses (RFC 2765)
    if (w0 === 0 && w1 === 0 && w2 === 0 && w3 === 0 && w4 === 0xffff && w5 === 0) {
      return checkEmbeddedV4Words(w6, w7);
    }
    // 64:ff9b::/96 NAT64 well-known prefix (RFC 6052)
    if (w0 === 0x0064 && w1 === 0xff9b && w2 === 0 && w3 === 0 && w4 === 0 && w5 === 0) {
      return checkEmbeddedV4Words(w6, w7);
    }
    // 64:ff9b:1::/48 NAT64 local-use private translation prefix (RFC 8215)
    if (w0 === 0x0064 && w1 === 0xff9b && w2 === 1) {
      return true;
    }
    // 2002::/16 6to4 embedding IPv4 in w1..w2
    if (w0 === 0x2002 && checkEmbeddedV4Words(w1, w2)) {
      return true;
    }
    // 100::/64 Discard-Only (RFC 6666)
    if (w0 === 0x0100 && w1 === 0 && w2 === 0 && w3 === 0) return true;
    // 2001:db8::/32 Documentation (RFC 3849)
    if (w0 === 0x2001 && w1 === 0x0db8) return true;
    // fc00::/7 Unique Local (fc00..fdff)
    if ((w0 & 0xfe00) === 0xfc00) return true;
    // fe80::/10 Link-Local (fe80..febf)
    if ((w0 & 0xffc0) === 0xfe80) return true;
    // fec0::/10 deprecated Site-Local (RFC 3879)
    if ((w0 & 0xffc0) === 0xfec0) return true;
    // ff00::/8 Multicast
    if ((w0 & 0xff00) === 0xff00) return true;
    return false;
  }

  // Block pure numeric/hex single-label IPv4 representations (if not already normalized by WHATWG URL).
  if (/^(?:0x[0-9a-f]+|\d+)$/i.test(h)) {
    return true;
  }

  const v4 = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(h);
  if (v4) {
    return isPrivateOrReservedIpv4Octets(
      Number(v4[1]),
      Number(v4[2]),
      Number(v4[3]),
      Number(v4[4]),
    );
  }
  return false;
}

export function upgradeSameHostHttpRedirect(currentUrl, targetUrl) {
  let src;
  let dst;
  try {
    src = new URL(currentUrl);
    dst = new URL(targetUrl);
  } catch {
    return targetUrl;
  }
  if (src.username || src.password || dst.username || dst.password) {
    return targetUrl;
  }
  const srcDefaultHttps =
    src.protocol === "https:" && (src.port === "" || src.port === "443");
  const dstDefaultHttp =
    dst.protocol === "http:" && (dst.port === "" || dst.port === "80");
  if (
    srcDefaultHttps &&
    dstDefaultHttp &&
    src.hostname.replace(/\.+$/, "").toLowerCase() ===
      dst.hostname.replace(/\.+$/, "").toLowerCase()
  ) {
    dst.protocol = "https:";
    dst.port = "";
    return dst.toString();
  }
  return targetUrl;
}

export function bytesToBase64(bytes) {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

export function base64ToBytes(b64) {
  let clean = String(b64 || "")
    .replace(/\s+/g, "")
    .replace(/-/g, "+")
    .replace(/_/g, "/");
  if (!clean) return new Uint8Array(0);
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(clean) || clean.length % 4 === 1) {
    throw new PortalProtocolError("VALIDATION_FAILED", "无效的 Base64 编码请求体", 400);
  }
  while (clean.length % 4 !== 0) {
    clean += "=";
  }
  let binary;
  try {
    binary = atob(clean);
  } catch {
    throw new PortalProtocolError("VALIDATION_FAILED", "无效的 Base64 编码请求体", 400);
  }
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    out[i] = binary.charCodeAt(i);
  }
  return out;
}

export const MAX_COOKIE_PAIR_BYTES = 4096;

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

export function safeParseUrl(raw) {
  try {
    return new URL(String(raw));
  } catch {
    return null;
  }
}
