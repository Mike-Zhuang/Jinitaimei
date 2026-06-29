# 同济业务协议说明

本文档记录 App 已接入业务的协议约定和已验证边界，供后续维护使用。所有示例均为脱敏结构，不得在文档、日志或测试夹具中写入真实密码、Cookie、Token、完整邮箱或学号。

## 1. 一系统通用鉴权

一系统 API 位于 `https://1.tongji.edu.cn`。业务请求复用：

```text
Cookie: <结构化 CookieJar 生成的 header>
X-Token: <sessionid>
```

课表额外需要 AES-CBC-PKCS7 加密后的 `studentCode`。登录、续期和失败恢复统一由：

- `TongjiAuthCoordinator`
- `AuthRecoveryManager`
- `CookieJar`
- `CredentialStore`

负责。业务 API 收到 `401 / 403` 时抛出 `AuthError.expired`，通过 `withAuthRetry` 触发 single-flight 续期并重试一次。业务模块不得擅自清除一系统凭证。

### 1.1 Cookie 双向同步与 SSO 预热

一系统登录态同时存在于两类容器：

- `CookieJar`：结构化保存到 Keychain，供 `URLSession` / `TongjiHTTPClient` 注入业务请求。
- `WKHTTPCookieStore`：隐藏续期 WebView 和交互登录 WebView 使用的浏览器态。

为了避免两者割裂，以下场景必须执行同步：

1. 静默续期、密码回填、回前台会话检查前：把 `CookieJar` 中仍有效的同济域 Cookie 回灌到对应 `WKHTTPCookieStore`。
2. 登录成功、静默续期成功、密码回填成功后：从 `WKHTTPCookieStore` 读取同济域 Cookie，合并回 `CookieJar`。
3. `all.tongji.edu.cn` 预热完成后：同样把预热 WebView 中产生的同济域 Cookie 合并回 `CookieJar`。

预热入口为：

```text
https://all.tongji.edu.cn/new/index.html
```

预热用于补齐同济门户域 Cookie。预热失败不得直接判定一系统登录失效，只记录脱敏诊断并保留当前登录态。

### 1.2 Android 下游可借鉴点与不采纳点

Android 下游项目较少掉登录的主要原因是全局持久化 CookieJar、登录后访问 `all.tongji.edu.cn` 预热 SSO Cookie、以及 Retrofit 请求统一注入 Cookie / Token。iOS 端只吸收这三个架构点。

以下做法不得引入 iOS 主项目：

- BODY 级网络日志。
- Cookie、Token、`sessiondata`、学号密码明文日志。
- 强行把所有 session cookie 改成固定 24 小时有效期。
- 用 `uid` 或其他身份字段兜底充当 `X-Token`。

## 2. 课表学期与日历导出

课表学期列表来自：

```text
GET /api/baseresservice/schoolCalendar/list
GET /api/baseresservice/schoolCalendar/detail?id=...
```

一系统会返回大量历史学期，App 只在 UI 展示与当前学生相关的范围：

- 下界：学生入学学年第一学期。入学年份优先解析个人资料 `grade/currentGrade` 中的 4 位年份，缺失时用学号前两位推断。
- 上界：远端 `nextTermFlag == true` 的学期；若无 next 标记，则使用 `currentTermFlag == true` 的学期。

本地仍可保存远端原始学期缓存，但课表页 Picker 只能使用过滤后的可见学期。若用户之前选中的学期落在范围外，自动回到当前学期。

课表导出使用 App 内部 Sheet 完成：选择课程、是否同时导出本学期考试、提醒、目标日历，然后点击同一页面的“导出”。不得再使用缺少明确继续动作的二级系统日历选择流程。若只有 write-only 日历权限，无法列出全部日历时，导出到系统默认日历。

## 3. 考试安排

考试安排位于 `TongjiKit/Sources/TongjiKit/ExamScore/`，请求顺序：

