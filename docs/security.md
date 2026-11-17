# 安全模型与 7 条硬红线

CourseLens 的设计目标之一，是在不引入第三方中心化后台存储用户账号的前提下，保证五端客户端在身份凭据、网络边界与教务写操作上的可验证安全性。

下面列出本项目强制执行的 **7 条安全与正确性硬红线**。（注：本文档源自 CourseLens 全平台版本，个别实现路径指向 App 仓库；CLI 侧对应实现见 `lib/cli/` 与 `lib/data/http/`。）

## 红线总览

### 1. 安全存储不可用时快速失败，绝不静默降级明文
- **实现**：[`PlatformSecureStore`](../lib/data/storage/secure_store_adapter.dart) 封装系统级安全存储（iOS/macOS Keychain、Android EncryptedSharedPreferences/Keystore、Windows DPAPI）。当底层抛出 `PlatformException` 或存储损坏时，统一转为 `SecureStoreException`，由 [`AcademicClient`](../lib/core/academic_client.dart) 映射为 `AcademicStatus.STORAGE_UNAVAILABLE` 抛出，绝不回退写入 `SharedPreferences` 明文。
- **Web 端策略**：`createPlatformSecureStore()` 在 Web 下显式返回 [`InMemorySecureStore`](../lib/core/port/storage.dart)，凭据与 Cookie 仅驻留当前标签页内存，绝不写入 `localStorage` / `sessionStorage`。
- **验证**：`SelfTestRunner` 第 21 步 & `test/core/net_test.dart`。

### 2. 选课 / 退课写操作未获显式确认前零网络发包
- **实现**：[`ZhengfangSelection`](../lib/core/selection/zhengfang_selection.dart) 的 `select(...)` 与 `drop(...)` 要求显式传入 `confirmed: true`。只要 `confirmed != true`，方法在任何网络调用前即直接返回 `AcademicStatus.VALIDATION_FAILED`。
- **CLI 护栏**：CLI 的 `select` / `drop` 命令默认只做干跑预检并输出待提交内容，必须显式加 `--confirm` 才真正发包；Agent Skill 同样规定写操作必须先经用户确认。
- **验证**：`SelfTestRunner` 第 22 步 & `test/core/login_study_selection_test.dart`。

### 3. 超时 `RESULT_UNKNOWN` 严禁自动重发写包
- **实现**：当 `POST` 请求已发出但遭遇超时或连接中断时，[`IoHttpEngine`](../lib/data/http/io_http_engine.dart) 与 [`RelayHttpEngine`](../lib/data/http/relay_http_engine.dart) 将异常标记为 `AcademicStatus.RESULT_UNKNOWN`。
- **核查行为**：写操作返回 `RESULT_UNKNOWN` 后，唯一允许的后续动作是只读查询已选名单核实结果，绝不重发写请求；核实前不得假设成功或失败。

### 4. 逐跳主机白名单与浏览器导航护栏
- **HostPolicy 五条纪律（[`lib/core/net/host_policy.dart`](../lib/core/net/host_policy.dart)）**：
  1. 仅允许 `http` / `https` 协议（拦截 `javascript:`、`file:`、`data:` 等）；
  2. 拒绝包含 `userinfo` 的钓鱼 URL（如 `https://jw.example.edu.cn@evil.com/`）；
  3. 开启 `requireSecure` 时严禁任何明文 `http` 降级；
  4. 端口必须精确匹配；
  5. 主机名必须完全相等，不做隐式通配。
