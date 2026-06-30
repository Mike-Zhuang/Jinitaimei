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

## 7. 智能控水

智能控水业务位于 `TongjiKit/Sources/TongjiKit/WaterControl/`。首版只读展示控水器状态，不提交开关水、预约、锁定、解锁或其他控制请求。

基础域名：

```text
https://ks.tongji.edu.cn
```

### 7.1 鉴权与参数来源

智能控水依赖校园卡系统的一卡通登录态。客户端流程：

1. 优先复用本地校园卡 `synjones-auth`
2. 若缺失，则触发 `YikatongAuthCoordinator` 续期
3. 通过 `pay-yikatong.tongji.edu.cn` 水控跳转入口进入 `ks.tongji.edu.cn`
4. 从 KS 页面提取：
   - `sessionStorage.ano` / `localStorage.ano`：一卡通账号
   - 前端 JS 中的 AES key
   - 前端 JS 中的接口 password
5. 参数写入 Keychain：
   - `water_control_account`
   - `water_control_aes_key`
   - `water_control_password`
   - `water_control_cookies`

若 JS 中无法提取 AES key 或 password，可使用当前 Android 下游验证过的 fallback 值；日志必须标注来源为 `js` 或 `fallback`，不得输出值本身。

日志只允许输出：

- 参数是否存在
- 长度
- 来源
- Cookie 名称
- HTTP 状态与业务码

日志不得输出 `synjones-auth`、Cookie、AES key、password、完整一卡通号或完整 URL 中的敏感 query 参数。

### 7.2 加密

水控接口的 `info` 参数使用与 Android 下游一致的：

```text
AES/ECB/PKCS7
```

加密前 JSON 字段保持原协议命名。

获取 token：

```json
{
  "userid": "<ano>",
  "userpassword": "<password>",
  "time": "yyyyMMddHHmmss"
}
```

获取某分组控水器：

```json
{
  "ano": "<ano>",
  "groupid": "<groupId>"
}
```

### 7.3 接口

分组列表：

```text
GET /waterapi/api/UseHzWatch
```

获取水控 token：

```text
GET /waterapi/api/GetToken?info=...
```

获取某分组控水器：

```text
GET /waterapi/api/AccUseHzWatch?info=...&token=...
```

`GetToken` 返回的 token 只保存在内存中。接口返回 token 失效、未登录、业务码失败时，先清内存 token 并重新 `GetToken`；仍失败再触发水控鉴权续期并重试一次。

如果水控接口返回类似 `RetNo=-38`、`RetDsp=爽约，禁止预约`，按学校水控系统的预约资格限制处理：UI 提示这是业务限制，不当作登录失效，不反复触发重新登录。

### 7.4 状态映射

控水器状态码按 Android 下游已验证规则展示：

| code | 展示 |
|------|------|
| `0` | 离线 |
| `1` | 空闲 |
| `2` | 加锁 |
| `3` | 报警 |
| `4` | 使用中 |

首页置顶卡和详情页 summary 统一汇总为：

- 空闲：`1`
- 使用中：`4`
- 异常：`0 / 2 / 3` 和未知状态

### 7.5 UI 与缓存

分组列表先从本地 SwiftData 快照展示，再按需刷新远端。展开某个分组时才请求该组控水器，不一次性请求所有分组设备。

详情页筛选只影响本地展示，不改变学校状态，也不提交任何写操作。空状态和错误态应提供“重新获取控水登录态 / 重试”，不能只展示“暂无数据”。

## 8. 宿舍洗衣机

洗衣机业务位于 `TongjiKit/Sources/TongjiKit/Laundry/`。首版只读展示洗衣房和机器状态，不提交预约、排队、支付、扫码、启动或停止洗衣请求。

基础域名：

```text
https://wx2.cooleasy.net
```

### 8.1 鉴权与网页 token

