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

## 最快的方式：把下面这段提示词发给你的 AI Agent

如果你在用 Claude Code、Codex、Cline、Muse 这类能操作你电脑的 AI 助手，不用自己敲命令——把下面整段复制发给它，它会自己完成安装、接入你的教务账号，并验证到能查出真实课表为止：

```text
请帮我安装并接入 CourseLens CLI（一个把高校教务系统接入 AI 助手的开源工具），全程按下面步骤做，每步做完向我汇报结果，遇到需要我决定的地方停下来问我：

1. 克隆仓库到 ~/.local/share/courselens-cli：
   git clone https://github.com/VanceHud/courselens-cli.git ~/.local/share/courselens-cli
   （如果克隆失败，先告诉我失败原因，不要换来源。）
2. 检查 Dart SDK：运行 dart --version；没有就从 dart.dev 官方渠道安装稳定版 Dart SDK 到 ~/.local/share/dart-sdk 并加入 PATH，然后再次验证。
3. 编译并安装 CLI：
   cd ~/.local/share/courselens-cli && dart pub get && dart compile exe tools/courselens_cli.dart -o build/courselens
   把 build/courselens 软链到 ~/.local/bin/courselens（目录不存在就建），然后运行 courselens --version 和 courselens --demo today 验证可用。
4. 安装配套的 Agent Skill：把仓库里的 .agents/skills/courselens-cli 整个目录软链（优先）或复制到你自己的技能目录（Claude Code 是 ~/.claude/skills，Codex 是 ~/.codex/skills 或 ~/.agents/skills；你判断不出自己是哪种就问我）。然后完整读一遍其中的 SKILL.md，并读仓库的 README.md 和 docs/cli-and-agent-skill.md，之后所有教务操作都按 Skill 的规范执行。
5. 引导我接入教务账号：先问我学校、教务系统地址（URL）和系统类型（ZF/ZF_OLD/QZ/QZ_OLD，不确定就用 auto 探测），然后让我在三种接入方式里选：
   a) 网关模式（推荐）：在仓库 workers/session_gateway 里把 wrangler.toml.example 复制为 wrangler.toml，用 wrangler 部署到我自己的 Cloudflare 账号；COURSELENS_API_KEY 和 PORTAL_PASSWORD 两个 Secret 由我本人执行 wrangler secret put 输入，你不要经手；部署完成后用 courselens auth worker 把 CLI 绑定到网关。
   b) Cookie 导入：我在浏览器登录教务后导出 .har 或 Cookie，你用 courselens auth import-cookie 导入。
   c) 直连模式：你把 courselens auth login 的命令给我，我在自己的终端里交互式输入学号和密码（隐藏输入），你不要让我在聊天里发密码。
6. 验证接入：运行 courselens whoami（或 auth status）确认会话 ACTIVE，再运行 courselens today，把我的真实今日课表发给我看。

安全红线（必须遵守）：
- 绝不在聊天里向我索要教务密码，也不要让我把密码、完整 Cookie 或 API key 发在聊天里；这些只能走上面三种正规通道。
- 任何时候不要在输出、日志或文件里复述我的密码、完整 Cookie 或 API key。
- 选课/退课（select/drop）必须先不带 --confirm 干跑预检，把课程名、老师、时间和冲突结果发我确认，我明确同意后才加 --confirm 执行；返回 RESULT_UNKNOWN 时严禁用原参数盲目重发，先用 courselens courses 只读核查。
- 不要修改 Cloudflare 的其他配置，不要动仓库的 git 历史；wrangler 部署只部署这个 Worker 本身。

最后告诉我：以后我想查课表、成绩、考试、空教室，直接跟你说就行；工具升级时运行 courselens update 即可（可先 courselens update --check 只检查不更新）。
```

手动安装则看下面的快速开始。

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
