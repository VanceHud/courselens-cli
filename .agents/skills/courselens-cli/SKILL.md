---
name: courselens-cli
description: >-
  Query university academic portals (高校教务系统：新旧正方 ZF/ZF_OLD、新旧强智 QZ/QZ_OLD) via
  the native `courselens` CLI: daily classes & exam countdowns (今日课程/明日课表), weekly
  timetables & `.ics` export (课表查询与日历导出), transcripts & GPA/绩点 stats (查成绩、加权均分、
  必修绩点), exam schedules & seats (考试安排/考场座位), degree audit progress (培养方案/学业进度),
  empty classrooms (空教室查询), enrolled/selectable courses, and confirmation-gated
  course selection/drop (选课/退课). Activate whenever the user mentions CourseLens,
  教务系统, 课表, 今日课程, 上什么课, 查成绩, GPA, 绩点, 考试安排, 考场, 培养方案, 空教室, 选课,
  退课, `/cli-auth` Web Credential Bridge, or `.har`/Cookie session import for university portals.
---

# CourseLens Academic Portal CLI (`courselens`)

Operate the native `courselens` CLI built on CourseLens's 100% pure-Dart protocol core (`lib/core/`) to inspect timetables, grades, GPA, exams, degree progress, empty classrooms, and confirmation-gated course selection across Zhengfang (`ZF` / `ZF_OLD`) and Qingzhi (`QZ` / `QZ_OLD`) university portals.

## Portable Binary Resolution & Key Paths

- **Locating the native `courselens` binary** (check in order):
  1. `courselens` on `PATH` (`command -v courselens`) or `~/.local/bin/courselens`;
  2. `./build/courselens` if already inside a CourseLens checkout;
  3. If `SKILL.md` is located inside or symlinked from a local CourseLens repo (`<repo>/.agents/skills/courselens-cli/SKILL.md`), resolve `SKILL.md`'s real path via `python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "<path-to-this-SKILL.md>"` (or `readlink`) to locate `<repo>/build/courselens`, compiling it inside `<repo>` if missing:
     ```bash
     export PATH="$HOME/.local/bin:$PATH"
     if ! command -v courselens >/dev/null 2>&1; then
       SKILL_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "<path-to-this-SKILL.md>")"
       REPO_DIR="$(cd "$(dirname "$SKILL_REAL")/../../.." && pwd)"
       if [ ! -x "$REPO_DIR/build/courselens" ]; then
         (cd "$REPO_DIR" && dart pub get && dart compile exe tools/courselens_cli.dart -o build/courselens)
       fi
       mkdir -p "$HOME/.local/bin" && ln -sf "$REPO_DIR/build/courselens" "$HOME/.local/bin/courselens"
     fi
     ```
  - Standalone `--demo` fixtures are embedded directly in the binary, so `courselens --demo ...` works from any working directory without repo `assets/`.
- **Session & credential stores**:
  - **macOS (`auto` default)**: macOS Keychain (`service: dev.courselens.cli`, `account: default`)
  - **Linux / explicit file**: `~/.config/courselens/session.json` (`0600` owner-only permissions strictly enforced)
  - **Environment (`env`)**: `COURSELENS_BASE_URL`, `COURSELENS_COOKIES`, `COURSELENS_USERNAME`, `COURSELENS_PASSWORD`, `COURSELENS_SCHOOL_TYPE`, `COURSELENS_RELAY_URL`, `COURSELENS_WORKER_URL`, `COURSELENS_API_KEY` (read-only)
- **Full CLI & security manuals** (relative to `<repo>/.agents/skills/courselens-cli/SKILL.md`):
  - [docs/cli-and-agent-skill.md](../../../docs/cli-and-agent-skill.md)
  - [docs/stateful-worker-api-key.md](../../../docs/stateful-worker-api-key.md)
  - [docs/security.md](../../../docs/security.md)

---

## Critical Agent Safety & Token Efficiency Rules (READ FIRST)

