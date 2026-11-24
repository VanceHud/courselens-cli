import { classifyProxyCacheRequest } from "./proxy_cache.js";

const selectionWrites = new Set([
  "xsxk/zzxkyzbjk_xkbczyzzxkyzb.html",
  "xsxk/zzxkyzb_tuikbczzxkyzb.html",
]);

// Known queries that are intentionally excluded from the cache or use legacy postbacks.
const extraQueries = new Set([
  "xsxk/zzxkyzb_cxzzxkyzbindex.html",
  "xsxk/zzxkyzb_cxzzxkyzbdisplay.html",
  "xsxk/zzxkyzb_cxzzxkyzbpartdisplay.html",
  "xsxk/zzxkyzbjk_cxjxbwithkchzzxkyzb.html",
  "xsxk/zzxkyzb_cxzzxkyzbchooseddisplay.html",
  "kscj/cjcx_query",
  "xscjcx.aspx",
  "xskbcx.aspx",
  "xskscx.aspx",
]);

function portalRoute(url, policy) {
  const target = new URL(url);
  const bases = [policy.portalUrl, policy.effectiveBaseUrl].filter(Boolean);
  for (const baseUrl of bases) {
    const base = new URL(baseUrl);
    if (target.origin !== base.origin) continue;
    const root = base.pathname.replace(/\/+$/, "");
    const path = target.pathname;
    if (path === root || path === `${root}/`) return "";
    if (!path.startsWith(`${root}/`)) continue;
    const route = path.slice(root.length + 1).toLowerCase();
    if (/^[a-z0-9_.-]+(?:\/[a-z0-9_.-]+)?$/.test(route)) return route;
  }
  return null;
}

export function isSelectionWrite(url, policy) {
  return selectionWrites.has(portalRoute(url, policy));
}

export function isReadOnlyProxyRequest(method, url, policy) {
  const verb = String(method || "").toUpperCase();
  if (verb !== "GET" && verb !== "POST") return false;
  const route = portalRoute(url, policy);
  if (route === null || selectionWrites.has(route)) return false;
  if (!route) return verb === "GET";
  if (extraQueries.has(route)) return true;
  return classifyProxyCacheRequest({
    method: verb, url, cacheConfig: { enabled: true },
  }).cacheable;
}