- **逐跳手动重定向**：`IoHttpEngine`、[`CourseLensRelayServer`](../tools/relay_server.dart) 与 [`relay/cloudflare_worker.js`](../relay/cloudflare_worker.js) 均禁用自动跟随重定向，在每一跳发包前再次执行 `HostPolicy.isAllowed` 校验；发现跳出白名单的 3xx 立即中止并标记 `X-CourseLens-Blocked-Redirect`。
- **反代同主机兼容**：针对高校常见的“Nginx TLS 入口 + Tomcat 80 后端未配 `proxy_redirect`”导致的同主机 `https://host -> 302 http://host` 重定向，四端引擎与 `WebSessionNavigationGuard` 均仅在“源为默认 HTTPS 443 + 目标为**同一主机**默认 HTTP 80 + 无 `userinfo`”时自动升级回 `https://`，跨域明文跳转依然严格拦截。
- **内嵌浏览器机构域识别（[`WebSessionNavigationGuard`](../lib/data/webview/web_session_bridge_io.dart)）**：对高校 SSO 常见的多子域跳转（如 `sso.qust.edu.cn` 与 `jwglxt.qust.edu.cn`），内嵌浏览器内置公共后缀表（正确识别 `.edu.cn` 等双标签公共后缀），仅放行同可注册机构域（如 `*.qust.edu.cn`），严防将 `*.edu.cn` 误放行给其他高校或钓鱼域。
- **验证**：`SelfTestRunner` 第 6–7 步、[`test/data/relay_server_test.dart`](../test/data/relay_server_test.dart)。

### 5. 会话退役封口，杜绝迟到响应写穿透
- **实现**：切换账号、重新登录或退出时，[`SessionStore`](../lib/core/session/session.dart) 会对旧 [`AccountSession`](../lib/core/session/session.dart) 调用 `retire()`，递增 `epoch` 世代号并调用 `CookieJar.retire()`。已退役的 `CookieJar` 永久拒收任何在途迟到 HTTP 响应的 `Set-Cookie` 写入，且 `requireActive()` 立即抛出 `SessionCancelledException`。
- **验证**：`SelfTestRunner` 第 8 步 & [`test/core/net_test.dart`](../test/core/net_test.dart)。

### 6. `lib/core/` 纯 Dart 架构纯度守卫
- **实现**：[`test/widget_test.dart`](../test/widget_test.dart) 自动扫描 `lib/core/` 下全部 `.dart` 文件，禁止出现 `package:flutter/`、`dart:io`、`dart:html` 与 `dart:js_interop`。
- **意义**：保证核心加密、解析、协议与状态机可以在 VM、Wasm 与独立 CLI 中复用并快速单测。

### 7. 传输安全默认与平台权限诚实边界
- **Apple ATS 策略**：[`ios/Runner/Info.plist`](../ios/Runner/Info.plist) 与 [`macos/Runner/Info.plist`](../macos/Runner/Info.plist) 为兼容部分高校仅提供校内明文 HTTP 的教务内网而配置了 `NSAllowsArbitraryLoads`，但严格**不设置** `NSAllowsArbitraryLoadsInWebContent`，使 WebView 继续受制于系统安全约束与 `WebSessionNavigationGuard` 校验；Android 在 [`AndroidManifest.xml`](../android/app/src/main/AndroidManifest.xml) 配置 `usesCleartextTraffic="true"` 服务于同类校内 HTTP 教务，同时所有学校预设（如 QUST）默认开启 `requireSecure: true`。
- **Web 中继 SSRF 防护**：[`tools/relay_server.dart`](../tools/relay_server.dart) 与 [`relay/cloudflare_worker.js`](../relay/cloudflare_worker.js) 严禁访问环回地址（`127.0.0.1`、`localhost`、`::1`）、RFC1918 私网、链路本地（`169.254.0.0/16`）、CGNAT（`100.64.0.0/10`）、IPv6 ULA（`fc00::/7`）及 IPv4-mapped IPv6 地址（本地 Dart 中继还会在 DNS 解析后二次检查解析结果，防范 DNS Rebinding）。

## Web 无状态转发网关的隐私边界

- **零持久化**：无论本地 `tools/relay_server.dart` 还是 `relay/cloudflare_worker.js`，均不绑定 KV / D1 / R2 / 数据库，也不向磁盘或日志输出请求体、`Cookie` 或 `Set-Cookie`。
- **透明可控**：推荐用户使用本机 `dart run tools/relay_server.dart` 或将 `relay/cloudflare_worker.js` 部署到**自己的** Cloudflare 账号下（详见 [`docs/web-relay-and-deployment.md`](web-relay-and-deployment.md)），确保教务凭据只流经自己完全掌控的基础设施。