1. **Check session first with `whoami` — NEVER handle plaintext passwords in chat or `argv`**:
   - Always check liveness first (ensure `~/.local/bin` is in `PATH` or invoke `~/.local/bin/courselens`):
     ```bash
     courselens whoami
     ```
   - **NEVER** ask the user to paste their portal password into chat, and **NEVER** pass `--password` or `--api-key` on CLI `argv` (both are intentionally rejected to prevent `ps` / shell history leaks).
   - When unauthenticated or expired, prefer in order:
     1. Existing macOS Keychain or `0600` `~/.config/courselens/session.json` session (or `COURSELENS_WORKER_URL` + `COURSELENS_API_KEY` environment variables if using a self-hosted stateful Worker gateway);
     2. **Stateful Cloudflare Worker Session Gateway** (`courselens auth worker --url <workerUrl> [--api-key-stdin | --api-key-env <VAR>]`) if the user hosts `workers/session_gateway/` (supports 1-click Deploy to Cloudflare button or `npx wrangler deploy`);
     3. **Stateless `/cli-auth` Web Credential Bridge** (`<your-relay-origin>/cli-auth?url=<baseUrl>`) if the user has deployed a CourseLens stateless Web relay and uses a **Password-Vault AI Agent** / browser autofill that fills standard HTML `<input name="username">` / `<input name="password">` without exposing plaintext passwords to the LLM;
     4. `.har` packet capture or `Cookie` import (`courselens auth import-cookie --url <baseUrl> --har <capture.har>`), which works seamlessly with CAS / SSO / QR-code portals;
     5. Asking the user to run interactive `courselens auth login --url <baseUrl> --user <id>` directly in their own terminal (uses hidden TTY input with `echoMode = false`).
