/**
 * Standalone Stateful CourseLens Session Gateway (Cloudflare Workers + Durable Objects).
 *
 * Routes:
 * - `GET` / `HEAD` / `OPTIONS` `/health`     -> Public health check JSON;
 * - `GET` `/v1/session`                      -> Verify/establish portal session & return metadata (API Key required);
 * - `POST` `/v1/session/refresh`             -> Force re-login on portal (API Key required);
 * - `POST` `/v1/session/cookies`             -> Inject dynamically captured SSO/QR cookies into Vault (API Key required);
 * - `DELETE` `/v1/session`                   -> Clear cached portal cookies in Durable Object (API Key required);
 * - `POST` `/v1/proxy`                       -> Stateful portal HTTP proxy with server-injected CookieJar, auto-relogin & dual-layer read cache (API Key required);
 * - `POST` `/v1/selection`                   -> Explicitly confirmed course selection/drop write proxy (API Key + confirmed=true required);
 * - `GET|DELETE` `/v1/cache`                 -> Inspect proxy cache stats or clear all/category cached entries (API Key required);
 * - `GET` `/v1/tasks`                        -> List all cloud background tasks & switch states (API Key required);
 * - `GET|PATCH|PUT|DELETE` `/v1/tasks/:id`   -> Inspect task detail/logs, toggle task switch, or remove/reset task (API Key required);
 * - `POST` `/v1/tasks/:id/run`               -> Trigger immediate task execution (write tasks require confirmed=true);
 * - `GET|PUT|DELETE|POST` `/v1/webhook*`     -> Multi-provider Webhook notification settings & test dispatch;
 * - `GET|PUT|POST` `/v1/monitor*`            -> Periodic grade & exam change monitor settings & manual check.
 */

import { PortalSessionVault } from "./session_vault.js";

export { PortalSessionVault };

// 网关版本号：与 CLI 版本保持一致（Dart 侧 CliUpdater.gatewayVersion 同步）。
const GATEWAY_VERSION = "1.1.8";

const FORBIDDEN_PLACEHOLDER_KEYS = new Set([
  "cl_sk_replace_with_32_bytes_random_hex",
  "replace_with_32_bytes_random_hex",
]);

const BASE_SECURITY_HEADERS = {
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Referrer-Policy": "no-referrer",
};

export default {
  async fetch(request, env) {
    const cors = resolveCorsPolicy(request, env);
    const corsHeaders = buildResponseHeaders(cors);

    if (request.method === "OPTIONS") {
      if (!cors.allowed) {
        return withHeaders(
          jsonResponse(403, {
            status: "FORBIDDEN_ORIGIN",
            error: "请求来源不在 CORS_ORIGIN 允许列表内",
          }),
          corsHeaders,
        );
      }
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    const url = new URL(request.url);
    if (url.pathname === "/health") {
      if (request.method === "GET") {
        return withHeaders(
          jsonResponse(200, {
            ok: true,
            service: "courselens-session-gateway",
            mode: "stateful-worker",
            version: GATEWAY_VERSION,
          }),
          corsHeaders,
        );
      }
      if (request.method === "HEAD") {
        return new Response(null, {
          status: 200,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json; charset=utf-8",
          },
        });
      }
      return withHeaders(jsonResponse(404, { status: "NOT_FOUND", error: "Not Found" }), corsHeaders);
    }

    if (!url.pathname.startsWith("/v1/")) {
      return withHeaders(jsonResponse(404, { status: "NOT_FOUND", error: "Not Found" }), corsHeaders);
    }

    if (!cors.allowed) {
      return withHeaders(
        jsonResponse(403, {
          status: "FORBIDDEN_ORIGIN",
          error: "请求来源不在 CORS_ORIGIN 允许列表内",
        }),
        corsHeaders,
      );
    }

    const configuredKeys = extractConfiguredApiKeys(env);
    if (configuredKeys.length === 0) {
      return withHeaders(
        jsonResponse(500, {
          status: "CONFIG_ERROR",
          error: "Worker 尚未配置有效的 COURSELENS_API_KEY（严禁使用示例占位密钥）",
        }),
        corsHeaders,
      );
    }

    const providedKey = extractRequestApiKey(request);
    const authorized = await verifyApiKeyConstantTime(providedKey, configuredKeys);
    if (!authorized) {
      return withHeaders(
        jsonResponse(
          401,
          {
            status: "UNAUTHORIZED",
            error: "API Key 无效或未提供",
          },
          { "WWW-Authenticate": 'Bearer realm="courselens-session-gateway"' },
        ),
        corsHeaders,
      );
    }

    if (!env || !env.SESSION_VAULT) {
      return withHeaders(
        jsonResponse(500, {
          status: "CONFIG_ERROR",
          error: "Durable Object 绑定 SESSION_VAULT 未就绪",
        }),
        corsHeaders,
      );
    }

    const id = env.SESSION_VAULT.idFromName("primary");
    const stub = env.SESSION_VAULT.get(id);
    const doResponse = await stub.fetch(request);
    return withHeaders(doResponse, corsHeaders);
  },
};