1. `POST /api/sessionservice/session/currentAuthId`
   请求体：`{"authId":9102}`
2. `POST /api/electionservice/underGraduateExamSwitch/getExamCalendar?examType=1&switchType=null`
3. `POST /api/electionservice/undergraduateExamQuery/getStudentListPage`

只有同时具有日期、开始时间和结束时间的条目才可导出到系统日历。无明确时间的考察、论文、汇报等条目保留在 App 内展示。

同步成功后，考试数据写入 SwiftData 缓存，并复用于：

- `校园 → 考试安排`
- `日程 → 本周考试`
- 系统日历导出

## 4. 课程成绩

课程成绩请求顺序：

1. `POST /api/sessionservice/session/currentAuthId`
   请求体：`{"authId":12174}`
2. `GET /api/scoremanagementservice/studentScoreBk/queryCourseTag?studentId=...`
3. `GET /api/scoremanagementservice/scoreGrades/getMyGrades?studentId=...`

### 4.1 课程类别映射

`getMyGrades` 的 `courseLabName` 可能包含领域名和括号编号，例如：

```text
科学探索与生命关怀[2]
人文经典与审美素养[125]
```

括号编号存在两种来源：

1. 网页底部图例中的展示序号，例如 `[2]`
2. `queryCourseTag` 返回的后端 `id`，例如 `[125]`

因此解析时必须动态拉取 `queryCourseTag`，为每个标签同时建立：

```text
展示序号 -> shortName
后端 id -> shortName
```

然后保留领域名，仅把编号翻译为短名：

| 原始字段 | App 展示 |
|---------|----------|
| `科学探索与生命关怀[2]` | `科学探索与生命关怀 · 精品类（核心）` |
| `人文经典与审美素养[125]` | `人文经典与审美素养 · 大学美育` |
| `人文经典与审美素养` | `人文经典与审美素养` |

不得把 `courseNature` 中的 `SJ` 等内部代码作为用户可见类别。

## 5. 教务通知与附件

通知摘要列表和详情位于一系统 `commonMsgPublish` 接口。详情响应中的：

```text
commonAttachmentList
```

用于展示附件，其中常用字段包括：

```text
id
relationId
fileName
fileLacation
```

注意：学校响应字段名确实是 `fileLacation`，不是标准拼写 `fileLocation`。模型内部可使用正确英文命名，但解码键必须兼容原字段。

附件下载按需执行，不在打开详情页时批量预取。下载入口：

```text
/api/commonservice/obsfile/downloadfile?objectkey=...
```

下载请求复用一系统 Cookie 与 `X-Token`。`objectkey` 由附件路径按一系统现有 AES 规则生成，并按接口要求进行 percent-encoding。下载后的文件只写入临时目录，用于 Quick Look 预览或系统分享。

## 6. 校园卡

校园卡业务位于 `TongjiKit/Sources/TongjiKit/Wallet/`。鉴权链路与一系统登录态隔离，避免校园卡凭证失效误伤课表、通知和成绩。

客户端续期策略：

1. 访问校园卡登录中转页
2. 捕获 H5 跳转、URL、Cookie、storage、请求头和 Native Bridge 中的校园卡凭证
3. 必要时使用 `all4u.tongji.edu.cn` 入口兜底
4. 余额接口返回鉴权失败时，清理校园卡专属旧凭证并重新续期

日志只能输出：

- 是否拿到 token / cookie
- 长度
- 来源
- Cookie 名称
- HTTP 状态

日志不得输出凭证值本身。

消费记录同步后，UI 展示：

- 余额与更新时间
- 最近 7 天每日消费曲线
- 精简后的最近消费

交易时间解析要兼容秒时间戳、毫秒时间戳和常见日期字符串；解析失败的记录不得伪造为公元 1 年日期。

## 7. STAR 卓越星

STAR 活动列表优先使用公开接口。个人星值和需要身份的接口使用独立 Bearer Token，由 `StarAuthCoordinator` 维护。

