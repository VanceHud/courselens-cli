/**
 * PortalSessionVault Durable Object (SQLite-backed).
 *
 * Responsibilities:
 * 1. Persist server-side RFC 6265 CookieJar & Webhook secrets (encrypted at rest via AES-256-GCM);
 * 2. Deduplicate concurrent cold-start or expired-session logins via generation-aware single-flight lock;
 * 3. Fence destructive lifecycle operations (`DELETE /v1/session` / secret rotation) via vault epoch
 *    so in-flight requests can never resurrect cleared sessions;
 * 4. Detect Upstream HTTP 901 / 401 / login redirects on `/v1/proxy` and transparently re-authenticate
 *    once before replaying safe exchanges (lazy keep-alive on traffic, zero idle wakeups);
 * 5. Multiplex a single Durable Object `alarm()` across opt-in cloud tasks:
 *    - `monitor:grades`    (Periodic grade publication check, strictly OFF by default)
 *    - `monitor:exams`     (Periodic exam schedule/seat check, strictly OFF by default)
 *    - `session:keepalive` (Active cookie heartbeat for QR/SSO-only sessions, strictly OFF by default)
 *    When all background tasks are disabled/paused, `deleteAlarm()` is called for 0 idle wakeups.
 */

import { ServerCookieJar } from "./cookie_jar.js";
import {
  applyMonitorDigestResult,
  applyMonitorError,
  clampMonitorIntervalSec,
  computeNextSubMonitorWakeMs,
  createInitialMonitorState,
  createInitialSingleMonitorState,
  fetchPortalExamsDigest,
  fetchPortalGradesDigest,
  formatSingleMonitorView,
  normalizeMonitorState,
} from "./monitor.js";
import {
  PortalProtocolError,
  authenticatePortalSession,
  base64ToBytes,
  bytesToBase64,
  computeConfigFingerprint,
  executeWithCookieJar,
  isHostAllowed,
  isPrivateOrLoopbackHost,
  isSessionExpiredExchange,
  parsePortalEnvConfig,
  probeSessionAlive,
  readBoundedResponseBytes,
} from "./protocol.js";
import {
  createDefaultWebhookConfig,
  dispatchWebhookNotification,
  sanitizeWebhookConfigForClient,
  shouldSendWebhookForEvent,
  validateWebhookUrl,
} from "./webhook.js";

export const MAX_PROXY_REQUEST_BYTES = 2 * 1024 * 1024;
export const MAX_CONTROL_JSON_BYTES = 256 * 1024;
const MAX_KEEPALIVE_LOGS = 40;

const STORAGE_KEYS = {
  fingerprint: "v1:fingerprint",
  cookies: "v1:cookies",
  meta: "v1:meta",
  webhook: "v1:webhook",
  monitor: "v1:monitor",
  keepalive: "v1:keepalive",
};

function createInitialKeepaliveTaskState() {
  return {
    overrideEnabled: null, // null = follow env.KEEPALIVE_INTERVAL_SEC (default 0 = OFF)
    intervalSec: 600,
    lastRunAtMs: null,
    lastDurationMs: null,
    totalRuns: 0,
    lastError: "",
    lastSummary: "",
    logs: [],
  };
}

async function deriveVaultAesKey(config, env = {}) {
  const primaryApiKey = String(env.COURSELENS_API_KEY || env.API_KEY || "")
    .split(",")[0]
    .trim();
  // Preserve exact key derivation for static-credential vaults while mixing API key entropy
  // when neither password nor seedCookies is statically configured.
  const material = config.hasStaticCredentials
    ? JSON.stringify([
        "courselens-do-cookie-vault-v1",
        config.portalUrl,
        config.casUrl,
        config.username,
        config.password,
        config.seedCookies,
      ])
    : JSON.stringify([
        "courselens-do-cookie-vault-v1-dynamic",
        config.portalUrl,
        config.casUrl,
        primaryApiKey,
      ]);
  const rawKey = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(material));
  return crypto.subtle.importKey("raw", rawKey, { name: "AES-GCM" }, false, [
    "encrypt",
    "decrypt",
  ]);
}

async function encryptJsonForStorage(payloadObj, config, env) {
  const key = await deriveVaultAesKey(config, env);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = new TextEncoder().encode(JSON.stringify(payloadObj));
  const cipherBuf = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, plaintext);
  return {
    v: 1,
    alg: "AES-256-GCM",
    iv: bytesToBase64(iv),
    ct: bytesToBase64(new Uint8Array(cipherBuf)),
  };
}

async function decryptJsonFromStorage(savedEnvelope, config, env, fallbackValue) {
  if (!savedEnvelope) return fallbackValue;
  if (Array.isArray(savedEnvelope) && Array.isArray(fallbackValue)) {
    return savedEnvelope;
  }
  if (
    typeof savedEnvelope === "object" &&
    savedEnvelope.v === 1 &&
    (savedEnvelope.alg === "AES-256-GCM" || savedEnvelope.alg === "AES-GCM") &&
    typeof savedEnvelope.iv === "string" &&
    typeof savedEnvelope.ct === "string"
  ) {
    try {
      const key = await deriveVaultAesKey(config, env);
      const iv = base64ToBytes(savedEnvelope.iv);
      const ct = base64ToBytes(savedEnvelope.ct);
      const plainBuf = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, ct);
      return JSON.parse(new TextDecoder().decode(plainBuf));
    } catch {
      return fallbackValue;
    }
  }
  return fallbackValue;
}

