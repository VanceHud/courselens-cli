/**
 * Periodic read-only monitors for grade publication (`monitor:grades`) and
 * exam schedule / seat changes (`monitor:exams`) inside `PortalSessionVault`.
 *
 * Key guarantees:
 * 1. BOTH monitors are strictly DISABLED (`enabled: false`) by default -> zero background
 *    wakeups and zero impact on lazy session re-authentication unless explicitly enabled!
 * 2. First check silently establishes a digest baseline (`baselineInitialized: true`)
 *    without firing historic notifications.
 * 3. Subsequent checks record item-level diffs into `recentChanges` (bounded 50 items)
 *    and per-run diagnostics into `logs` (bounded 50 items).
 */

import {
  PortalProtocolError,
  decodePortalText,
  encodeFormBytes,
  executeWithCookieJar,
  findElementsText,
  firstHeaderValue,
  isLoginPageHtml,
  isSessionExpiredExchange,
  safeJsonParse,
  trimTrailingSlash,
} from "./protocol.js";

export const MAX_MONITOR_CHANGES = 50;
export const MAX_MONITOR_LOGS = 50;

const XQM_CODE_MAP = {
  "3": "1",
  "1": "1",
  "12": "2",
  "2": "2",
  "16": "3",
  "32": "4",
};

export function createInitialSingleMonitorState(kind) {
  const isGrades = kind === "grades";
  return {
    kind,
    enabled: false, // Strictly OFF by default!
    intervalSec: isGrades ? 1800 : 3600,
    baselineInitialized: false,
    baselineMap: {},
    trackedItemCount: 0,
    lastRunAtMs: null,
    lastDurationMs: null,
    totalRuns: 0,
    changeCount: 0,
    lastError: "",
    lastSummary: "未开启（默认关闭）",
    recentChanges: [],
    logs: [],
  };
}

export function createInitialMonitorState() {
  return {
    grades: createInitialSingleMonitorState("grades"),
    exams: createInitialSingleMonitorState("exams"),
  };
}

export function normalizeMonitorState(saved) {
  const def = createInitialMonitorState();
  if (!saved || typeof saved !== "object") return def;
  return {
    grades: {
      ...def.grades,
      ...(saved.grades && typeof saved.grades === "object" ? saved.grades : {}),
      kind: "grades",
      enabled: Boolean(saved.grades && saved.grades.enabled === true),
    },
    exams: {
      ...def.exams,
      ...(saved.exams && typeof saved.exams === "object" ? saved.exams : {}),
      kind: "exams",
      enabled: Boolean(saved.exams && saved.exams.enabled === true),
    },
  };
}

export function clampMonitorIntervalSec(raw, fallback = 1800) {
  const n = Number.parseInt(String(raw ?? ""), 10);
  if (Number.isNaN(n)) return fallback;
  return Math.min(86400, Math.max(300, n));
}

export function computeNextSubMonitorWakeMs(sub, nowMs = Date.now()) {
  if (!sub || sub.enabled !== true) return null;
  const intervalMs = clampMonitorIntervalSec(sub.intervalSec, 1800) * 1000;
  if (!sub.lastRunAtMs) {
    return nowMs + intervalMs;
  }
  return Math.max(nowMs + 1000, sub.lastRunAtMs + intervalMs);
}

function pickStr(row, keys) {
  if (!row || typeof row !== "object") return "";
  for (const k of keys) {
    const v = row[k];
    if (v === null || v === undefined) continue;
    const s = String(v).trim();
    if (s && s !== "null" && s !== "-") return s;
  }
  return "";
}

function extractTermId(row) {
  const direct = pickStr(row, ["xqmmc", "xnxq01id", "xnxqid", "kksj", "term"]);
  if (/^\d{4}-\d{4}-\d$/.test(direct)) return direct;
  const xnm = pickStr(row, ["xnm", "XNM"]);
  const xqm = pickStr(row, ["xqm", "XQM"]);
  if (/^\d{4}$/.test(xnm)) {
    const yr = Number.parseInt(xnm, 10);
    const sem = XQM_CODE_MAP[xqm] || "1";
    return `${yr}-${yr + 1}-${sem}`;
  }
  return direct;
}

function extractItemsArray(body) {
  const parsed = safeJsonParse(body);
  if (!parsed) return null;
  if (Array.isArray(parsed)) return parsed;
  if (typeof parsed === "object") {
    for (const k of ["items", "data", "rows", "list", "aaData"]) {
      if (Array.isArray(parsed[k])) return parsed[k];
    }
    if (parsed.data && typeof parsed.data === "object") {
      for (const k of ["items", "rows", "list"]) {
        if (Array.isArray(parsed.data[k])) return parsed.data[k];
      }
    }
  }
  return null;
}

