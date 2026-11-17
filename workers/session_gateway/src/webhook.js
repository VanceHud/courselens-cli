/**
 * Multi-provider SSRF-hardened Webhook notification dispatcher for `PortalSessionVault`.
 *
 * Supported providers:
 * - `bark`     (iOS Bark Push: `https://api.day.app/<deviceKey>`)
 * - `feishu`   (飞书群自定义机器人，支持可选加签密钥)
 * - `dingtalk` (钉钉群自定义机器人，支持可选 `SEC...` 加签密钥)
 * - `wecom`    (企业微信群机器人)
 * - `telegram` (Telegram Bot API `sendMessage` with `chatId`)
 * - `generic`  (标准 JSON POST + `X-CourseLens-Signature: sha256=<hex>` HMAC-SHA256)
 */

import { PortalProtocolError, bytesToBase64, isPrivateOrLoopbackHost } from "./protocol.js";

const VALID_PROVIDERS = new Set([
  "auto",
  "bark",
  "feishu",
  "dingtalk",
  "wecom",
  "telegram",
  "generic",
]);

export function createDefaultWebhookConfig() {
  return {
    enabled: false,
    provider: "auto",
    url: "",
    secret: "",
    telegramChatId: "",
    onGradeChange: true,
    onExamChange: true,
    updatedAtMs: null,
    lastSentAtMs: null,
    lastError: "",
  };
}

export function detectWebhookProvider(urlStr, explicitProvider = "auto") {
  const norm = String(explicitProvider || "auto").trim().toLowerCase();
  if (VALID_PROVIDERS.has(norm) && norm !== "auto") {
    return norm;
  }
  let u;
  try {
    u = new URL(urlStr);
  } catch {
    return "generic";
  }
  const host = u.hostname.toLowerCase();
  const path = u.pathname.toLowerCase();
  if (host === "api.day.app" || path.includes("/bark")) return "bark";
  if (host.endsWith("feishu.cn") || host.endsWith("larksuite.com")) return "feishu";
  if (host.endsWith("dingtalk.com")) return "dingtalk";
  if (host === "qyapi.weixin.qq.com") return "wecom";
  if (host === "api.telegram.org") return "telegram";
  return "generic";
}

export function validateWebhookUrl(rawUrl, { allowPrivateLoopback = false } = {}) {
  const s = String(rawUrl || "").trim();
  if (!s) {
    throw new PortalProtocolError("VALIDATION_FAILED", "Webhook URL 不能为空", 400);
  }
  let parsed;
  try {
    parsed = new URL(s);
  } catch {
    throw new PortalProtocolError("VALIDATION_FAILED", "Webhook URL 不是合法的 URL", 400);
  }
  if (parsed.username || parsed.password) {
    throw new PortalProtocolError(
      "UNTRUSTED_URL",
      "Webhook URL 严禁内嵌用户名或密码字段",
      400,
    );
  }
  if (parsed.protocol !== "https:") {
    if (!(allowPrivateLoopback && parsed.protocol === "http:")) {
      throw new PortalProtocolError(
        "UNTRUSTED_URL",
        "Webhook URL 必须使用 https:// 加密传输",
        400,
      );
    }
  }
  if (!allowPrivateLoopback && isPrivateOrLoopbackHost(parsed.hostname)) {
    throw new PortalProtocolError(
      "UNTRUSTED_URL",
      `SSRF 防护拦截：禁止将内网、环回或云元数据地址配置为 Webhook（${parsed.hostname}）`,
      403,
    );
  }
  return parsed.toString();
}

export function maskWebhookUrl(rawUrl) {
  const s = String(rawUrl || "").trim();
  if (!s) return "";
  try {
    const u = new URL(s);
    const segs = u.pathname.split("/").filter(Boolean);
    const maskedSegs = segs.map((seg, idx) => {
      if (idx === segs.length - 1 && seg.length > 8) {
        return `${seg.slice(0, 3)}••••${seg.slice(-3)}`;
      }
      if (/^bot\d+:/i.test(seg)) {
        return "bot••••";
      }
      return seg;
    });
    const hasQuery = Array.from(u.searchParams.keys()).length > 0;
    const pathPart = maskedSegs.length > 0 ? `/${maskedSegs.join("/")}` : "";
    return `${u.protocol}//${u.host}${pathPart}${hasQuery ? "?•••" : ""}`;
  } catch {
    return "•••";
  }
}

export function sanitizeWebhookConfigForClient(cfg) {
  const c = cfg || createDefaultWebhookConfig();
  const hasUrl = Boolean(String(c.url || "").trim());
  return {
    configured: hasUrl,
    enabled: Boolean(c.enabled && hasUrl),
    provider: c.provider || "auto",
    resolvedProvider: hasUrl ? detectWebhookProvider(c.url, c.provider) : "generic",
    maskedUrl: maskWebhookUrl(c.url),
    hasSecret: Boolean(String(c.secret || "").trim()),
    telegramChatId: String(c.telegramChatId || ""),
    onGradeChange: c.onGradeChange !== false,
    onExamChange: c.onExamChange !== false,
    updatedAt: c.updatedAtMs ? new Date(c.updatedAtMs).toISOString() : null,
    lastSentAt: c.lastSentAtMs ? new Date(c.lastSentAtMs).toISOString() : null,
    lastError: c.lastError || "",
  };
}

