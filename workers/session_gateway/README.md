# CourseLens Session Gateway (`courselens-session`)

自托管在用户个人 Cloudflare 账号（Free 计划即可）上的有状态教务会话托管网关，配合 [CourseLens CLI](https://github.com/VanceHud/courselens-cli) 使用。

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/VanceHud/courselens-cli/tree/main/workers/session_gateway)

## 核心特性

- **凭据不出个人边界**：学号、密码与 `COURSELENS_API_KEY` 以 Cloudflare Worker **Encrypted Secrets** 存储；会话 `CookieJar` 在个人 Durable Object SQLite 中以 **AES-256-GCM**（HKDF 派生密钥）静态加密，永不下发客户端。
- **默认零后台唤醒（懒保活）**：`KEEPALIVE_INTERVAL_SEC=0` 时平时完全休眠不消耗配额；仅当 CLI 发起请求且上游返回过期时，才在云端单航班自动重登并透明重放。
- **动态扫码 Cookie 注入**：若学校强制图形验证码或企业微信/钉钉扫码登录，可在填写 `PORTAL_PASSWORD` 时填 `COOKIE_ONLY`，部署后使用 `courselens worker push-cookies` 注入浏览器已登录 Cookie。
- **可选成绩/考试变动巡检与推送**：内置默认关闭的 `monitor:grades` / `monitor:exams` 与 Bark / 飞书 / 钉钉 / 企微 / Telegram / 通用 HMAC Webhook 通知。

## 部署后绑定 CourseLens CLI

部署完成后，复制你的 Worker 地址（形如 `https://courselens-session.<你的子域>.workers.dev`），在本机终端绑定：

```bash
printf '%s\n' '<你设置的 COURSELENS_API_KEY>' | courselens auth worker \
  --url https://courselens-session.<你的子域>.workers.dev \
  --name my-school \
  --api-key-stdin

courselens today
```

## 进阶可选环境变量

如果学校使用独立域名的统一身份认证（CAS SSO）或多节点教务域名，可在部署后前往 **Cloudflare Dashboard → Workers & Pages → `courselens-session` → Settings → Variables and Secrets** 添加：

- `PORTAL_CAS_URL`：学校 CAS 登录地址（如 `https://sso.example.edu.cn/cas/login`）
- `ALLOWED_HOSTS`：额外允许转发的教务主机白名单（逗号分隔，`PORTAL_URL` 与 `PORTAL_CAS_URL` 所在域名已自动加入白名单）
- `SCHOOL_NAME`：自定义显示的学校名称

## 本地开发与自测

```bash
npm install
npm test
npx wrangler deploy
```
