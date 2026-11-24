# 安全模型与 7 条硬红线

CourseLens CLI 的核心设计目标，是在不引入第三方中心化后台存储用户账号的前提下，保证本地命令行、AI Agent 与个人自托管会话网关在身份凭据、网络边界与教务写操作上的可验证安全性。

下面列出本项目强制执行的 **7 条安全与正确性硬红线**。

## 红线总览

### 1. 安全存储不可用时快速失败，绝不静默降级明文；严禁命令行明文秘密参数
- **存储快速失败**：[`CliCredentialStore`](../lib/cli/store/cli_credential_store.dart) 在 macOS 下通过 [`macos_keychain.dart`](../lib/cli/store/macos_keychain.dart) 在进程内直接调用 `Security.framework`（写入后立即清零原生内存缓冲区，避免拉起 `/usr/bin/security` 子进程导致 `argv` 泄露）；在 Linux/POSIX 下强制使用 `0700` 目录与 `0600` 会话文件（读取时执行 `stat` 校验，若存在任何组或其他用户权限位 `mode & 0x3f != 0` 则立即拒绝加载）。任何异常统一抛出 `STORAGE_UNAVAILABLE`，绝不静默降级到明文文件。
- **拒绝 `argv` 泄密与环境密钥绑定**：[`CliArgs`](../lib/cli/cli_args.dart) 主动拦截并拒绝 `--password`、`--api-key`、`--webhook-secret`、`--secret` 等命令行参数，防止凭据被 `ps aux` 或 Shell 历史记录捕获；只允许 TTY 关闭回显交互输入、`--*-stdin` 管道或 `--*-env` 环境变量；且环境变量 `COURSELENS_API_KEY` 仅在归一化后的 `COURSELENS_WORKER_URL` 与目标网关一致时生效，杜绝将密钥误发给其他网关。
- **验证**：[`test/cli_store_test.dart`](../test/cli_store_test.dart) & [`test/courselens_cli_test.dart`](../test/courselens_cli_test.dart)。

### 2. 选课 / 退课写操作未获显式确认前零网络发包
- **协议层与网关双重门禁**：[`ZhengfangSelection`](../lib/core/selection/zhengfang_selection.dart) 的 `select(...)` 与 `drop(...)` 要求显式传入 `confirmed: true`（否则零发包直接返回 `AcademicStatus.VALIDATION_FAILED`），并将请求标记为 `confirmedSelection: true` 路由至有状态网关独立的 `POST /v1/selection`（携带 `confirmed: true` 并由 [`proxy_policy.js`](../workers/session_gateway/src/proxy_policy.js) 校验白名单路径）；通用 `POST /v1/proxy` 仅放行已知只读教务查询。
- **CLI 护栏**：CLI 的 `select` / `drop` 命令默认只做零写发包干跑预检、冲突检测并输出待确认命令（以退出码 `2` 结束），必须显式加 `--confirm` 才真正发包；Agent Skill 同样规定写操作必须先向用户展示预检结果并取得明确确认。
- **验证**：[`test/core/login_study_selection_test.dart`](../test/core/login_study_selection_test.dart)、[`test/courselens_cli_test.dart`](../test/courselens_cli_test.dart) & [`workers/session_gateway/test/worker.test.mjs`](../workers/session_gateway/test/worker.test.mjs)。

### 3. 超时 `RESULT_UNKNOWN` 严禁自动重发写包
- **实现**：当非幂等 `POST` 请求已发出但遭遇超时、连接中断、响应截断或未识别 5xx 时，[`IoHttpEngine`](../lib/data/http/io_http_engine.dart)、[`RelayHttpEngine`](../lib/data/http/relay_http_engine.dart)、[`WorkerSessionHttpEngine`](../lib/data/http/worker_session_http_engine.dart)（经共享 [`uncertain_write.dart`](../lib/data/http/uncertain_write.dart) 与 [`gateway_response_decoder.dart`](../lib/data/http/gateway_response_decoder.dart)）与云端网关 [`workers/session_gateway/`](../workers/session_gateway/) 均将异常标记为 `AcademicStatus.RESULT_UNKNOWN`。
- **核查行为**：写操作返回 `RESULT_UNKNOWN` 后，唯一允许的后续动作是只读查询已选课程名单核实结果（同时云端网关自动失效课表/已选/培养方案缓存），绝不自动重发写请求；核实前不得假设成功或失败。
- **验证**：[`test/data/gateway_response_decoder_test.dart`](../test/data/gateway_response_decoder_test.dart)、[`test/courselens_cli_test.dart`](../test/courselens_cli_test.dart) & [`workers/session_gateway/test/worker.test.mjs`](../workers/session_gateway/test/worker.test.mjs)。