async function requestPortalText({
  method = "GET",
  url,
  formObj = null,
  ajax = true,
  jar,
  policy,
  fetchImpl,
  timeoutMs,
  allowPrivateLoopback,
  nowFn,
}) {
  const headers = {
    Accept: ajax
      ? "application/json, text/javascript, */*; q=0.01"
      : "text/html,application/xhtml+xml,*/*;q=0.8",
  };
  if (ajax) headers["X-Requested-With"] = "XMLHttpRequest";
  let bodyBytes = null;
  if (formObj && method === "POST") {
    headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8";
    bodyBytes = encodeFormBytes(Object.entries(formObj));
  }
  const ex = await executeWithCookieJar({
    method,
    url,
    headers,
    bodyBytes,
    followRedirects: true,
    jar,
    policy,
    fetchImpl,
    timeoutMs,
    allowPrivateLoopback,
    nowFn,
  });
  const ct = firstHeaderValue(ex.headers, "content-type");
  const text = decodePortalText(ex.bodyBytes, ct);
  if (isSessionExpiredExchange(ex) || isLoginPageHtml(text)) {
    throw new PortalProtocolError("SESSION_EXPIRED", "会话已过期", 401);
  }
  if (ex.status < 200 || ex.status > 299) {
    throw new PortalProtocolError("NETWORK_ERROR", `上游返回 HTTP ${ex.status}`, 502);
  }
  return text;
}

export async function fetchPortalGradesDigest({
  effectiveBaseUrl,
  systemId = "ZF",
  jar,
  policy,
  fetchImpl = fetch,
  timeoutMs = 18000,
  allowPrivateLoopback = false,
  nowFn = Date.now,
}) {
  const root = trimTrailingSlash(effectiveBaseUrl);
  const sys = String(systemId || "ZF").toUpperCase();
  const rows = [];

  if (sys.startsWith("QZ")) {
    const text = await requestPortalText({
      method: "POST",
      url: `${root}/kscj/cjcx_list`,
      formObj: { kksj: "", kcxz: "", kcmc: "", xsfs: "all" },
      ajax: false,
      jar,
      policy,
      fetchImpl,
      timeoutMs,
      allowPrivateLoopback,
      nowFn,
    });
    const jsonRows = extractItemsArray(text);
    if (jsonRows) {
      rows.push(...jsonRows);
    } else {
      const trs = findElementsText(text, (tag) => tag === "tr");
      for (const tr of trs) {
        const parts = tr.text.split(/\s+/).filter(Boolean);
        if (parts.length >= 5 && /^\d{4}-\d{4}-\d$/.test(parts[1] || "")) {
          rows.push({
            kksj: parts[1],
            kch: parts[2],
            kcmc: parts[3],
            zcj: parts[4],
            xf: parts[5] || "",
            jd: parts[7] || "",
          });
        }
      }
    }
  } else {
    const queryForm = {
      xnm: "",
      xqm: "",
      "queryModel.showCount": "300",
      "queryModel.currentPage": "1",
      "queryModel.sortName": "",
      "queryModel.sortOrder": "asc",
      time: "0",
    };
    let text = "";
    try {
      text = await requestPortalText({
        method: "POST",
        url: `${root}/cjcx/cjcx_cxXsgrcj.html?doType=query&gnmkdm=N305005`,
        formObj: queryForm,
        ajax: true,
        jar,
        policy,
        fetchImpl,
        timeoutMs,
        allowPrivateLoopback,
        nowFn,
      });
    } catch (err) {
      if (err instanceof PortalProtocolError && err.status === "SESSION_EXPIRED") throw err;
      text = await requestPortalText({
        method: "POST",
        url: `${root}/cjcx/cjcx_cxDgXscj.html?doType=query&gnmkdm=N305005`,
        formObj: queryForm,
        ajax: true,
        jar,
        policy,
        fetchImpl,
        timeoutMs,
        allowPrivateLoopback,
        nowFn,
      });
    }
    const jsonRows = extractItemsArray(text) || [];
    rows.push(...jsonRows);
  }

  const map = {};
  for (const row of rows) {
    const name = pickStr(row, ["kc_mc", "kcmc", "KCMC", "courseName"]);
    if (!name) continue;
    const term = extractTermId(row);
    const code = pickStr(row, ["kch", "kch_id", "KCH", "KCH_ID"]);
    const nature = pickStr(row, ["ksxz", "KSXZ"]);
    const score = pickStr(row, ["zcjstr", "cj", "zcj", "CJ"]);
    const gpa = pickStr(row, ["jd", "JD"]);
    const credit = pickStr(row, ["xf", "XF"]);
    const key = `${term}|${code || name}|${nature || "正考"}`;
    map[key] = {
      key,
      term,
      courseCode: code,
      courseName: name,
      score,
      gpa,
      credit,
      fingerprint: `${score}|${gpa}|${credit}`,
    };
  }
  return map;
}

