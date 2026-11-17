# CourseLens CLI

**把高校教务系统接入你自己的 AI 助手。**

课表、成绩、考试、空教室——不再手工登录教务网站点来点去，而是让 Claude Code、Codex 等 AI agent 通过一个原生 CLI 直接查询你自己的教务数据。全开源、自托管：教务密码只存在你自己部署的服务里，不经过任何第三方托管。

## 它由三部分组成

| 组件 | 说明 |
| --- | --- |
| **协议核心 + CLI**（`lib/`、`tools/`） | 100% 纯 Dart 实现的教务协议层与原生命令行 `courselens`，无 Flutter 依赖，编译为单个可执行文件 |
| **Agent Skill**（`.agents/skills/courselens-cli/`） | 给 AI agent 读的操作手册：命令图、会话管理与安全红线（写操作二次确认、密码绝不经聊天窗口等），主流 agent 工具可直接加载 |
| **有状态会话网关**（`workers/session_gateway/`） | 部署在你自己 Cloudflare 账号上的 Worker：登录会话保存在 Durable Objects 中（Cookie 加密落盘），CLI/App 只用 API key 访问；会话失效自动重登，懒保活模式下无请求时零唤醒、零上游流量 |

## 支持的教务系统

- 新正方 `ZF`（jwglxt，RSA 直连 / CAS）
- 旧正方 `ZF_OLD`
- 新强智 `QZ`（jsxsd）
- 旧强智 `QZ_OLD`

大多数学校填入教务地址即可自动识别接入；为学校新增预设模板与作息的方法见 [高校适配指南](docs/school-adaptation.md)。

## 快速开始

### 1. 编译 CLI

需要 Dart SDK ≥ 3.11：

```bash
dart pub get
dart compile exe tools/courselens_cli.dart -o build/courselens
./build/courselens --demo today   # 内置演示数据，先看看输出长什么样
```

### 2a. 直连模式（最简单）

在本机终端交互式登录（密码隐藏输入，不经过任何聊天窗口与日志）：

```bash
courselens auth login --url https://jwglxt.example.edu.cn/jwglxt --system ZF
courselens today
```

学校走 CAS / 扫码 / 短信验证码登录时，用浏览器完成一次登录后导入会话（`.har` 或 Cookie），见 Skill 文档中的 `auth import-cookie` 流程。

### 2b. 网关模式（推荐，适合配合 AI 助手长期使用）

把会话托管到你自己的 Cloudflare Worker，之后 CLI 与 AI agent 只持有 API key，本地零 Cookie、零密码：

```bash
cd workers/session_gateway
cp wrangler.toml.example wrangler.toml   # 改成你的学校与账号
npx wrangler secret put COURSELENS_API_KEY
npx wrangler secret put PORTAL_PASSWORD
npx wrangler deploy

courselens auth worker --url https://<你的 Worker 地址> --api-key-stdin
courselens whoami
courselens today
```

网关还内置成绩/考试变化监控与 Webhook 通知（默认关闭，按需开启）：

```bash
courselens worker monitor status
courselens worker webhook set --url <你的 Bark/飞书/Telegram 等地址>
```

架构与安全设计见 [docs/stateful-worker-api-key.md](docs/stateful-worker-api-key.md) 与 [docs/security.md](docs/security.md)。

## 常用命令

```text
courselens today                  今日/明日课程 + 近期考试倒计时
courselens schedule               周课表，可导出 .ics 进日历
courselens grades                 成绩、加权均分、必修绩点
courselens exams                  考试安排与考场座位
courselens progress               培养方案完成进度
courselens rooms                  空教室查询
courselens courses                已选 / 可选课程
courselens select / drop          选课 / 退课（强制二次确认：先干跑预检，确认后才提交）
```

## 设计取向

- **只查自己的数据**：用你本人的账号，查你本人的课表与成绩。
- **写操作有人把关**：选课、退课必须先干跑预检、经本人确认才真正提交；结果未知时绝不盲目重发。
- **不提供无人值守抢课**：这是有意为之的边界。
- **不做托管服务**：网关一人一份、部署在自己账号里，密码不出自己的服务器。

## 文档

- [架构说明](docs/architecture.md)
- [CLI 与 Agent Skill](docs/cli-and-agent-skill.md)
- [高校适配与开发指南](docs/school-adaptation.md)
- [安全模型](docs/security.md)
- [有状态会话网关（API key 方案）](docs/stateful-worker-api-key.md)

## 免责声明

本项目与正方、强智等教务系统厂商无关，仅供使用本人账号查询本人信息时参考。请遵守你所在学校关于教务系统使用的规定；因自动化访问产生的账号风险由使用者自行承担。

## License

[MIT](LICENSE)