### 4. 逐跳主机白名单与重定向钓鱼阻断
- **HostPolicy 五条纪律（[`lib/core/net/host_policy.dart`](../lib/core/net/host_policy.dart)）**：
  1. 仅允许 `http` / `https` 协议（拦截 `javascript:`、`file:`、`data:` 等）；
  2. 拒绝包含 `userinfo` 的钓鱼 URL（如 `https://jw.example.edu.cn@evil.com/`）；
  3. 开启 `requireSecure` 时严禁任何明文 `http` 降级；
  4. 端口必须精确匹配；
  5. 主机名必须完全相等，不做隐式通配（公共后缀识别严格区分 `.edu.cn` / `.ac.cn` 等双标签后缀）。
- **逐跳手动重定向与跨源保护**：[`IoHttpEngine`](../lib/data/http/io_http_engine.dart) 与有状态网关 [`workers/session_gateway/src/protocol.js`](../workers/session_gateway/src/protocol.js) 均禁用自动跟随重定向，在每一跳发包前再次执行 `HostPolicy` 校验；跨源重定向会丢弃首跳 `Cookie`、`Authorization`、`Proxy-Authorization`、`Origin`、`Referer`，并拦截跨源保留请求体的 307/308 POST 重定向。
- **反代同主机兼容**：针对高校常见的“Nginx TLS 入口 + Tomcat 80 后端未配 `proxy_redirect`”导致的同主机 `https://host -> 302 http://host` 重定向，仅在“源为默认 HTTPS 443 + 目标为**同一主机**默认 HTTP 80 + 无 `userinfo`”时安全升级回 `https://`，跨域明文跳转依然严格拦截。
- **验证**：[`test/core/net_test.dart`](../test/core/net_test.dart) & [`test/courselens_cli_test.dart`](../test/courselens_cli_test.dart)。

### 5. 会话退役封口，杜绝迟到响应写穿透
- **实现**：切换账号、重新登录或执行 `auth logout` 时，[`SessionStore`](../lib/core/session/session.dart) 会对旧 [`AccountSession`](../lib/core/session/session.dart) 调用 `retire()`，递增 `epoch` 世代号并调用 `CookieJar.retire()`（云端 Durable Object 同理维护 `_vaultEpoch` 世代围栏与会话隔离 `cacheScope`）。已退役会话永久拒收任何在途迟到 HTTP 响应的 `Set-Cookie` 与缓存写入。
- **验证**：[`test/core/net_test.dart`](../test/core/net_test.dart) & [`workers/session_gateway/test/worker.test.mjs`](../workers/session_gateway/test/worker.test.mjs)。

### 6. `lib/core/` 与 `lib/cli/` 纯 Dart 架构纯度守卫
- **实现**：`lib/core/` 保持零平台与 `dart:io` 依赖，`lib/cli/` 与 `tools/courselens_cli.dart` 保持零 `package:flutter/` 依赖，确保单文件原生可执行产物轻量、可审计且可快速离线回归测试。
- **验证**：[`test/courselens_cli_test.dart`](../test/courselens_cli_test.dart) & [`test/cli_store_test.dart`](../test/cli_store_test.dart)。

### 7. 有状态网关与出站 Webhook 的 SSRF 防护、加密落盘与损坏保护
- **SSRF 防护**：[`workers/session_gateway/src/net_policy.js`](../workers/session_gateway/src/net_policy.js) 对教务上游请求与 Webhook 推送统一拦截环回地址（`127.0.0.1`、`localhost`、`::1`）、RFC1918 私网、链路本地/云元数据（`169.254.0.0/16`）、CGNAT（`100.64.0.0/10`）、IPv6 ULA（`fc00::/7`）及 IPv4-mapped IPv6 地址（由共享夹具 [`test/fixtures/ssrf_reserved_ranges.json`](../test/fixtures/ssrf_reserved_ranges.json) 锁定），且出站 Webhook 严禁跟随重定向。
- **静态加密、密文保留与缓存隔离**：网关入口采用 SHA-256 + `crypto.subtle.timingSafeEqual` 常量时间校验 API Key；`CookieJar`、Webhook 签名密钥与 L2 代理缓存在个人 Durable Object SQLite 中以 AES-256-GCM 静态加密存储，原始 `Cookie` / `Set-Cookie` 绝不下发客户端；密文因密钥轮换无法解密时原样保留至 `*:unreadable` 键并在 `/v1/session` 暴露诊断，绝不静默丢弃。
- **验证**：[`workers/session_gateway/test/worker.test.mjs`](../workers/session_gateway/test/worker.test.mjs)、[`workers/session_gateway/test/proxy_cache.test.mjs`](../workers/session_gateway/test/proxy_cache.test.mjs) & [`workers/session_gateway/test/cloud_features.test.mjs`](../workers/session_gateway/test/cloud_features.test.mjs)。
