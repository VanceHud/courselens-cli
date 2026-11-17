# 高校适配与开发指南

CourseLens 支持「直接填写地址自动识别」与「内置学校预设模板」两种方式接入不同高校的教务系统。本文档说明现有教务系统的适配范围，以及如何安全地为你的学校新增适配、作息预设与回归测试夹具。

## 1. 当前支持的教务系统家族

[`SystemDetector`](../lib/core/parse/system_detector.dart) 与 [`AcademicSystem`](../lib/core/model/academic_system.dart) 当前识别并支持以下 4 套教务系统家族：

| 代号 (`systemId`) | 教务类型 | 特征路径 / 登录形态 | 已支持能力 |
| --- | --- | --- | --- |
| `ZF` | 新正方教务（`jwglxt`） | `/jwglxt/xtgl/login_slogin.html`、`csrftoken` + RSA 公钥（`login_getpublickey`） | 直连登录 / CAS 登录 / 浏览器接管、课表（含 `sjkList`）、成绩与分项明细、考试、学业进度（`N105515`）、已选名单（`N255010`）、空教室（`N2155`）、自主选课（`N253512`） |
| `ZF_OLD` | 旧正方教务 | `default2.aspx`、ViewState / `txtKeyModulus` / `CheckCode` | CAS / 浏览器接管、课表、成绩、考试只读读取 |
| `QZ` | 新强智教务（`jsxsd`） | `var scode` + `var sxh` + `LoginToXk` | CAS / 浏览器接管、课表、成绩、考试只读读取 |
| `QZ_OLD` | 旧强智教务 | `Logon.do?method=logon&flag=sess`、`EncodeInp` | CAS / 浏览器接管、课表、成绩、考试只读读取 |

> [!NOTE]
> **自主选课**（写接口）当前仅新正方（`ZF`）已完成完整适配（参见 [`AcademicClient._selectionFor`](../lib/core/academic_client.dart)），且必须经干跑预检 + 显式确认才提交；其余三套系统在课程查询、课表、成绩与考试方面不受影响。本项目不提供无人值守抢课功能。

## 2. 无需改代码的通用接入方式

大多数高校无需修改源码即可直接试用：

1. 直连登录：`courselens auth login --url <教务系统根地址> --system ZF`（可直接填域名根路径，原生正方探测到跳转后会自动升级为 `/jwglxt`）；
2. 若学校走统一身份认证（CAS），`auth login` 时附带 `--cas-url <CAS 登录地址>`；
3. 若学校必须**扫码、短信验证码、滑块或企业微信/钉钉跳转登录**，先在浏览器里完成一次登录，再用 `courselens auth import-cookie`（或 `.har` 导入）把会话交给 CLI / 网关。

## 3. 为仓库贡献高校预设（模板与作息）

如果你希望为你所在的高校添加一键预设（参考青岛科技大学 QUST 预设实现），可重点检查以下几处：

1. **学校预设模板（`AccountProfile`）**：
   - 定义位置：[`lib/data/storage/preferences_store.dart`](../lib/data/storage/preferences_store.dart)（参考 `AccountProfile.qustTemplate` 与 `AccountProfile.qustSecondaryTemplate`）。
   - 核心字段：`schoolId`、`schoolName`、`academicBaseUrl`、`casBaseUrl`（直连留空）、`allowedHosts`（含主备域名与 CAS 域，严格遵守 `HostPolicy` 无通配符原则）、`systemId`、`requireSecure`。
2. **UI 快捷入口Chip**：
   - 定义位置：[`lib/ui/settings/settings_screen.dart`](../lib/ui/settings/settings_screen.dart)。
3. **作息时间预设（可选）**：
   - 定义位置：[`lib/core/schedule/period_schedule_builder.dart`](../lib/core/schedule/period_schedule_builder.dart)（通过 `PeriodScheduleSpec` 与 `PeriodBreakOverride` 描述每节课时长、大小课间、午休与晚间间隔）。
   - 对于支持官方作息查询的新正方高校，`StudyReader.campusBellSchedule` 也可在登录后自动拉取校区作息表。
4. **校区 / 教室类型或专有模块（可选）**：
   - 参考 [`lib/core/model/qust_modules.dart`](../lib/core/model/qust_modules.dart) 中的 `CampusOption`、`RoomTypeOption` 与解析扩展。

## 4. 录制与提交脱敏测试夹具（极重要）

CourseLens 的所有解析器与协议回归测试均建立在 `test/fixtures/academic/` 的离线 HTML/JSON 夹具之上（例如 [`test/core/qust_protocol_and_modules_test.dart`](../test/core/qust_protocol_and_modules_test.dart) 与 [`test/core/parse_fixtures_test.dart`](../test/core/parse_fixtures_test.dart)）。

**提交任何夹具文件前，必须完成以下脱敏检查：**

- [ ] 替换学生真实姓名（统一改为如 `测试同学` / `Test Student`）；
- [ ] 替换真实学号（统一改为虚构占位学号，如 `20250000`）；
- [ ] 替换真实 `Set-Cookie` / `JSESSIONID` / `CASTGC` / `csrftoken` / `execution` 等会话与认证令牌；
- [ ] 删除或脱敏身份证号、手机号、邮箱、家庭住址、证件照链接中的敏感参数等所有 PII 字段；
- [ ] 确保未写入真实密码或明文凭据。

**本地验证命令：**

```bash
dart analyze --fatal-infos
flutter test
```