2. **Mandatory two-step dry-run gate for `select` and `drop` (Redline #2)**:
   - **ALWAYS run `select` / `drop` WITHOUT `--confirm` first**:
     - Exits with **code `2`**, sends **zero** write network packets, validates target class (`jxbId`) & `ScheduleConflicts`, and prints the preview + exact `--confirm` command (`--json` includes `"confirmed": false, "previewOnly": true`).
   - Show the dry-run preview (course name, teacher, schedule slot, conflicts) to the user and **ONLY run with `--confirm` after explicit user confirmation**.
3. **Never blindly re-run `--confirm` on `RESULT_UNKNOWN` / timeout (Redline #3)**:
   - If `select --confirm` or `drop --confirm` hits a network timeout or returns `RESULT_UNKNOWN`, **NEVER** blindly re-POST `--confirm`. Inspect the CLI's automatic read-only verification output or run `courselens courses` to confirm whether the portal already applied the change.
4. **Fail-closed storage (`STORAGE_UNAVAILABLE` — Redline #1)**:
   - Keychain errors throw `STORAGE_UNAVAILABLE` without silent plaintext fallback. File sessions with group/world bits (`mode & 0x3f != 0`, e.g. `0644`) are rejected until fixed via `chmod 600 <path>`.
5. **Token efficiency**:
   - Use **`courselens today`** (`[--date YYYY-MM-DD]`) as your **preferred 1-shot command** for daily briefings (current academic week + today's/tomorrow's classes + exam countdowns).
   - Default `stdout` is compact Markdown/tables (diagnostics go to `stderr`). Use `--json | jq ...` when filtering large `rooms`, `plan`, or `courses` payloads instead of dumping full tables into context.

---

## Global Flags

Usable with any subcommand:

| Flag | Description |
| --- | --- |
| `--demo` | Run offline against embedded sanitized demo fixtures (works from any CWD) |
| `--json` | Emit structured JSON on `stdout` (diagnostics/errors stay on `stderr`) |
| `--term <term>` | Override academic term (e.g. `2025-2026-1`) |
| `--relay <url>` | Forward HTTP via stateless relay (`http://127.0.0.1:8787` or Cloudflare Worker URL) |
| `--worker <name\|url>` | Route via saved gateway alias or stateful Cloudflare Worker session gateway (`workers/session_gateway/`) |
| `--store <auto\|keychain\|file\|env>` | Select credential/session store backend (`auto` default) |
| `--session-file <path>` | Explicit `0600` JSON session file path (uses `file` backend) |
| `-h`, `--help` | Show CLI or subcommand usage help |
| `--version` | Print CLI version |

---

## Command Reference & Workflows

### 1. Authentication & Multi-Gateway Session Management

```bash
# Check active store backend, baseUrl, systemType (ZF/ZF_OLD/QZ/QZ_OLD), student info & session liveness
courselens whoami
courselens auth status [--offline]

# Bind/save, list, switch, or remove stateful Cloudflare Worker Session Gateways (--api-key on argv is rejected!)
courselens auth worker \
  --url <https://session.example.workers.dev> [--name <alias>] \
  [--api-key-stdin | --api-key-env <VAR>] [--no-verify]
courselens auth worker --list
courselens auth worker --use <alias|url> [--no-verify]
courselens auth worker --remove <alias|url>

# Import session from .har capture (Loon / Reqable / Proxyman / Charles / DevTools) or Cookie header
courselens auth import-cookie \
  --url <baseUrl> \
  (--cookie <header> | --cookie-stdin | --har <capture.har>) \
  [--user <id>] [--system <auto|ZF|ZF_OLD|QZ|QZ_OLD>] [--no-verify]

# Direct portal login (NOTE: --password on argv is intentionally rejected for ps security!)
# For human interactive terminal (hidden TTY prompt) or piped/env secret:
courselens auth login \
  --url <baseUrl> --user <id> \
  [--password-stdin | --password-env <VAR>] \
  [--system <auto|ZF|ZF_OLD|QZ|QZ_OLD>]

# Seal in-memory CookieJar via session.retire() (Redline #5) and clear stored credentials (--keep-workers preserves saved Worker profiles)
courselens auth logout [--keep-workers]
```

#### Stateless `/cli-auth` Web Credential Bridge (Password-Vault AI Agents)

University portals mark `JSESSIONID` as `HttpOnly`, preventing normal browser scripts (`document.cookie`) from exporting session cookies. If the user has deployed a CourseLens stateless Web relay (`<your-relay-origin>/cli-auth`), it serves a stateless Web Credential Bridge (`GET /cli-auth?url=<portalUrl>[&system=auto|ZF|QZ][&cas=<casUrl>][&relay=1]`) that authenticates in browser memory (`BigInt` RSA PKCS#1 v1.5 / CAS / Qingzhi `scode`) via same-origin `POST /v1/forward` (`hopCookies`) under strict CSP (`connect-src 'self'; form-action 'none'`, `Cache-Control: no-store`) with zero `localStorage` / `sessionStorage` / `indexedDB` / `document.cookie` or server storage.

This enables **Password-Vault AI Agents** (which store `(URL, username, password)` in an encrypted vault and auto-fill standard HTML login forms without ever exposing plaintext passwords to the LLM):

- **Autofill-Safe DOM Contract**:
  - Portal configuration controls sit **outside** `#login-form` (`<form id="login-form">`) with `autocomplete="off"` so credential autofill never mis-targets them: `#portal-url` (`?url=`), `#portal-system` (`?system=auto|ZF|QZ`), optional `#cas-url` (`?cas=`), and `#include-relay` (`?relay=1`, appends `--relay '<origin>'` to `#cli-import-cmd`).
  - `#login-form` (`<form id="login-form">`) contains **only** `#username` (`input[name="username"]`), `#password` (`input[name="password"]`), and `#login-submit` (`button[type="submit"]`).
- **4-Step Agent Workflow**:
  1. Navigate to `<your-relay-origin>/cli-auth?url=<portalUrl>`.
  2. Auto-fill `#username` (`input[name="username"]`) and `#password` (`input[name="password"]`), then submit `#login-submit` (`#password.value` is immediately wiped to `''` from the DOM on submit before network I/O so post-submit screenshots/DOM reads never see the password).
  3. Wait for `#auth-status[data-state="authenticated"]` (`data-state` transitions `idle` -> `working` -> `authenticated` or `error`; `#auth-result` un-hides `#cli-session-meta`, `#cli-cookie-json`, `#cli-import-cmd`, `#copy-json-btn`, and `#copy-cmd-btn`).
  4. Read `#cli-cookie-json` (JSON cookie map, e.g. `{"JSESSIONID":"..."}`) and pipe it into `courselens auth import-cookie --url <portalUrl> --cookie-stdin` (or run the shell-escaped command in `#cli-import-cmd`).

### 2. Read-Only Academic Queries

All commands below perform strictly **read-only** requests (`0` exit code on success):

```bash
# Preferred 1-shot daily briefing: academic week, today & tomorrow classes, exam countdowns
courselens today [--date YYYY-MM-DD]

# Weekly schedule + practical courses (sjkList) + conflict warnings; optional RFC 5545 .ics export
courselens schedule [--week <1..30>] [--ics <out.ics>]

# Course transcript list; pass --stats for weighted average, compulsory GPA & credit breakdown
courselens grades [--stats]

# Exam schedule, classroom venue, seat number & countdown
courselens exams

# Degree audit / curriculum credit tree (N105515)
courselens plan

# Empty classroom lookup (N2155; specs accept ranges/lists like 1-16 or 1,3,5)
courselens rooms \
  [--campus <id>] [--day <1..7>] [--weeks <spec>] [--sections <spec>]

# Enrolled courses (N255010) + selectable offerings with optional keyword filter
courselens courses [--query <kw>]
```

#### Token-Efficient Filtering Examples (`--json | jq`)

```bash
# Filter empty classrooms on Wednesday (day 3), sections 1-2, week 8
courselens rooms \
  --day 3 --weeks 8 --sections 1-2 --json | jq '.rooms[:15]'

# Search courses matching a keyword in JSON mode
courselens courses \
  --query "数学" --json | jq '.'
```

### 3. Stateful Cloud Worker Gateway Commands (`worker`)

When connected to a stateful Cloudflare Worker (`workers/session_gateway/`), manage cloud tasks, dynamic cookie push, Webhooks, and default-OFF grade/exam monitors:

```bash
# Inspect unified cloud task list & single task detail (metrics, changes, logs)
courselens worker tasks list
courselens worker tasks show <monitor:grades|monitor:exams|session:keepalive>

# Toggle scheduled checks independently (all default to OFF; zero impact on lazy keep-alive when OFF)
courselens worker tasks enable monitor:grades [--interval 1800] [--reset-baseline]
courselens worker tasks disable monitor:grades
courselens worker tasks run <taskId> [--confirm]

# Push QR/SSO cookies or configure Webhook / monitors (--webhook-secret & --secret on argv are rejected!)
courselens worker push-cookies (--cookie <hdr> | --cookie-stdin | --har <file.har>) [--url <portalUrl>]
courselens worker webhook set --url <https://...> [--provider <auto|bark|feishu|dingtalk|wecom|telegram|generic>] [--secret-stdin | --secret-env <VAR>]
courselens worker webhook test
courselens worker monitor [status | set [--grades <on|off>] [--exams <on|off>] | check [--kind <all|grades|exams>]]
```

### 4. Controlled Write Commands (`select` / `drop`)

```bash
# STEP 1 (MANDATORY): Dry-run preview WITHOUT --confirm -> zero write packets, exits with code 2
courselens select --course-id <id> [--class-id <jxbId>]
courselens drop --course-id <id> [--class-id <jxbId>]

# STEP 2 (ONLY AFTER EXPLICIT USER CONFIRMATION): Execute single confirmed write
courselens select --course-id <id> [--class-id <jxbId>] --confirm
courselens drop --course-id <id> [--class-id <jxbId>] --confirm
```

- **Exit code `0`**: Command succeeded (or `--confirm` write succeeded / verified).
- **Exit code `2`**: Dry-run preview completed (`select` or `drop` called without `--confirm`); zero write packets were sent. Present preview to the user before asking to confirm.
- **Exit code `1` (non-zero)**: Runtime, validation, authentication, or `STORAGE_UNAVAILABLE` error (details on `stderr` or JSON error envelope).

### 5. Self-Update (`update`)

Keep the CLI itself, this Skill, and the deployed session gateway in sync with the open-source repo (`VanceHud/courselens-cli`):

```bash
# ALWAYS check first: reports per-component status without changing anything
courselens update --check

# Update everything applicable (default when no component flag is given)
courselens update [--all]

# Or update a single component
courselens update --cli     # CLI binary
courselens update --skill   # this SKILL.md in installed skill directories
courselens update --worker  # redeploy the bound session gateway Worker
```

How each component updates:

- **CLI (`--cli`)**: When running from a source checkout (a git repo containing `pubspec.yaml` with `name: courselens` + `tools/courselens_cli.dart`, located via `COURSELENS_REPO_DIR`, `<repo>/build/courselens`, cwd ancestry, or `~/.local/share/courselens-cli`), the updater fetches, refuses to pull over a dirty working tree, `git pull --ff-only`, recompiles `build/courselens` (`.exe` on Windows), and installs it over a copied (non-symlink) running binary with a `.bak` backup. Without a checkout it falls back to the latest GitHub Release asset `courselens-<os>-<arch>[.exe]`; if no Release exists it says so and skips (not an error).
- **Skill (`--skill`)**: Compares `SKILL.md` in `COURSELENS_SKILL_DIR`, `~/.claude/skills/courselens-cli`, `~/.codex/skills/courselens-cli`, and `~/.agents/skills/courselens-cli` against the latest (checkout copy first, else the raw file on GitHub `main`). Regular files are backed up to `SKILL.md.bak` before overwriting; symlinks are never rewritten — a symlink into a checkout becomes current as soon as the checkout is pulled.
- **Worker (`--worker`)**: Reads the bound gateway's public `GET /health` `version` field (no API key needed; gateways deployed before versioning report as "无版本号（旧版）"). When outdated, it deploys from `<checkout>/workers/session_gateway/` with `npx wrangler deploy` (prefers local `wrangler.toml` if present, otherwise uses the built-in `wrangler.jsonc` with `"keep_vars": true`, requiring a logged-in wrangler session), then re-checks `/health` to confirm the new version. **Deploying never touches injected Secrets** (`COURSELENS_API_KEY`, `PORTAL_PASSWORD` stay on the Cloudflare side).

Exit codes for `update`: `0` when the check/update completes (including "already latest" and explained skips), `1` only on hard failures such as a compile or deploy error. Agents should run `courselens update --check` first, show the user the per-component result, and only then run the real update.