async function hmacSha256Bytes(secretStr, messageStr) {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secretStr),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(messageStr));
  return new Uint8Array(sig);
}

function bytesToHex(bytes) {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export function shouldSendWebhookForEvent(cfg, eventType) {
  if (!cfg || !cfg.enabled || !String(cfg.url || "").trim()) return false;
  switch (eventType) {
    case "grade_change":
      return cfg.onGradeChange !== false;
    case "exam_change":
      return cfg.onExamChange !== false;
    case "test":
      return true;
    default:
      return true;
  }
}

export async function dispatchWebhookNotification({
  cfg,
  event = "info",
  title,
  body,
  meta = {},
  fetchImpl = fetch,
  allowPrivateLoopback = false,
  nowFn = Date.now,
  timeoutMs = 10000,
}) {
  const targetBaseUrl = validateWebhookUrl(cfg.url, { allowPrivateLoopback });
  const provider = detectWebhookProvider(targetBaseUrl, cfg.provider);
  const nowMs = nowFn();
  const secret = String(cfg.secret || "").trim();

  let requestUrl = targetBaseUrl;
  const headers = {
    "Content-Type": "application/json; charset=utf-8",
    "User-Agent": "CourseLens-SessionGateway/1.0",
  };
  let payloadObj;

  if (provider === "bark") {
    payloadObj = {
      title: String(title || "CourseLens 通知"),
      body: String(body || ""),
      group: "CourseLens",
    };
  } else if (provider === "feishu") {
    const timestampSec = String(Math.floor(nowMs / 1000));
    payloadObj = {
      msg_type: "text",
      content: {
        text: `${title}\n${body}`,
      },
    };
    if (secret) {
      const stringToSign = `${timestampSec}\n${secret}`;
      const sigBytes = await hmacSha256Bytes(stringToSign, "");
      payloadObj.timestamp = timestampSec;
      payloadObj.sign = bytesToBase64(sigBytes);
    }
  } else if (provider === "dingtalk") {
    if (secret) {
      const stringToSign = `${nowMs}\n${secret}`;
      const sigBytes = await hmacSha256Bytes(secret, stringToSign);
      const u = new URL(requestUrl);
      u.searchParams.set("timestamp", String(nowMs));
      u.searchParams.set("sign", bytesToBase64(sigBytes));
      requestUrl = u.toString();
    }
    payloadObj = {
      msgtype: "text",
      text: {
        content: `${title}\n${body}`,
      },
    };
  } else if (provider === "wecom") {
    payloadObj = {
      msgtype: "text",
      text: {
        content: `${title}\n${body}`,
      },
    };
  } else if (provider === "telegram") {
    const u = new URL(requestUrl);
    if (!u.pathname.toLowerCase().endsWith("/sendmessage") && /^\/bot[^/]+\/?$/i.test(u.pathname)) {
      u.pathname = `${u.pathname.replace(/\/$/, "")}/sendMessage`;
      requestUrl = u.toString();
    }
    const chatId = String(cfg.telegramChatId || u.searchParams.get("chat_id") || "").trim();
    payloadObj = {
      chat_id: chatId,
      text: `${title}\n\n${body}`,
    };
  } else {
    payloadObj = {
      event,
      title,
      body,
      timestamp: new Date(nowMs).toISOString(),
      ...meta,
    };
  }

  const rawJson = JSON.stringify(payloadObj);
  if (provider === "generic" && secret) {
    const sigBytes = await hmacSha256Bytes(secret, `${nowMs}.${rawJson}`);
    headers["X-CourseLens-Timestamp"] = String(nowMs);
    headers["X-CourseLens-Signature"] = `sha256=${bytesToHex(sigBytes)}`;
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(requestUrl, {
      method: "POST",
      headers,
      body: rawJson,
      // Security Redline #4: Never follow redirects on outbound Webhooks (prevents open-redirect SSRF).
      redirect: "manual",
      signal: controller.signal,
    });
    if (res.status >= 300 && res.status < 400) {
      return {
        ok: false,
        status: res.status,
        error: "Webhook 目标返回重定向响应，已按安全策略拦截",
      };
    }
    if (res.status < 200 || res.status > 299) {
      return {
        ok: false,
        status: res.status,
        error: `Webhook 返回 HTTP ${res.status}`,
      };
    }
    return { ok: true, status: res.status, provider };
  } catch (err) {
    return {
      ok: false,
      status: 0,
      error: `Webhook 发送失败：${err.message || err}`,
    };
  } finally {
    clearTimeout(timer);
  }
}