STAR token 与一系统登录态解耦：

- STAR 续期失败不得把 `CampusModel.authState` 改为 `requiresInteractiveLogin`
- 一系统恢复成功后，可独立尝试 STAR 续期
- 遇到验证码或 MFA 时不绕过，降级到用户交互

## 8. 图书馆空间系统

图书馆座位与研习室数据来自：

```text
https://space.tongji.edu.cn
```

首版只读展示，不提交预约、取消预约或签到。

### 8.1 鉴权

图书馆系统使用独立 IAM 应用：

```text
client_id / entityId: SYS20230204
redirect_uri: https://space.tongji.edu.cn/api/Oauth3/login
```

登录链路：

1. IAM OAuth 回跳到 `/api/Oauth3/login?code=...`
2. 图书馆系统重定向到 `/h5/#/cas?cas=...`
3. App 调用 `POST /api/cas/user`，请求体：

```json
{"cas":"<redacted>"}
```

4. 响应中的 `member.token` 是后续业务请求使用的 JWT，写入 Keychain `library_space_bearer_token`

该 token 与一系统、STAR、校园卡凭证互相隔离。业务请求遇到 `401 / 403` 时抛 `AuthError.expired`，通过 `withLibrarySpaceAuthRetry` 触发图书馆专属 single-flight 续期并重试一次。

日志只允许输出 token 是否存在、长度和来源，不得输出 `cas`、JWT、Cookie、手机号、邮箱或完整学号。

### 8.2 请求约定

图书馆系统的 JWT 不放在 HTTP `Authorization` Header，而是放在 JSON 请求体里：

```json
{
  "authorization": "bearer<token>"
}
```

注意抓包中 `bearer` 与 token 之间没有空格。新增接口时必须保持这个格式，除非后续抓包证明学校改了协议。

### 8.3 座位概览与座位图

座位概览：

```text
POST /reserve/index/quickSelect
```

座位模式请求体核心字段：

```json
{
  "id": "1",
  "date": "yyyy-MM-dd",
  "categoryIds": ["1"],
  "members": 0
}
```

返回中的 `premises` 是图书馆概览，`storey` 是楼层，`area` 是具体座位区。当前已验证重点图书馆：

- 嘉定校区图书馆
- 四平路校区图书馆
- 德文图书馆
- 东区图书馆

`total_num` 和 `free_num` 是座位总数与空闲数。当前抓包未发现真实门禁入馆人数接口，因此 UI 必须称为“座位占用口径”，不得写成“入馆人数”。

区域座位图按需请求：

```text
POST /api/Seat/date
POST /api/seat/label
POST /api/seat/map
POST /api/Seat/seat
```

`/api/Seat/seat` 返回座位坐标、尺寸、状态、标签等字段。UI 使用坐标绘制平面图，不展示几千条座位列表。

### 8.4 本地标签

学校标签来自：

```text
POST /api/seat/label
```

本地额外维护 `单人单座` 标签，首版规则：

- 四平路二楼：`113-128`、`191-214`
- 四平路 6 / 8 / 10 楼南北：`001-007`、`032-040`、`073-081`
- 东区二楼：`57-69`
- 东区三楼：`65-79`

匹配依据为“图书馆名 + 楼层 / 区域名 + 座位号”。不确定区域不得误标。

### 8.5 研习室

研习室概览同样使用：

```text
POST /reserve/index/quickSelect
```

研习室模式请求体核心字段：

```json
{
  "id": "2",
  "date": "yyyy-MM-dd",
  "members": 0
}
```

单个研习室详情与空闲段：

```text
POST /api/Seminar/detail
POST /api/Seminar/v1seminar
```

`/api/Seminar/v1seminar` 返回多天可约信息。App 首版只展示今天、明天、后天三天，并把 `beginNum` / `endNum` 按分钟映射到 08:00-22:00 时间轴。