export class PortalSessionVault {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env || {};
    this._hydrated = false;
    this._hydratePromise = null;
    this._loginPromise = null;
    this._jar = new ServerCookieJar();
    this._fingerprint = "";
    this._meta = null;
    this._webhook = createDefaultWebhookConfig();
    this._monitor = createInitialMonitorState();
    this._keepaliveTask = createInitialKeepaliveTaskState();
    this._scopeCache = { baseUrl: "", scopes: null, expiresAtMs: 0 };
    this._authGeneration = 0;
    this._vaultEpoch = 0;
    this._nextAlarmMs = null;
  }

  _now() {
    return typeof this.env.__NOW_FN === "function" ? this.env.__NOW_FN() : Date.now();
  }

  _fetchImpl() {
    return typeof this.env.__FETCH_IMPL === "function" ? this.env.__FETCH_IMPL : fetch;
  }

  _allowLoopback() {
    return this.env.__ALLOW_LOOPBACK_FOR_TEST === true;
  }

  _timeoutMs() {
    const custom = Number(this.env.__UPSTREAM_TIMEOUT_MS);
    return Number.isFinite(custom) && custom > 0 ? custom : 22000;
  }

  _maxUpstreamResponseBytes() {
    const custom = Number(this.env.__MAX_UPSTREAM_RESPONSE_BYTES);
    return Number.isFinite(custom) && custom > 0 ? custom : undefined;
  }

  _effectiveKeepaliveMs(config) {
    if (this._keepaliveTask.overrideEnabled === true) {
      return Math.max(60, Number(this._keepaliveTask.intervalSec || 600)) * 1000;
    }
    if (this._keepaliveTask.overrideEnabled === false) {
      return 0;
    }
    return config.keepaliveMs || 0;
  }

  async _ensureHydrated(config) {
    if (!this._hydratePromise) {
      this._hydratePromise = (async () => {
        const [
          savedFp,
          savedCookies,
          savedMeta,
          savedWebhook,
          savedMonitor,
          savedKeepalive,
          existingAlarm,
        ] = await Promise.all([
          this.ctx.storage.get(STORAGE_KEYS.fingerprint),
          this.ctx.storage.get(STORAGE_KEYS.cookies),
          this.ctx.storage.get(STORAGE_KEYS.meta),
          this.ctx.storage.get(STORAGE_KEYS.webhook),
          this.ctx.storage.get(STORAGE_KEYS.monitor),
          this.ctx.storage.get(STORAGE_KEYS.keepalive),
          typeof this.ctx.storage.getAlarm === "function"
            ? this.ctx.storage.getAlarm()
            : Promise.resolve(null),
        ]);

        this._fingerprint = typeof savedFp === "string" ? savedFp : "";
        const decryptedCookies = await decryptJsonFromStorage(savedCookies, config, this.env, []);
        this._jar = ServerCookieJar.fromJSON(
          Array.isArray(decryptedCookies) ? decryptedCookies : [],
          this._now(),
        );
        this._meta = savedMeta && typeof savedMeta === "object" ? savedMeta : null;
        this._authGeneration =
          Number.isInteger(this._meta?.authGeneration) && this._meta.authGeneration > 0
            ? this._meta.authGeneration
            : (this._meta ? 1 : 0);

        const decryptedWebhook = await decryptJsonFromStorage(
          savedWebhook,
          config,
          this.env,
          null,
        );
        if (decryptedWebhook && typeof decryptedWebhook === "object") {
          this._webhook = { ...createDefaultWebhookConfig(), ...decryptedWebhook };
        } else if (this.env.NOTIFY_WEBHOOK_URL) {
          this._webhook = {
            ...createDefaultWebhookConfig(),
            enabled: true,
            url: String(this.env.NOTIFY_WEBHOOK_URL).trim(),
            secret: String(this.env.NOTIFY_WEBHOOK_SECRET || "").trim(),
          };
        } else {
          this._webhook = createDefaultWebhookConfig();
        }

        this._monitor = normalizeMonitorState(savedMonitor);
        this._keepaliveTask =
          savedKeepalive && typeof savedKeepalive === "object"
            ? { ...createInitialKeepaliveTaskState(), ...savedKeepalive }
            : createInitialKeepaliveTaskState();
        this._nextAlarmMs = typeof existingAlarm === "number" ? existingAlarm : null;
        this._hydrated = true;
      })().catch((err) => {
        this._hydratePromise = null;
        throw err;
      });
    }
    await this._hydratePromise;

    const currentFp = await computeConfigFingerprint(config);
    if (this._fingerprint !== currentFp) {
      const hadPriorFp = Boolean(this._fingerprint);
      this._fingerprint = currentFp;
      await this.ctx.storage.put(STORAGE_KEYS.fingerprint, currentFp);
      // Only wipe session cookies when migrating from a DIFFERENT prior static config fingerprint.
      if (hadPriorFp) {
        this._vaultEpoch += 1;
        this._loginPromise = null;
        this._jar = new ServerCookieJar();
        this._meta = null;
        this._scopeCache = { baseUrl: "", scopes: null, expiresAtMs: 0 };
        await this.ctx.storage.delete(STORAGE_KEYS.cookies);
        await this.ctx.storage.delete(STORAGE_KEYS.meta);
      }
    }
  }

  async _persistState(config, expectedEpoch = this._vaultEpoch) {
    if (this._vaultEpoch !== expectedEpoch || !this._meta) {
      return false;
    }
    const nowMs = this._now();
    const metaSnapshot = { ...this._meta };
    const encryptedCookies = await encryptJsonForStorage(
      this._jar.toJSON(nowMs),
      config,
      this.env,
    );
    if (this._vaultEpoch !== expectedEpoch || !this._meta) {
      return false;
    }
    await Promise.all([
      this.ctx.storage.put(STORAGE_KEYS.cookies, encryptedCookies),
      this.ctx.storage.put(STORAGE_KEYS.meta, metaSnapshot),
    ]);
    return true;
  }

  async _persistMonitor(expectedEpoch = this._vaultEpoch) {
    if (this._vaultEpoch !== expectedEpoch) return false;
    await this.ctx.storage.put(STORAGE_KEYS.monitor, this._monitor);
    return true;
  }

  async _persistKeepaliveTask(expectedEpoch = this._vaultEpoch) {
    if (this._vaultEpoch !== expectedEpoch) return false;
    await this.ctx.storage.put(STORAGE_KEYS.keepalive, this._keepaliveTask);
    return true;
  }

  async _persistWebhook(config, expectedEpoch = this._vaultEpoch) {
    if (this._vaultEpoch !== expectedEpoch) return false;
    const enc = await encryptJsonForStorage(this._webhook, config, this.env);
    if (this._vaultEpoch !== expectedEpoch) return false;
    await this.ctx.storage.put(STORAGE_KEYS.webhook, enc);
    return true;
  }

  /**
   * Unified Durable Object single-alarm multiplexer.
   * Schedules `min(gradesWake, examsWake, keepaliveWake)` or deletes any
   * pending alarm when all background tasks are OFF/idle (zero Free Plan background wakeups).
   */
  async _scheduleNextAlarm(config, expectedEpoch = this._vaultEpoch) {
    if (this._vaultEpoch !== expectedEpoch) return;
    const nowMs = this._now();
    const candidates = [];

    const gradesWake = computeNextSubMonitorWakeMs(this._monitor.grades, nowMs);
    if (gradesWake !== null) candidates.push(gradesWake);

    const examsWake = computeNextSubMonitorWakeMs(this._monitor.exams, nowMs);
    if (examsWake !== null) candidates.push(examsWake);

    const keepaliveMs = this._effectiveKeepaliveMs(config);
    let pausedByKeepaliveMaxIdle = false;
    if (keepaliveMs > 0 && this._meta && this._jar.hasActiveCookies(nowMs)) {
      const lastAccess = this._meta.lastClientAccessAtMs || this._meta.authenticatedAtMs || nowMs;
      const withinIdleLimit =
        config.keepaliveMaxIdleMs <= 0 || nowMs - lastAccess <= config.keepaliveMaxIdleMs;
      if (withinIdleLimit) {
        candidates.push(nowMs + keepaliveMs);
      } else {
        pausedByKeepaliveMaxIdle = true;
      }
    }

    if (candidates.length === 0) {
      this._nextAlarmMs = null;
      if (!pausedByKeepaliveMaxIdle && typeof this.ctx.storage.deleteAlarm === "function") {
        await this.ctx.storage.deleteAlarm();
      }
      return;
    }

    const earliest = Math.min(...candidates);
    this._nextAlarmMs = earliest;
    await this.ctx.storage.setAlarm(earliest);
  }

  async _notifyEvents(config, notifications = []) {
    if (!Array.isArray(notifications) || notifications.length === 0) return;
    for (const n of notifications) {
      if (!shouldSendWebhookForEvent(this._webhook, n.event)) continue;
      const res = await dispatchWebhookNotification({
        cfg: this._webhook,
        event: n.event,
        title: n.title,
        body: n.body,
        meta: {
          schoolId: config.schoolId,
          schoolName: config.schoolName,
          taskId: n.taskId || "",
        },
        fetchImpl: this._fetchImpl(),
        allowPrivateLoopback: this._allowLoopback(),
        nowFn: () => this._now(),
      });
      this._webhook.lastSentAtMs = this._now();
      this._webhook.lastError = res.ok ? "" : (res.error || "");
      await this._persistWebhook(config, this._vaultEpoch);
    }
  }

  async _ensureAuthenticated(config, { force = false, staleGeneration = null } = {}) {
    await this._ensureHydrated(config);
    if (this._loginPromise) {
      return this._loginPromise;
    }
    if (
      force &&
      staleGeneration !== null &&
      this._authGeneration > staleGeneration &&
      this._meta &&
      this._jar.hasActiveCookies(this._now())
    ) {
      return this._meta;
    }
    if (!force && this._meta && this._jar.hasActiveCookies(this._now())) {
      return this._meta;
    }

    const generationBeforeLogin = this._authGeneration;
    const loginEpoch = this._vaultEpoch;
    const promise = (async () => {
      const nowMs = this._now();
      const authResult = await authenticatePortalSession({
        config,
        jar: null,
        fetchImpl: this._fetchImpl(),
        timeoutMs: this._timeoutMs(),
        allowPrivateLoopback: this._allowLoopback(),
        nowFn: () => this._now(),
      });

      if (this._vaultEpoch !== loginEpoch) {
        throw new PortalProtocolError(
          "SESSION_EXPIRED",
          "云端托管会话已在认证期间被主动注销或轮换，请重试",
          401,
        );
      }

      const commitMs = this._now();
      this._jar.replaceFrom(authResult.jar, commitMs);
      const nextGen = Math.max(this._authGeneration, generationBeforeLogin) + 1;
      this._authGeneration = nextGen;
      this._meta = {
        effectiveBaseUrl: authResult.effectiveBaseUrl,
        systemId: authResult.systemId,
        username: config.username || authResult.identity.studentId || "",
        studentInfo: {
          name: authResult.identity.name || "",
          studentId: authResult.identity.studentId || config.username || "",
          department: authResult.identity.department || "",
          className: authResult.identity.className || "",
        },
        authGeneration: nextGen,
        authenticatedAtMs: nowMs,
        lastVerifiedAtMs: commitMs,
        lastClientAccessAtMs: this._meta?.lastClientAccessAtMs || commitMs,
      };
      await this._persistState(config, loginEpoch);
      await this._scheduleNextAlarm(config, loginEpoch);
      return this._meta;
    })().finally(() => {
      if (this._loginPromise === promise) {
        this._loginPromise = null;
      }
    });

    this._loginPromise = promise;
    return promise;
  }

  _countActiveCloudTasks(config) {
    let count = 0;
    if (this._monitor.grades.enabled) count += 1;
    if (this._monitor.exams.enabled) count += 1;
    if (this._effectiveKeepaliveMs(config) > 0) count += 1;
    return count;
  }

  _formatSessionResponse(config, { alive }) {
    const nowMs = this._now();
    const meta = this._meta;
    const effectiveBaseUrl = meta?.effectiveBaseUrl || config.portalUrl;
    const systemId =
      meta?.systemId ||
      (config.system === "auto"
        ? (effectiveBaseUrl.toLowerCase().includes("/jsxsd") ? "QZ" : "ZF")
        : config.system);

    const identityObj = meta?.studentInfo || {
      name: "",
      studentId: config.username || "",
      department: "",
      className: "",
    };

    const keepaliveIntervalSec = Math.floor(this._effectiveKeepaliveMs(config) / 1000);
    return {
      ok: true,
      authenticated: Boolean(meta && this._jar.hasActiveCookies(nowMs)),
      alive,
      schoolId: config.schoolId,
      schoolName: config.schoolName,
      baseUrl: effectiveBaseUrl,
      casBaseUrl: config.casUrl || "",
      systemId,
      allowedHosts: config.allowedHosts,
      requireSecure: config.requireSecure,
      hasPasswordAuth: Boolean(config.hasPasswordAuth),
      hasStaticCredentials: Boolean(config.hasStaticCredentials),
      username: meta?.username || config.username || "",
      identity: identityObj,
      studentInfo: identityObj,
      authenticatedAt: meta?.authenticatedAtMs
        ? new Date(meta.authenticatedAtMs).toISOString()
        : null,
      lastVerifiedAt: meta?.lastVerifiedAtMs
        ? new Date(meta.lastVerifiedAtMs).toISOString()
        : null,
      keepaliveMode: keepaliveIntervalSec > 0 ? "alarm" : "lazy",
      keepaliveIntervalSec,
      capabilities: [
        "proxy",
        "cookie-push",
        "cloud-tasks",
        "webhook",
        "monitor",
      ],
      monitorGradesEnabled: Boolean(this._monitor.grades.enabled),
      monitorExamsEnabled: Boolean(this._monitor.exams.enabled),
      activeTaskCount: this._countActiveCloudTasks(config),
      nextAlarmAt: this._nextAlarmMs ? new Date(this._nextAlarmMs).toISOString() : null,
    };
  }

  async _readJsonBody(request, maxBytes = MAX_CONTROL_JSON_BYTES) {
    const raw = await readBoundedResponseBytes(request, maxBytes);
    if (raw.byteLength === 0) return {};
    let parsed;
    try {
      parsed = JSON.parse(new TextDecoder().decode(raw));
    } catch {
      throw new PortalProtocolError("VALIDATION_FAILED", "无效的 JSON 请求体", 400);
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new PortalProtocolError("VALIDATION_FAILED", "请求体必须是 JSON 对象", 400);
    }
    return parsed;
  }

  async fetch(request) {
    try {
      const config = parsePortalEnvConfig(this.env);
      const url = new URL(request.url);
      const path = url.pathname;
      const method = request.method.toUpperCase();

      // --- Session Management ---
      if (path === "/v1/session" && method === "GET") {
        return await this._handleGetSession(url, config);
      }
      if (path === "/v1/session/refresh" && method === "POST") {
        await this._ensureAuthenticated(config, { force: true });
        const refreshEpoch = this._vaultEpoch;
        if (this._meta) {
          this._meta.lastClientAccessAtMs = this._now();
          await this._persistState(config, refreshEpoch);
          await this._scheduleNextAlarm(config, refreshEpoch);
        }
        return jsonOut(200, this._formatSessionResponse(config, { alive: true }));
      }
      if (path === "/v1/session/cookies" && method === "POST") {
        return await this._handlePushCookies(request, config);
      }
      if (path === "/v1/session" && method === "DELETE") {
        await this._ensureHydrated(config);
        this._vaultEpoch += 1;
        this._loginPromise = null;
        this._jar = new ServerCookieJar();
        this._meta = null;
        this._scopeCache = { baseUrl: "", scopes: null, expiresAtMs: 0 };
        await this.ctx.storage.delete(STORAGE_KEYS.cookies);
        await this.ctx.storage.delete(STORAGE_KEYS.meta);
        await this._scheduleNextAlarm(config, this._vaultEpoch);
        return jsonOut(200, { ok: true, cleared: true });
      }

      // --- Stateful Portal Proxy ---
      if (path === "/v1/proxy" && method === "POST") {
        return await this._handleProxy(request, config);
      }

      // --- Unified Cloud Task Center (/v1/tasks & /v1/tasks/:taskId) ---
      if (path === "/v1/tasks" && method === "GET") {
        await this._ensureHydrated(config);
        return jsonOut(200, this._buildTasksListPayload(config));
      }
      if (path.startsWith("/v1/tasks/")) {
        return await this._handleTaskRoute(request, url, config);
      }

      // --- Multi-provider Webhook Center (/v1/webhook*) ---
      if (path === "/v1/webhook" && method === "GET") {
        await this._ensureHydrated(config);
        return jsonOut(200, { ok: true, ...sanitizeWebhookConfigForClient(this._webhook) });
      }
      if (path === "/v1/webhook" && (method === "PUT" || method === "POST")) {
        return await this._handleUpdateWebhook(request, config);
      }
      if (path === "/v1/webhook" && method === "DELETE") {
        await this._ensureHydrated(config);
        this._webhook = createDefaultWebhookConfig();
        await this._persistWebhook(config);
        return jsonOut(200, { ok: true, ...sanitizeWebhookConfigForClient(this._webhook) });
      }
      if (path === "/v1/webhook/test" && method === "POST") {
        return await this._handleTestWebhook(config);
      }

      // --- Periodic Grade & Exam Monitor (/v1/monitor*) ---
      if (path === "/v1/monitor" && method === "GET") {
        await this._ensureHydrated(config);
        const nowMs = this._now();
        return jsonOut(200, {
          ok: true,
          grades: formatSingleMonitorView(this._monitor.grades, nowMs),
          exams: formatSingleMonitorView(this._monitor.exams, nowMs),
        });
      }
      if (path === "/v1/monitor" && (method === "PUT" || method === "PATCH" || method === "POST")) {
        return await this._handleUpdateMonitor(request, config);
      }
      if (path === "/v1/monitor/check" && method === "POST") {
        return await this._handleManualMonitorCheck(request, config);
      }

      return jsonOut(404, { status: "NOT_FOUND", error: "Not Found" });
    } catch (err) {
      if (err instanceof PortalProtocolError) {
        return jsonOut(err.httpStatus || 502, {
          status: err.status,
          error: err.message,
        });
      }
      return jsonOut(500, {
        status: "INTERNAL_ERROR",
        error: "网关内部处理异常",
      });
    }
  }

  async _handleGetSession(url, config) {
    await this._ensureHydrated(config);
    const offline = url.searchParams.get("offline") === "1";
    if (offline) {
      await this._scheduleNextAlarm(config, this._vaultEpoch);
      return jsonOut(200, this._formatSessionResponse(config, { alive: null }));
    }

    if (this._loginPromise) {
      await this._loginPromise;
    }

    const reqEpoch = this._vaultEpoch;
    const forceProbe = url.searchParams.get("probe") === "1";
    const nowMs = this._now();
    if (this._meta) {
      this._meta.lastClientAccessAtMs = nowMs;
    }

    const recentlyVerified =
      !forceProbe &&
      config.sessionVerifyTtlMs > 0 &&
      this._meta &&
      this._jar.hasActiveCookies(nowMs) &&
      typeof this._meta.lastVerifiedAtMs === "number" &&
      nowMs - this._meta.lastVerifiedAtMs >= 0 &&
      nowMs - this._meta.lastVerifiedAtMs < config.sessionVerifyTtlMs;

    if (recentlyVerified) {
      if (this._effectiveKeepaliveMs(config) > 0) {
        await this._persistState(config, reqEpoch);
      }
      await this._scheduleNextAlarm(config, reqEpoch);
      return jsonOut(200, this._formatSessionResponse(config, { alive: true }));
    }

    const preProbeGen = this._authGeneration;
    let alive = false;
    if (this._meta && this._jar.hasActiveCookies(nowMs)) {
      const probe = await probeSessionAlive({
        effectiveBaseUrl: this._meta.effectiveBaseUrl,
        systemId: this._meta.systemId,
        jar: this._jar,
        policy: {
          allowedHosts: config.allowedHosts,
          requireSecure: config.requireSecure,
        },
        fetchImpl: this._fetchImpl(),
        timeoutMs: this._timeoutMs(),
        allowPrivateLoopback: this._allowLoopback(),
        nowFn: () => this._now(),
      });
      if (this._vaultEpoch !== reqEpoch) {
        throw new PortalProtocolError(
          "SESSION_EXPIRED",
          "云端托管会话已在探测期间被主动注销",
          401,
        );
      }
      if (probe.alive && this._meta) {
        alive = true;
        this._meta.lastVerifiedAtMs = this._now();
        if (probe.identity.name && !this._meta.studentInfo?.name) {
          this._meta.studentInfo.name = probe.identity.name;
        }
        await this._persistState(config, reqEpoch);
        await this._scheduleNextAlarm(config, reqEpoch);
      }
    }

    if (!alive) {
      await this._ensureAuthenticated(config, {
        force: true,
        staleGeneration: preProbeGen,
      });
      const postAuthEpoch = this._vaultEpoch;
      if (this._meta) {
        this._meta.lastClientAccessAtMs = this._now();
        await this._persistState(config, postAuthEpoch);
        await this._scheduleNextAlarm(config, postAuthEpoch);
      }
      alive = true;
    }

    return jsonOut(200, this._formatSessionResponse(config, { alive: true }));
  }

  async _handlePushCookies(request, config) {
    await this._ensureHydrated(config);
    const body = await this._readJsonBody(request);
    const targetBaseUrl = body.portalUrl
      ? String(body.portalUrl).trim().replace(/\/+$/, "")
      : config.portalUrl;

    if (!isHostAllowed(targetBaseUrl, config.allowedHosts, config.requireSecure)) {
      throw new PortalProtocolError(
        "UNTRUSTED_URL",
        `Cookie 注入目标域名不在当前 Worker 允许列表内：${targetBaseUrl}`,
        403,
      );
    }
    const parsedHost = new URL(targetBaseUrl).hostname;
    if (!this._allowLoopback() && isPrivateOrLoopbackHost(parsedHost)) {
      throw new PortalProtocolError(
        "UNTRUSTED_URL",
        `SSRF 防护拦截：禁止向内网或环回地址注入会话（${parsedHost}）`,
        403,
      );
    }

    const nowMs = this._now();
    const stagingJar = new ServerCookieJar();
    const rawCookies = body.cookies;
    let absorbedCount = 0;

    if (typeof rawCookies === "string") {
      absorbedCount = stagingJar.absorbSeedCookies(rawCookies, targetBaseUrl, nowMs);
    } else if (Array.isArray(rawCookies)) {
      for (const item of rawCookies) {
        if (typeof item === "string") {
          if (item.includes(";") && /\b(?:path|domain|httponly|secure)\b/i.test(item)) {
            if (stagingJar.absorbSetCookie(item, targetBaseUrl, nowMs)) absorbedCount += 1;
          } else {
            absorbedCount += stagingJar.absorbSeedCookies(item, targetBaseUrl, nowMs);
          }
        } else if (item && typeof item === "object" && item.name && item.value !== undefined) {
          absorbedCount += stagingJar.absorbSeedCookies(
            `${item.name}=${item.value}`,
            targetBaseUrl,
            nowMs,
          );
        }
      }
    } else if (rawCookies && typeof rawCookies === "object") {
      absorbedCount = stagingJar.absorbSeedCookies(JSON.stringify(rawCookies), targetBaseUrl, nowMs);
    }

    if (absorbedCount === 0 || !stagingJar.hasActiveCookies(nowMs)) {
      throw new PortalProtocolError(
        "VALIDATION_FAILED",
        "未能从请求中解析到合法的教务会话 Cookie",
        400,
      );
    }

    const resolvedSystem =
      body.systemId && ["ZF", "ZF_OLD", "QZ", "QZ_OLD"].includes(String(body.systemId).toUpperCase())
        ? String(body.systemId).toUpperCase()
        : (config.system === "auto"
            ? (targetBaseUrl.toLowerCase().includes("/jsxsd") ? "QZ" : "ZF")
            : config.system);

    const epochBeforeProbe = this._vaultEpoch;
    const probe = await probeSessionAlive({
      effectiveBaseUrl: targetBaseUrl,
      systemId: resolvedSystem,
      jar: stagingJar,
      policy: {
        allowedHosts: config.allowedHosts,
        requireSecure: config.requireSecure,
      },
      fetchImpl: this._fetchImpl(),
      timeoutMs: this._timeoutMs(),
      allowPrivateLoopback: this._allowLoopback(),
      nowFn: () => this._now(),
    });

    if (!probe.alive) {
      throw new PortalProtocolError(
        "SESSION_EXPIRED",
        "上报的 Cookie 未通过教务在线探活核验，请确认浏览器内已完成教务登录",
        401,
      );
    }
    if (this._vaultEpoch !== epochBeforeProbe) {
      throw new PortalProtocolError("SESSION_EXPIRED", "会话已在探测期间变更，请重试", 401);
    }

    const commitMs = this._now();
    this._jar.replaceFrom(stagingJar, commitMs);
    this._authGeneration += 1;
    const resolvedUsername =
      String(body.username || "").trim() ||
      probe.identity.studentId ||
      config.username ||
      this._meta?.username ||
      "";
    this._meta = {
      effectiveBaseUrl: probe.effectiveBaseUrl || targetBaseUrl,
      systemId: probe.systemId || resolvedSystem,
      username: resolvedUsername,
      studentInfo: {
        name: probe.identity.name || this._meta?.studentInfo?.name || "",
        studentId: probe.identity.studentId || resolvedUsername,
        department: probe.identity.department || this._meta?.studentInfo?.department || "",
        className: probe.identity.className || this._meta?.studentInfo?.className || "",
      },
      authGeneration: this._authGeneration,
      authenticatedAtMs: commitMs,
      lastVerifiedAtMs: commitMs,
      lastClientAccessAtMs: commitMs,
    };

    if (body.keepaliveIntervalSec !== undefined && body.keepaliveIntervalSec !== null) {
      const sec = Number.parseInt(String(body.keepaliveIntervalSec), 10);
      if (!Number.isNaN(sec) && sec >= 0) {
        if (sec === 0) {
          this._keepaliveTask.overrideEnabled = false;
        } else {
          this._keepaliveTask.overrideEnabled = true;
          this._keepaliveTask.intervalSec = Math.min(7200, Math.max(60, sec));
        }
        await this._persistKeepaliveTask(epochBeforeProbe);
      }
    }

    await this._persistState(config, epochBeforeProbe);
    await this._scheduleNextAlarm(config, epochBeforeProbe);
    return jsonOut(200, {
      ...this._formatSessionResponse(config, { alive: true }),
      injectedCookieCount: this._jar.size(commitMs),
    });
  }

  // -------------------------------------------------------------------------
  // Webhook & Monitor Handlers
  // -------------------------------------------------------------------------

  async _handleUpdateWebhook(request, config) {
    await this._ensureHydrated(config);
    const body = await this._readJsonBody(request);
    const next = { ...this._webhook };

    if (body.url !== undefined) {
      const trimmed = String(body.url || "").trim();
      if (trimmed) {
        next.url = validateWebhookUrl(trimmed, {
          allowPrivateLoopback: this._allowLoopback(),
        });
      } else {
        next.url = "";
      }
    }
    if (body.provider !== undefined) {
      next.provider = String(body.provider || "auto").trim().toLowerCase() || "auto";
    }
    if (body.secret !== undefined) {
      next.secret = String(body.secret || "").trim();
    }
    if (body.telegramChatId !== undefined) {
      next.telegramChatId = String(body.telegramChatId || "").trim();
    }
    if (body.enabled !== undefined) {
      next.enabled = Boolean(body.enabled);
    } else if (next.url) {
      next.enabled = true;
    }
    if (body.onGradeChange !== undefined) next.onGradeChange = Boolean(body.onGradeChange);
    if (body.onExamChange !== undefined) next.onExamChange = Boolean(body.onExamChange);

    next.updatedAtMs = this._now();
    this._webhook = next;
    await this._persistWebhook(config);
    return jsonOut(200, { ok: true, ...sanitizeWebhookConfigForClient(this._webhook) });
  }

  async _handleTestWebhook(config) {
    await this._ensureHydrated(config);
    if (!String(this._webhook.url || "").trim()) {
      throw new PortalProtocolError("VALIDATION_FAILED", "尚未配置 Webhook URL", 400);
    }
    const res = await dispatchWebhookNotification({
      cfg: { ...this._webhook, enabled: true },
      event: "test",
      title: "🔔 CourseLens 云端网关推送连通性测试",
      body: `学校：${config.schoolName}（${config.schoolId}）\n状态：Webhook 推送通道工作正常！`,
      meta: { schoolId: config.schoolId, schoolName: config.schoolName },
      fetchImpl: this._fetchImpl(),
      allowPrivateLoopback: this._allowLoopback(),
      nowFn: () => this._now(),
    });
    this._webhook.lastSentAtMs = this._now();
    this._webhook.lastError = res.ok ? "" : (res.error || "");
    await this._persistWebhook(config);
    if (!res.ok) {
      return jsonOut(502, {
        ok: false,
        status: "WEBHOOK_FAILED",
        error: res.error || "Webhook 测试发送失败",
      });
    }
    return jsonOut(200, {
      ok: true,
      provider: res.provider,
      ...sanitizeWebhookConfigForClient(this._webhook),
    });
  }

  async _handleUpdateMonitor(request, config) {
    await this._ensureHydrated(config);
    const body = await this._readJsonBody(request);
    const hasGradesObj = Boolean(body.grades && typeof body.grades === "object");
    const hasExamsObj = Boolean(body.exams && typeof body.exams === "object");
    const targetsGrades = hasGradesObj || body.gradesEnabled !== undefined;
    const targetsExams = hasExamsObj || body.examsEnabled !== undefined;

    if (hasGradesObj) {
      this._applySingleMonitorPatch("grades", body.grades);
    }
    if (hasExamsObj) {
      this._applySingleMonitorPatch("exams", body.exams);
    }
    if (body.gradesEnabled !== undefined) {
      this._applySingleMonitorPatch("grades", { enabled: Boolean(body.gradesEnabled) });
    }
    if (body.examsEnabled !== undefined) {
      this._applySingleMonitorPatch("exams", { enabled: Boolean(body.examsEnabled) });
    }
    if (body.intervalSec !== undefined) {
      if (targetsGrades || !targetsExams) {
        this._monitor.grades.intervalSec = clampMonitorIntervalSec(body.intervalSec, 1800);
      }
      if (targetsExams || !targetsGrades) {
        this._monitor.exams.intervalSec = clampMonitorIntervalSec(body.intervalSec, 3600);
      }
    }
    if (body.resetBaseline === true) {
      if ((targetsGrades && !hasGradesObj) || (!targetsGrades && !targetsExams)) {
        this._applySingleMonitorPatch("grades", { resetBaseline: true });
      }
      if ((targetsExams && !hasExamsObj) || (!targetsGrades && !targetsExams)) {
        this._applySingleMonitorPatch("exams", { resetBaseline: true });
      }
    }

    await this._persistMonitor();
    await this._scheduleNextAlarm(config, this._vaultEpoch);
    const nowMs = this._now();
    return jsonOut(200, {
      ok: true,
      grades: formatSingleMonitorView(this._monitor.grades, nowMs),
      exams: formatSingleMonitorView(this._monitor.exams, nowMs),
    });
  }

  _applySingleMonitorPatch(kind, patch = {}) {
    const sub = this._monitor[kind];
    if (!sub) return;
    if (patch.enabled !== undefined) {
      sub.enabled = Boolean(patch.enabled);
      if (sub.enabled && (!sub.lastSummary || sub.lastSummary.startsWith("未开启"))) {
        sub.lastSummary = sub.baselineInitialized
          ? `已开启定时巡检（当前追踪 ${sub.trackedItemCount} 项）`
          : "已开启，等待首轮基线建立";
      } else if (!sub.enabled) {
        sub.lastSummary = "未开启（默认关闭）";
      }
    }
    if (patch.intervalSec !== undefined) {
      sub.intervalSec = clampMonitorIntervalSec(
        patch.intervalSec,
        kind === "grades" ? 1800 : 3600,
      );
    }
    if (patch.resetBaseline === true) {
      const keepEnabled = sub.enabled;
      const keepInterval = sub.intervalSec;
      this._monitor[kind] = {
        ...createInitialSingleMonitorState(kind),
        enabled: keepEnabled,
        intervalSec: keepInterval,
        lastSummary: keepEnabled ? "已重置基线，等待下一次巡检重建" : "未开启（默认关闭）",
      };
    }
  }

  async _runSingleMonitorCheck(config, kind) {
    const started = Date.now();
    const runEpoch = this._vaultEpoch;
    const policy = {
      allowedHosts: config.allowedHosts,
      requireSecure: config.requireSecure,
    };
    try {
      let meta = await this._ensureAuthenticated(config, { force: false });
      const preGen = this._authGeneration;
      const runFetch = (m) =>
        kind === "grades"
          ? fetchPortalGradesDigest({
              effectiveBaseUrl: m.effectiveBaseUrl,
              systemId: m.systemId,
              jar: this._jar,
              policy,
              fetchImpl: this._fetchImpl(),
              timeoutMs: this._timeoutMs(),
              allowPrivateLoopback: this._allowLoopback(),
              nowFn: () => this._now(),
            })
          : fetchPortalExamsDigest({
              effectiveBaseUrl: m.effectiveBaseUrl,
              systemId: m.systemId,
              jar: this._jar,
              policy,
              fetchImpl: this._fetchImpl(),
              timeoutMs: this._timeoutMs(),
              allowPrivateLoopback: this._allowLoopback(),
              nowFn: () => this._now(),
            });

      let digestMap;
      try {
        digestMap = await runFetch(meta);
      } catch (err) {
        if (
          err instanceof PortalProtocolError &&
          err.status === "SESSION_EXPIRED" &&
          config.hasPasswordAuth
        ) {
          meta = await this._ensureAuthenticated(config, {
            force: true,
            staleGeneration: preGen,
          });
          digestMap = await runFetch(meta);
        } else {
          throw err;
        }
      }

      if (this._vaultEpoch !== runEpoch) return [];
      const nowMs = this._now();
      const { subState, changes, notification } = applyMonitorDigestResult(
        this._monitor[kind],
        digestMap,
        nowMs,
        Date.now() - started,
      );
      this._monitor[kind] = subState;
      await this._persistState(config, runEpoch);
      await this._persistMonitor(runEpoch);
      if (notification) {
        await this._notifyEvents(config, [notification]);
      }
      return changes;
    } catch (err) {
      if (this._vaultEpoch !== runEpoch) return [];
      this._monitor[kind] = applyMonitorError(
        this._monitor[kind],
        err.message || String(err),
        this._now(),
        Date.now() - started,
      );
      await this._persistMonitor(runEpoch);
      return [];
    }
  }

  async _handleManualMonitorCheck(request, config) {
    await this._ensureHydrated(config);
    const body = await this._readJsonBody(request);
    const targetKind = String(body.kind || "all").toLowerCase();
    if (targetKind === "grades" || targetKind === "all") {
      await this._runSingleMonitorCheck(config, "grades");
    }
    if (targetKind === "exams" || targetKind === "all") {
      await this._runSingleMonitorCheck(config, "exams");
    }
    await this._scheduleNextAlarm(config, this._vaultEpoch);
    const nowMs = this._now();
    return jsonOut(200, {
      ok: true,
      grades: formatSingleMonitorView(this._monitor.grades, nowMs),
      exams: formatSingleMonitorView(this._monitor.exams, nowMs),
    });
  }

  async _runKeepaliveHeartbeat(config) {
    const started = Date.now();
    const alarmEpoch = this._vaultEpoch;
    try {
      if (!this._meta) {
        await this._ensureAuthenticated(config, { force: false });
      } else {
        const preGen = this._authGeneration;
        const probe = await probeSessionAlive({
          effectiveBaseUrl: this._meta.effectiveBaseUrl,
          systemId: this._meta.systemId,
          jar: this._jar,
          policy: {
            allowedHosts: config.allowedHosts,
            requireSecure: config.requireSecure,
          },
          fetchImpl: this._fetchImpl(),
          timeoutMs: this._timeoutMs(),
          allowPrivateLoopback: this._allowLoopback(),
          nowFn: () => this._now(),
        });
        if (this._vaultEpoch !== alarmEpoch) return;
        if (probe.alive && this._meta) {
          this._meta.lastVerifiedAtMs = this._now();
          await this._persistState(config, alarmEpoch);
        } else {
          await this._ensureAuthenticated(config, {
            force: true,
            staleGeneration: preGen,
          });
        }
      }
      if (this._vaultEpoch !== alarmEpoch) return;
      const nowMs = this._now();
      const dur = Date.now() - started;
      this._keepaliveTask.lastRunAtMs = nowMs;
      this._keepaliveTask.lastDurationMs = dur;
      this._keepaliveTask.totalRuns = (this._keepaliveTask.totalRuns || 0) + 1;
      this._keepaliveTask.lastError = "";
      this._keepaliveTask.lastSummary = `会话在线探活通过（Cookie ${this._jar.size(nowMs)} 项）`;
      this._keepaliveTask.logs = [
        {
          atMs: nowMs,
          at: new Date(nowMs).toISOString(),
          status: "OK",
          durationMs: dur,
          message: this._keepaliveTask.lastSummary,
        },
        ...(this._keepaliveTask.logs || []),
      ].slice(0, MAX_KEEPALIVE_LOGS);
      await this._persistKeepaliveTask(alarmEpoch);
    } catch (err) {
      if (this._vaultEpoch !== alarmEpoch) return;
      const nowMs = this._now();
      const dur = Date.now() - started;
      this._keepaliveTask.lastRunAtMs = nowMs;
      this._keepaliveTask.lastDurationMs = dur;
      this._keepaliveTask.totalRuns = (this._keepaliveTask.totalRuns || 0) + 1;
      this._keepaliveTask.lastError = String(err.message || err).slice(0, 180);
      this._keepaliveTask.lastSummary = `探活异常：${this._keepaliveTask.lastError}`;
      this._keepaliveTask.logs = [
        {
          atMs: nowMs,
          at: new Date(nowMs).toISOString(),
          status: "ERROR",
          durationMs: dur,
          message: this._keepaliveTask.lastSummary,
        },
        ...(this._keepaliveTask.logs || []),
      ].slice(0, MAX_KEEPALIVE_LOGS);
      await this._persistKeepaliveTask(alarmEpoch);
    }
  }

  // -------------------------------------------------------------------------
  // Unified Cloud Task Center (/v1/tasks & /v1/tasks/:taskId)
  // -------------------------------------------------------------------------

  _buildMonitorTaskSummary(kind, nowMs) {
    const view = formatSingleMonitorView(this._monitor[kind], nowMs);
    const isGrades = kind === "grades";
    return {
      taskId: view.taskId,
      type: isGrades ? "MONITOR_GRADES" : "MONITOR_EXAMS",
      title: isGrades ? "定时成绩出分检测" : "定时考试与考场变动检测",
      subtitle: isGrades
        ? "默认关闭 · 开启后按周期静默对比成绩单，发现新出分时记录并推送"
        : "默认关闭 · 开启后按周期检测考试时间、考场与座号变动",
      enabled: view.enabled,
      canToggleDirectly: true,
      requiresWriteConfirmToRun: false,
      status: !view.enabled ? "DISABLED" : (view.lastError ? "ERROR" : "SCHEDULED"),
      intervalSec: view.intervalSec,
      mode: "PERIODIC",
      lastRunAt: view.lastRunAt,
      nextWakeAt: view.nextWakeAt,
      lastSummary: view.lastSummary,
      trackedItemCount: view.trackedItemCount,
      changeCount: view.changeCount,
    };
  }

  _buildKeepaliveTaskSummary(config, nowMs) {
    const effMs = this._effectiveKeepaliveMs(config);
    const enabled = effMs > 0;
    const intervalSec = enabled
      ? Math.floor(effMs / 1000)
      : (this._keepaliveTask.intervalSec || 600);
    const hasSession = Boolean(this._meta && this._jar.hasActiveCookies(nowMs));
    const nextWakeMs =
      enabled && hasSession ? nowMs + effMs : null;
    return {
      taskId: "session:keepalive",
      type: "SESSION_KEEPALIVE",
      title: "Cookie 主动定时心跳",
      subtitle: config.hasPasswordAuth
        ? "默认关闭 · 当前网关已配置账密按需懒重登（零后台唤醒），无需开启此项"
        : "默认关闭 · 仅纯扫码/动态注入 Cookie 且未配账密时按需开启防闲置过期",
      enabled,
      canToggleDirectly: true,
      requiresWriteConfirmToRun: false,
      status: !enabled
        ? "DISABLED"
        : (this._keepaliveTask.lastError ? "ERROR" : (hasSession ? "SCHEDULED" : "WAITING_SESSION")),
      intervalSec,
      mode: "PERIODIC",
      lastRunAt: this._keepaliveTask.lastRunAtMs
        ? new Date(this._keepaliveTask.lastRunAtMs).toISOString()
        : null,
      nextWakeAt: nextWakeMs ? new Date(nextWakeMs).toISOString() : null,
      lastSummary: enabled
        ? (this._keepaliveTask.lastSummary || (hasSession ? "主动心跳已开启" : "等待注入有效会话"))
        : (config.hasPasswordAuth ? "已关闭（按需懒重登始终生效）" : "未开启（默认关闭）"),
      trackedItemCount: this._jar.size(nowMs),
      changeCount: 0,
    };
  }

  _buildTasksListPayload(config) {
    const nowMs = this._now();
    const tasks = [
      this._buildMonitorTaskSummary("grades", nowMs),
      this._buildMonitorTaskSummary("exams", nowMs),
      this._buildKeepaliveTaskSummary(config, nowMs),
    ];
    return {
      ok: true,
      lazyKeepaliveActive: Boolean(config.hasPasswordAuth),
      hasPasswordAuth: Boolean(config.hasPasswordAuth),
      webhookConfigured: Boolean(this._webhook.enabled && String(this._webhook.url || "").trim()),
      activeTaskCount: this._countActiveCloudTasks(config),
      nextAlarmAt: this._nextAlarmMs ? new Date(this._nextAlarmMs).toISOString() : null,
      tasks,
    };
  }

  _buildTaskDetailPayload(taskId, config) {
    const nowMs = this._now();
    if (taskId === "monitor:grades" || taskId === "monitor:exams") {
      const kind = taskId === "monitor:grades" ? "grades" : "exams";
      const summary = this._buildMonitorTaskSummary(kind, nowMs);
      const view = formatSingleMonitorView(this._monitor[kind], nowMs);
      return {
        ok: true,
        ...summary,
        metrics: {
          baselineInitialized: view.baselineInitialized,
          trackedItemCount: view.trackedItemCount,
          totalRuns: view.totalRuns,
          changeCount: view.changeCount,
          lastDurationMs: view.lastDurationMs,
          lastError: view.lastError,
        },
        recentChanges: view.recentChanges,
        targets: [],
        logs: view.logs,
      };
    }

    if (taskId === "session:keepalive") {
      const summary = this._buildKeepaliveTaskSummary(config, nowMs);
      return {
        ok: true,
        ...summary,
        metrics: {
          baselineInitialized: Boolean(this._meta),
          trackedItemCount: this._jar.size(nowMs),
          totalRuns: this._keepaliveTask.totalRuns || 0,
          changeCount: 0,
          lastDurationMs: this._keepaliveTask.lastDurationMs ?? null,
          lastError: this._keepaliveTask.lastError || "",
        },
        sessionInfo: {
          authenticated: Boolean(this._meta && this._jar.hasActiveCookies(nowMs)),
          hasPasswordAuth: Boolean(config.hasPasswordAuth),
          lazyKeepaliveActive: Boolean(config.hasPasswordAuth),
          cookieCount: this._jar.size(nowMs),
          username: this._meta?.username || config.username || "",
          lastVerifiedAt: this._meta?.lastVerifiedAtMs
            ? new Date(this._meta.lastVerifiedAtMs).toISOString()
            : null,
        },
        recentChanges: [],
        targets: [],
        logs: this._keepaliveTask.logs || [],
      };
    }

    return null;
  }

  async _handleTaskRoute(request, url, config) {
    await this._ensureHydrated(config);
    const method = request.method.toUpperCase();
    const rest = url.pathname.slice("/v1/tasks/".length);
    const isRunAction = rest.endsWith("/run");
    const rawSegment = isRunAction ? rest.slice(0, -4) : rest;
    const taskId = decodeURIComponent(rawSegment);

    if (!taskId) {
      return jsonOut(404, { status: "NOT_FOUND", error: "未指定云端任务 ID" });
    }

    if (!isRunAction && method === "GET") {
      const detail = this._buildTaskDetailPayload(taskId, config);
      if (!detail) {
        return jsonOut(404, { status: "NOT_FOUND", error: `未找到云端任务：${taskId}` });
      }
      return jsonOut(200, detail);
    }

    if (!isRunAction && (method === "PATCH" || method === "PUT")) {
      const body = await this._readJsonBody(request);
      if (taskId === "monitor:grades" || taskId === "monitor:exams") {
        const kind = taskId === "monitor:grades" ? "grades" : "exams";
        this._applySingleMonitorPatch(kind, body);
        await this._persistMonitor();
        await this._scheduleNextAlarm(config, this._vaultEpoch);
        return jsonOut(200, this._buildTaskDetailPayload(taskId, config));
      }

      if (taskId === "session:keepalive") {
        if (body.enabled !== undefined) {
          this._keepaliveTask.overrideEnabled = Boolean(body.enabled);
        }
        if (body.intervalSec !== undefined) {
          const sec = Number.parseInt(String(body.intervalSec), 10);
          if (!Number.isNaN(sec) && sec >= 60) {
            this._keepaliveTask.intervalSec = Math.min(7200, sec);
          }
        }
        if (body.resetBaseline === true) {
          this._keepaliveTask.logs = [];
          this._keepaliveTask.totalRuns = 0;
          this._keepaliveTask.lastError = "";
        }
        await this._persistKeepaliveTask();
        await this._scheduleNextAlarm(config, this._vaultEpoch);
        return jsonOut(200, this._buildTaskDetailPayload(taskId, config));
      }

      return jsonOut(404, { status: "NOT_FOUND", error: `未找到云端任务：${taskId}` });
    }

    if (isRunAction && method === "POST") {
      const body = await this._readJsonBody(request);
      if (taskId === "monitor:grades" || taskId === "monitor:exams") {
        const kind = taskId === "monitor:grades" ? "grades" : "exams";
        await this._runSingleMonitorCheck(config, kind);
        await this._scheduleNextAlarm(config, this._vaultEpoch);
        return jsonOut(200, this._buildTaskDetailPayload(taskId, config));
      }
      if (taskId === "session:keepalive") {
        await this._runKeepaliveHeartbeat(config);
        await this._scheduleNextAlarm(config, this._vaultEpoch);
        return jsonOut(200, this._buildTaskDetailPayload(taskId, config));
      }
      return jsonOut(404, { status: "NOT_FOUND", error: `未找到云端任务：${taskId}` });
    }

    if (!isRunAction && method === "DELETE") {
      if (taskId === "monitor:grades" || taskId === "monitor:exams") {
        const kind = taskId === "monitor:grades" ? "grades" : "exams";
        this._monitor[kind] = createInitialSingleMonitorState(kind);
        await this._persistMonitor();
        await this._scheduleNextAlarm(config, this._vaultEpoch);
        return jsonOut(200, this._buildTaskDetailPayload(taskId, config));
      }
      if (taskId === "session:keepalive") {
        this._keepaliveTask = {
          ...createInitialKeepaliveTaskState(),
          overrideEnabled: false,
        };
        await this._persistKeepaliveTask();
        await this._scheduleNextAlarm(config, this._vaultEpoch);
        return jsonOut(200, this._buildTaskDetailPayload(taskId, config));
      }
      return jsonOut(404, { status: "NOT_FOUND", error: `未找到云端任务：${taskId}` });
    }

    return jsonOut(405, { status: "METHOD_NOT_ALLOWED", error: "不支持的请求方法" });
  }

  // -------------------------------------------------------------------------
  // Stateful Portal Proxy (/v1/proxy) — Lazy Re-authentication Preserved 100%
  // -------------------------------------------------------------------------

  async _handleProxy(request, config) {
    let rawRequestBytes;
    try {
      rawRequestBytes = await readBoundedResponseBytes(request, MAX_PROXY_REQUEST_BYTES);
    } catch (err) {
      if (err instanceof PortalProtocolError) {
        return jsonOut(413, {
          status: "PAYLOAD_TOO_LARGE",
          error: `代理请求体超过安全大小上限（${MAX_PROXY_REQUEST_BYTES} bytes）`,
        });
      }
      return jsonOut(400, { status: "VALIDATION_FAILED", error: "读取请求体失败" });
    }

    let payload;
    try {
      payload = JSON.parse(new TextDecoder().decode(rawRequestBytes));
    } catch {
      return jsonOut(400, { status: "VALIDATION_FAILED", error: "无效的 JSON 请求体" });
    }
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      return jsonOut(400, { status: "VALIDATION_FAILED", error: "无效的 JSON 请求体结构" });
    }

    const method = String(payload.method || "GET").toUpperCase();
    if (method !== "GET" && method !== "POST") {
      throw new PortalProtocolError("UNTRUSTED_URL", "仅支持 GET / POST 请求", 400);
    }
    const targetUrl = String(payload.url || "").trim();
    const followRedirects = payload.followRedirects !== false;
    const headers =
      payload.headers && typeof payload.headers === "object" && !Array.isArray(payload.headers)
        ? payload.headers
        : {};
    const bodyBytes = payload.bodyBase64 ? base64ToBytes(String(payload.bodyBase64)) : null;

    const policy = {
      allowedHosts: config.allowedHosts,
      requireSecure: config.requireSecure,
    };

    // Enforce HostPolicy & SSRF guard BEFORE triggering any cold-start upstream login.
    if (!isHostAllowed(targetUrl, policy.allowedHosts, policy.requireSecure)) {
      throw new PortalProtocolError(
        "UNTRUSTED_URL",
        `目标域名不在当前 Worker 绑定的高校白名单内：${targetUrl}`,
        403,
      );
    }
    const parsedTarget = new URL(targetUrl);
    if (!this._allowLoopback() && isPrivateOrLoopbackHost(parsedTarget.hostname)) {
      throw new PortalProtocolError(
        "UNTRUSTED_URL",
        `SSRF 防护拦截：禁止访问内网或环回地址 ${parsedTarget.hostname}`,
        403,
      );
    }

    // Ensure an active portal session exists before dispatching the first attempt.
    await this._ensureAuthenticated(config, { force: false });
    const attemptGen = this._authGeneration;
    let activeEpoch = this._vaultEpoch;
    const maxResponseBytes = this._maxUpstreamResponseBytes();

    let exchange = await executeWithCookieJar({
      method,
      url: targetUrl,
      headers,
      bodyBytes,
      followRedirects,
      jar: this._jar,
      policy,
      fetchImpl: this._fetchImpl(),
      timeoutMs: this._timeoutMs(),
      allowPrivateLoopback: this._allowLoopback(),
      nowFn: () => this._now(),
      maxResponseBytes,
    });

    // Security Redline #3: Only auto-replay a POST if hop 0 itself was rejected prior to
    // processing (hopCount === 0, or hop 0 redirected straight to a login URL). Never replay
    // a POST whose hop 0 redirected to a non-login business endpoint.
    const canSafelyReplay =
      method === "GET" ||
      exchange.hopCount === 0 ||
      exchange.firstHopWasLoginRedirect === true;

    if (isSessionExpiredExchange(exchange) && canSafelyReplay) {
      await this._ensureAuthenticated(config, {
        force: true,
        staleGeneration: attemptGen,
      });
      activeEpoch = this._vaultEpoch;
      exchange = await executeWithCookieJar({
        method,
        url: targetUrl,
        headers,
        bodyBytes,
        followRedirects,
        jar: this._jar,
        policy,
        fetchImpl: this._fetchImpl(),
        timeoutMs: this._timeoutMs(),
        allowPrivateLoopback: this._allowLoopback(),
        nowFn: () => this._now(),
        maxResponseBytes,
      });
    }

    if (this._vaultEpoch === activeEpoch && this._meta) {
      const nowMs = this._now();
      this._meta.lastClientAccessAtMs = nowMs;
      if (!isSessionExpiredExchange(exchange)) {
        this._meta.lastVerifiedAtMs = nowMs;
      }
      await this._persistState(config, activeEpoch);
      await this._scheduleNextAlarm(config, activeEpoch);
    }

    return jsonOut(200, {
      status: exchange.status,
      finalUrl: exchange.finalUrl,
      headers: exchange.headers,
      bodyBase64: bytesToBase64(exchange.bodyBytes),
    });
  }

  // -------------------------------------------------------------------------
  // Durable Object `alarm()` Multiplexer Dispatcher
  // -------------------------------------------------------------------------

  async alarm() {
    let config;
    try {
      config = parsePortalEnvConfig(this.env);
    } catch {
      return;
    }
    await this._ensureHydrated(config);
    const nowMs = this._now();

    // 1. Grade Monitor Tick (only if explicitly enabled AND due)
    if (this._monitor.grades.enabled) {
      const intervalMs = clampMonitorIntervalSec(this._monitor.grades.intervalSec, 1800) * 1000;
      if (!this._monitor.grades.lastRunAtMs || nowMs - this._monitor.grades.lastRunAtMs >= intervalMs - 500) {
        await this._runSingleMonitorCheck(config, "grades");
      }
    }

    // 2. Exam Monitor Tick (only if explicitly enabled AND due)
    if (this._monitor.exams.enabled) {
      const intervalMs = clampMonitorIntervalSec(this._monitor.exams.intervalSec, 3600) * 1000;
      if (!this._monitor.exams.lastRunAtMs || nowMs - this._monitor.exams.lastRunAtMs >= intervalMs - 500) {
        await this._runSingleMonitorCheck(config, "exams");
      }
    }

    // 3. Optional Active Session Keepalive Heartbeat (only if enabled AND within idle window)
    const effKeepaliveMs = this._effectiveKeepaliveMs(config);
    if (effKeepaliveMs > 0 && this._meta) {
      const lastAccess = this._meta.lastClientAccessAtMs || this._meta.authenticatedAtMs || 0;
      const withinIdle =
        config.keepaliveMaxIdleMs <= 0 || nowMs - lastAccess <= config.keepaliveMaxIdleMs;
      if (withinIdle) {
        const lastKa = this._keepaliveTask.lastRunAtMs || 0;
        if (nowMs - lastKa >= Math.min(effKeepaliveMs - 500, 1000)) {
          await this._runKeepaliveHeartbeat(config);
        }
      }
    }

    // Re-evaluate and schedule next earliest alarm (or deleteAlarm() if all tasks are idle/OFF).
    await this._scheduleNextAlarm(config, this._vaultEpoch);
  }
}

function jsonOut(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}