export async function fetchPortalExamsDigest({
  effectiveBaseUrl,
  systemId = "ZF",
  jar,
  policy,
  fetchImpl = fetch,
  timeoutMs = 18000,
  allowPrivateLoopback = false,
  nowFn = Date.now,
}) {
  const root = trimTrailingSlash(effectiveBaseUrl);
  const sys = String(systemId || "ZF").toUpperCase();
  const rows = [];

  if (sys.startsWith("QZ")) {
    const text = await requestPortalText({
      method: "POST",
      url: `${root}/xsks/xsksap_list`,
      formObj: { xnxqid: "", xqlb: "" },
      ajax: false,
      jar,
      policy,
      fetchImpl,
      timeoutMs,
      allowPrivateLoopback,
      nowFn,
    });
    const jsonRows = extractItemsArray(text);
    if (jsonRows) rows.push(...jsonRows);
  } else {
    const text = await requestPortalText({
      method: "POST",
      url: `${root}/kwgl/kscx_cxXsksxxIndex.html?doType=query&gnmkdm=N358105`,
      formObj: {
        xnm: "",
        xqm: "",
        ksmcdmb_id: "",
        "queryModel.showCount": "200",
        "queryModel.currentPage": "1",
      },
      ajax: true,
      jar,
      policy,
      fetchImpl,
      timeoutMs,
      allowPrivateLoopback,
      nowFn,
    });
    const jsonRows = extractItemsArray(text) || [];
    rows.push(...jsonRows);
  }

  const cleanExamVal = (v) =>
    v === "未放开不可查" || v === "不可查" ? "" : v;

  const map = {};
  for (const row of rows) {
    const name = pickStr(row, ["kskcmc", "kcmc", "kc_mc"]);
    if (!name) continue;
    const term = extractTermId(row);
    const examName = pickStr(row, ["ksccmc", "ksmc", "ksxz"]);
    const time = cleanExamVal(pickStr(row, ["kssj", "ksrq", "kssjms"]));
    const campus = cleanExamVal(pickStr(row, ["cdxqmc", "ksxq", "xqmc"]));
    const room = cleanExamVal(pickStr(row, ["js_mc", "cdmc", "ksdd"]));
    const location = [campus, room].filter(Boolean).join(" ");
    const seat = cleanExamVal(pickStr(row, ["zwh", "zwh_mc"]));
    const key = `${term}|${name}|${examName || "期末"}`;
    map[key] = {
      key,
      term,
      courseName: name,
      examName,
      time,
      location,
      seat,
      fingerprint: `${time}|${location}|${seat}`,
    };
  }
  return map;
}