CoolEasy 洗衣机网页当前不依赖同济 IAM，但依赖 CoolEasy 自己的微信网页会话。抓包验证表明：裸请求入口页会返回 HTTP 500；只要带有效 `loginStatusId` Cookie，入口页即可返回 200 并生成新的 anti-forgery token。业务 POST 需要网页中的 anti-forgery token 与同站 Cookie：

1. 请求洗衣房入口页：

   ```text
   GET /Home/lineUpNearbyEquipment?typeId=1&r=yyyyMMddHHmmssSSS
   ```

2. 从 HTML 中抽取隐藏 input：

   ```html
   name="__RequestVerificationToken"
   ```

3. 带同站 Cookie 提交洗衣房列表 POST。
4. 展开某个洗衣房时，请求详情页：

   ```text
   GET /Home/NearbyEquipment?typeId=1&address=<Address>
   ```

5. 从详情页重新抽取 token，再提交该房间机器列表 POST。

日志只允许输出接口路径、HTTP 状态、业务 `success/msg`、房间数量、机器数量、token 长度；不得输出 Cookie、anti-forgery token、完整请求体或用户敏感信息。

App 单独维护 `wx2.cooleasy.net` 的 Cookie header，响应中的 `Set-Cookie` 会回写到 Keychain `laundry_cookies`。日志只输出 Cookie 名称，例如 `loginStatusId` / `ASP.NET_SessionId` / `__RequestVerificationToken`，不输出值。若入口页返回 500 且本地没有 `loginStatusId`，按“CoolEasy 会话未初始化”处理，而不是误报普通网络错误。

### 8.2 接口

洗衣房列表：

```text
POST /Home/ApiWashingRoomList
Content-Type: application/x-www-form-urlencoded; charset=UTF-8

__RequestVerificationToken=<page token>
TypeId=1
LonX=121.498886
LatY=31.28323
```

首版默认使用四平路附近坐标，不请求系统定位权限。

某洗衣房机器列表：

```text
POST /Home/ApiMachineListByAddress
Content-Type: application/x-www-form-urlencoded; charset=UTF-8

__RequestVerificationToken=<page token>
TypeId=1
Address=<服务端返回的原始 Address>
status=all
```

`RoomId` 在当前样例中为 `null`，因此 App 使用服务端原始 `Address` 作为本地稳定 id；展示时才 trim 首尾空白，避免把相似宿舍误合并。

### 8.3 状态映射与 UI

机器状态按以下优先级展示：

- `IsOnline == false`：离线
- `RunningStatusDescription` 包含“空闲”或 `RunningStatus == 1`：空闲
- `RunningStatusDescription` 包含“运行”或 `RunningStatus == 2`：运行中
- 其他：未知

首页卡片和详情页优先展示用户置顶的常用洗衣房。机器列表按洗衣房懒加载；未展开的洗衣房不批量请求机器状态，避免请求过多。

## 9. STAR 卓越星

STAR 活动列表优先使用公开接口。个人星值和需要身份的接口使用独立 Bearer Token，由 `StarAuthCoordinator` 维护。

STAR token 与一系统登录态解耦：

- STAR 续期失败不得把 `CampusModel.authState` 改为 `requiresInteractiveLogin`
- 一系统恢复成功后，可独立尝试 STAR 续期
- 遇到验证码或 MFA 时不绕过，降级到用户交互

## 10. 图书馆空间系统

图书馆座位与研习室数据来自：

```text
https://space.tongji.edu.cn
```

首版只读展示，不提交预约、取消预约或签到。

### 10.1 鉴权

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

### 10.2 请求约定

图书馆系统的 JWT 不放在 HTTP `Authorization` Header，而是放在 JSON 请求体里：

```json
{
  "authorization": "bearer<token>"
}
```

注意抓包中 `bearer` 与 token 之间没有空格。新增接口时必须保持这个格式，除非后续抓包证明学校改了协议。

### 10.3 座位概览与座位图

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

### 10.4 本地标签

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

### 10.5 研习室

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