export function extractConfiguredApiKeys(env = {}) {
  const raw = String(env.COURSELENS_API_KEY || env.API_KEY || "").trim();
  if (!raw) return [];
  return raw
    .split(",")
    .map((k) => k.trim())
    .filter((k) => k.length > 0 && !FORBIDDEN_PLACEHOLDER_KEYS.has(k.toLowerCase()));
}

export function resolveCorsPolicy(request, env = {}) {
  const rawCfg = String((env && env.CORS_ORIGIN) || "*").trim() || "*";
  if (rawCfg === "*") {
    return { allowed: true, allowOrigin: "*", varyOrigin: false };
  }
  const allowlist = rawCfg
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  if (allowlist.length === 0 || allowlist.includes("*")) {
    return { allowed: true, allowOrigin: "*", varyOrigin: false };
  }
  const reqOrigin = (request.headers.get("origin") || "").trim();
  if (!reqOrigin) {
    return { allowed: true, allowOrigin: allowlist[0], varyOrigin: true };
  }
  if (allowlist.includes(reqOrigin)) {
    return { allowed: true, allowOrigin: reqOrigin, varyOrigin: true };
  }
  return { allowed: false, allowOrigin: null, varyOrigin: true };
}

function buildResponseHeaders(cors) {
  const headers = {
    ...BASE_SECURITY_HEADERS,
    "Access-Control-Allow-Methods": "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS",
    "Access-Control-Allow-Headers":
      "Content-Type, Authorization, X-CourseLens-Key, X-CourseLens-Cache",
    "Access-Control-Expose-Headers":
      "X-CourseLens-Cache, X-CourseLens-Cache-Category, X-CourseLens-Cache-Age",
  };
  if (cors.allowOrigin) {
    headers["Access-Control-Allow-Origin"] = cors.allowOrigin;
  }
  if (cors.varyOrigin) {
    headers["Vary"] = "Origin";
  }
  return headers;
}

export function extractRequestApiKey(request) {
  const auth = request.headers.get("authorization") || "";
  const bearerMatch = /^Bearer\s+(.+)$/i.exec(auth.trim());
  if (bearerMatch && bearerMatch[1].trim()) {
    return bearerMatch[1].trim();
  }
  const custom = request.headers.get("x-courselens-key") || "";
  return custom.trim();
}

export async function verifyApiKeyConstantTime(candidate, validKeys) {
  if (!candidate || !Array.isArray(validKeys) || validKeys.length === 0) {
    return false;
  }
  const encoder = new TextEncoder();
  const candidateDigest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", encoder.encode(candidate)),
  );

  let matched = false;
  for (const valid of validKeys) {
    const validDigest = new Uint8Array(
      await crypto.subtle.digest("SHA-256", encoder.encode(valid)),
    );
    if (constantTimeBytesEqual(candidateDigest, validDigest)) {
      matched = true;
    }
  }
  return matched;
}

function constantTimeBytesEqual(a, b) {
  if (a.byteLength !== b.byteLength) return false;
  if (typeof crypto.subtle.timingSafeEqual === "function") {
    return crypto.subtle.timingSafeEqual(a, b);
  }
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff === 0;
}

function jsonResponse(status, obj, extraHeaders = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      ...extraHeaders,
    },
  });
}

function withHeaders(response, extraHeaders) {
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries(extraHeaders)) {
    if (k.toLowerCase() === "vary" && headers.has("Vary")) {
      const existing = headers.get("Vary") || "";
      if (!existing.toLowerCase().split(",").map((s) => s.trim()).includes(v.toLowerCase())) {
        headers.set("Vary", `${existing}, ${v}`);
      }
      continue;
    }
    headers.set(k, v);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