export function applyMonitorDigestResult(subState, currentMap, nowMs = Date.now(), durationMs = 0) {
  const next = structuredClone(subState);
  const items = Object.values(currentMap || {});
  const newBaseline = {};
  for (const it of items) {
    newBaseline[it.key] = it.fingerprint;
  }

  next.lastRunAtMs = nowMs;
  next.lastDurationMs = durationMs;
  next.totalRuns = (next.totalRuns || 0) + 1;
  next.trackedItemCount = items.length;
  next.lastError = "";

  if (!next.baselineInitialized) {
    next.baselineInitialized = true;
    next.baselineMap = newBaseline;
    next.lastSummary =
      next.kind === "grades"
        ? `已建立初始成绩基线（共 ${items.length} 门课程）`
        : `已建立初始考试基线（共 ${items.length} 场考试）`;
    next.logs = [
      {
        atMs: nowMs,
        at: new Date(nowMs).toISOString(),
        status: "BASELINE_INIT",
        durationMs,
        message: next.lastSummary,
      },
      ...(next.logs || []),
    ].slice(0, MAX_MONITOR_LOGS);
    return { subState: next, changes: [], notification: null };
  }

  const prevBaseline = next.baselineMap || {};
  const detected = [];
  for (const item of items) {
    const oldFp = prevBaseline[item.key];
    if (oldFp === undefined) {
      detected.push({
        changeType: "ADDED",
        detectedAt: new Date(nowMs).toISOString(),
        ...item,
        previousFingerprint: "",
      });
    } else if (oldFp !== item.fingerprint) {
      detected.push({
        changeType: "UPDATED",
        detectedAt: new Date(nowMs).toISOString(),
        ...item,
        previousFingerprint: oldFp,
      });
    }
  }

  next.baselineMap = newBaseline;
  if (detected.length === 0) {
    next.lastSummary =
      next.kind === "grades"
        ? `未发现新出分（当前追踪 ${items.length} 门成绩）`
        : `未发现考场变动（当前追踪 ${items.length} 场考试）`;
    next.logs = [
      {
        atMs: nowMs,
        at: new Date(nowMs).toISOString(),
        status: "NO_CHANGE",
        durationMs,
        message: next.lastSummary,
      },
      ...(next.logs || []),
    ].slice(0, MAX_MONITOR_LOGS);
    return { subState: next, changes: [], notification: null };
  }

  next.changeCount = (next.changeCount || 0) + detected.length;
  next.recentChanges = [...detected, ...(next.recentChanges || [])].slice(0, MAX_MONITOR_CHANGES);

  let title;
  let bodyLines;
  if (next.kind === "grades") {
    title = `📢 检测到 ${detected.length} 门新成绩/成绩更新`;
    bodyLines = detected.map(
      (d) =>
        `• ${d.courseName}：成绩 ${d.score || "已更新"}${d.gpa ? `（绩点 ${d.gpa}）` : ""}${d.credit ? ` · ${d.credit} 学分` : ""}`,
    );
  } else {
    title = `📅 检测到 ${detected.length} 场考试安排/考场更新`;
    bodyLines = detected.map(
      (d) =>
        `• ${d.courseName}：${d.time || "时间待定"} @ ${d.location || "地点待定"}${d.seat ? `（座号 ${d.seat}）` : ""}`,
    );
  }

  next.lastSummary = title;
  next.logs = [
    {
      atMs: nowMs,
      at: new Date(nowMs).toISOString(),
      status: "CHANGED",
      durationMs,
      message: `${title}：${detected.map((d) => d.courseName).join("、")}`,
    },
    ...(next.logs || []),
  ].slice(0, MAX_MONITOR_LOGS);

  return {
    subState: next,
    changes: detected,
    notification: {
      event: next.kind === "grades" ? "grade_change" : "exam_change",
      title,
      body: bodyLines.slice(0, 8).join("\n"),
      taskId: `monitor:${next.kind}`,
    },
  };
}

export function applyMonitorError(subState, errorMessage, nowMs = Date.now(), durationMs = 0) {
  const next = structuredClone(subState);
  next.lastRunAtMs = nowMs;
  next.lastDurationMs = durationMs;
  next.totalRuns = (next.totalRuns || 0) + 1;
  next.lastError = String(errorMessage || "巡检请求失败").slice(0, 200);
  next.lastSummary = `异常：${next.lastError}`;
  next.logs = [
    {
      atMs: nowMs,
      at: new Date(nowMs).toISOString(),
      status: "ERROR",
      durationMs,
      message: next.lastSummary,
    },
    ...(next.logs || []),
  ].slice(0, MAX_MONITOR_LOGS);
  return next;
}

export function formatSingleMonitorView(sub, nowMs = Date.now()) {
  const s = sub || createInitialSingleMonitorState("grades");
  const nextWake = computeNextSubMonitorWakeMs(s, nowMs);
  return {
    taskId: `monitor:${s.kind}`,
    kind: s.kind,
    enabled: Boolean(s.enabled),
    intervalSec: clampMonitorIntervalSec(s.intervalSec, s.kind === "grades" ? 1800 : 3600),
    baselineInitialized: Boolean(s.baselineInitialized),
    trackedItemCount: s.trackedItemCount || 0,
    totalRuns: s.totalRuns || 0,
    changeCount: s.changeCount || 0,
    lastDurationMs: s.lastDurationMs ?? null,
    lastRunAt: s.lastRunAtMs ? new Date(s.lastRunAtMs).toISOString() : null,
    nextWakeAt: nextWake ? new Date(nextWake).toISOString() : null,
    lastError: s.lastError || "",
    lastSummary: s.enabled ? (s.lastSummary || "待命") : "未开启（默认关闭）",
    recentChanges: s.recentChanges || [],
    logs: s.logs || [],
  };
}
