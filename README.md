# Jinitaimei · 同济大学 iPhone App

一个面向同济大学学生的开源 iOS App，仅支持 iPhone（不支持 iPad / Mac / watchOS）。当前为 v0.1.0 早期版本，按"逐步开发"的方式从最小可用功能开始迭代。

> Jinitaimei 在架构与 UI 设计上重度参考了复旦大学的优秀开源项目 [DanXi](https://github.com/DanXi-Dev/DanXi)（Flutter）与 [DanXi-swift](https://github.com/DanXi-Dev/DanXi-swift)（SwiftUI 重写版）；同济业务数据抓取逻辑参考了作者所在团队的 .NET MAUI 原型 [wish_drom](https://github.com/wyyyz1937365497/wish_drom)。在此致谢上游项目。

## 当前已实现功能

| Tab | 功能 | 数据来源 | 状态 |
|-----|------|---------|------|
| 日程 | 周课表查看（按周切换、点击节次看详情、导出到系统日历） | 一系统 `1.tongji.edu.cn` `findStudentTimetab` + `currentTermCalendar` | v0.1 可用 |
| 校园 | 卓越星活动列表、筛选排序、个人星值摘要 | STAR 平台 `star.tongji.edu.cn` | v0.1 可用 |
| 校园 | 教学管理信息系统通知公告（列表、详情、置顶服务卡片） | 一系统 `1.tongji.edu.cn` `commonMsgPublish` | v0.1 可用 |
| 校园 | 校园卡余额、最近余额变化趋势、低余额提醒 | 同济校园卡 `pay-yikatong.tongji.edu.cn` | v0.1 可用 |
| 设置 | 校园账户登录、账户信息、退出登录、自动登录开关、邮件推送与低余额阈值 | 同济统一身份认证 + 一系统 session 用户信息 | v0.1 可用 |

登录方式：**仅同济统一身份认证（iam/ids.tongji.edu.cn）**。用户从 `设置 → 校园账户` 进入登录页，在 WebView 内完成一次 SSO 后，App 会在同一个 WebView 内于遮罩下后台抓取凭证（Cookie + sessionid + AES 加密 studentCode）。STAR 平台的活动列表为公开接口，无需额外登录；个人星值用独立的 Bearer Token，由 `StarAuthCoordinator` 单独维护。

邮件推送：`设置 → 通知` 中可填写接收邮箱并同步到 `https://tjpush.mikezhuang.cn`。如果用户开启“离线邮件推送”并保存同济统一身份账号密码，服务端会加密保存这组凭据，用于低频轮询教务通知；卓越星新活动和报名提醒优先使用公开活动接口，不上传 STAR Token。关闭邮件推送会请求服务器删除订阅和凭据。SMTP 密码、服务端加密主密钥不写入 App 或仓库。

校园卡低余额提醒：`设置 → 通知` 中可单独开启“校园卡低余额提醒”，默认阈值为 `50` 元，也可手动改成 `9` / `20` / `30` 等。App 本地通知与服务端邮件提醒统一使用这一个阈值；首次只建立基线，不补发历史低余额状态，后续只有在“余额从高于阈值变为低于或等于阈值”时才提醒一次。若余额一直处于低位，不会反复打扰；只有余额恢复到阈值以上后再次跌破，才会重新提醒。

### 长效登录态体系

为了避免"半夜被踢、早起重登"的体验，App 实现了三层兜底续期：

1. **L1 静默续期**：业务 API 收到 401/403 时，由 `AuthRecoveryManager` 通过隐藏在根视图上的 0×0 `WKWebView` 重新访问 `1.tongji.edu.cn/workbench`。只要 IAM SSO cookie 仍有效，浏览器会自动跳回 workbench 并写入新的 `sessiondata`，全过程对用户无感。
2. **L2 密码自动回填**（严格 opt-in）：用户在 `设置 → 自动登录` 中开启后，账号密码会以 `kSecAttrAccessControl(biometryCurrentSet)` 写入 Keychain，密钥锁进 Secure Enclave。L1 失败时，框架会触发一次 Face ID / Touch ID 校验，然后用 JS 注入填充 IAM 登录表单提交。若学校 SSO 当时要求图形验证码 / 短信码 / 二次验证，会自动检测并降级到 L3。
3. **L3 交互登录**：上述全部失败 → `CampusModel.authState` 转 `requiresInteractiveLogin`，日程页 / 卓越星页顶部出现非阻塞 banner 引导手动登录。**本地课表 / 活动缓存不会被清空。**

并发请求安全：`AuthRecoveryManager` 通过 single-flight `Task<Bool, Never>` 把多个 API 并发遇到 401 的情况合并成一次续期，不会出现"同一时间触发多次重登"。

Cookie 处理：所有响应里的 `Set-Cookie` 会被合并回 `CookieJar.shared`（结构化存储，按 domain / path / expires 过滤、持久化到 Keychain `tongji_cookies_jar`），让服务端滚动刷新的 sessionId 立即生效。

日程页的校历接口只用于缓存"本学期第几周对应哪一段日期"：`calendarId`、`beginDay`、`endDay`、`weekNum` 等。当前显示第几周由本机系统日期和缓存的 `beginDay` 即时计算，同一学期内不会每次进入日程页都请求校历接口。

## 暂未实现 / 不计划在 v0.1 实现

> 已删除 / 不创建（参考 DanXi 但本项目不实现）：树洞社区、课评、AI 助手、教师日程、图书馆人数、食堂排队、巴士、电费、运动数据、钱包、宿舍预约…… 后续按需独立 module 增量加入。

## 项目结构

```
Jinitaimei/
├── project.yml                # XcodeGen 项目描述（唯一事实来源；修改后跑 `xcodegen generate`）
├── Jinitaimei.xcodeproj/      # Xcode 壳工程（不入仓，clone 后由 xcodegen 生成）
├── App/                       # iOS App 入口
│   ├── JinitaimeiApp.swift    # @main 入口，注册 SwiftData ModelContainer
│   ├── Info.plist
│   └── Assets.xcassets/
├── TongjiKit/                 # 业务 SDK（本地 SPM Package）
│   └── Sources/TongjiKit/
│       ├── Authentication/    # SSO 登录 / 静默续期 / 密码回填 / AuthRecoveryManager / CookieJar / Keychain / studentCode AES-CBC / StarAuthCoordinator
│       ├── Course/            # 一系统课表 API + 解析 + SwiftData 仓储
│       ├── Activity/          # STAR 活动 API + 解析 + SwiftData 仓储
│       ├── TeachingNotice/    # 一系统通知公告 API + 模型
│       ├── Wallet/            # 校园卡余额与消费记录 API / 登录续期 / SwiftData 快照
│       ├── Profile/           # 一系统 session 用户信息
│       ├── CampusModel.swift  # 全局登录态
│       └── Util/              # JSON 等工具
└── TongjiUI/                  # UI 层（本地 SPM Package，依赖 TongjiKit）
    └── Sources/TongjiUI/
        ├── Navigation/        # RootView（TabBar + 隐藏续期 WebView + scenePhase 节流检查） / CampusHome
        ├── Components/        # AuthStateBanner（renewing / requiresInteractiveLogin 非阻塞 banner）
        ├── Pages/             # LoginPage / AutoLoginSettingsView / ActivityListPage / TeachingNoticePage / CampusCardPage / SettingsPage
        └── Calendar/          # CoursePage（周课表）
```

模块依赖方向（单向）：

```
Jinitaimei (App) → TongjiUI → TongjiKit
                            ↘ SwiftData / WebKit / SafariServices / CommonCrypto / Security
```

## 在 Xcode 中调试

### 环境要求

- macOS 14 Sonoma 或更新
- Xcode 15.0+（含 iOS 17.0 SDK）
- **必装** [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
  本仓库不提交 `Jinitaimei.xcodeproj/`（已写进 `.gitignore`），`project.yml` 才是工程描述的唯一事实来源。
- 一个 Apple ID（免费即可，真机 7 天证书；如有付费开发者账号可直接长期签）

### 首次打开

```bash
# 1. 安装 XcodeGen（如已装跳过）
brew install xcodegen

# 2. 在仓库 Jinitaimei/ 目录下生成 Xcode 工程
cd Jinitaimei
xcodegen generate

# 3. 打开
open Jinitaimei.xcodeproj
```

> 任何时候修改了 `project.yml`（增删源文件目录、改 bundle id、调 build setting 等）后，都要重新跑 `xcodegen generate`。也别试图把 Xcode 里手动加的文件/设置写回，下一次 generate 会被覆盖——所有改动应该写到 `project.yml`。

### 在 iPhone 模拟器中运行

1. 打开 `Jinitaimei.xcodeproj`。
2. 顶部 scheme 选 **Jinitaimei**。
3. 顶部 device 选择任意 iPhone 模拟器（例如 `iPhone 15` / `iPhone 15 Pro`，iOS 17.x）。
4. `⌘R` 运行。首次启动不会自动弹出登录页；进入 `设置 → 校园账户` 后，用学号 + 统一身份密码登录即可。登录完成后 App 会询问是否保存账号密码用于自动续期登录（Face ID / Touch ID 保护，默认拒绝；也可随时在 `设置 → 自动登录` 中关闭）。
5. 模拟器内 WebView 调试：在 macOS Safari 菜单中开启 `开发 → 模拟器 → <你的 WebView>`，可像调试网页一样调试 SSO 流程。

### 用数据线在真机 iPhone 上调试

1. 用数据线把 iPhone 接到 Mac，iPhone 端点击 **信任此电脑**。
2. iPhone：`设置 → 隐私与安全性 → 开发者模式` 打开（仅 iOS 16+ 需要），重启 iPhone。
3. Xcode 顶部 device 列表里选你的 iPhone（不要选模拟器）。
4. 选中项目 → **Signing & Capabilities** 标签：
   - Team 改为你自己的 Apple ID（在 Xcode → Settings → Accounts 里先登录账号）。
   - Bundle Identifier 改成全局唯一值，例如 `com.<yourname>.jinitaimei`（默认 `com.jinitaimei.app` 可能被占用）。
5. `⌘R` 安装并运行。首次安装后 iPhone 会弹"不受信任的开发者"，去 `设置 → 通用 → VPN与设备管理 → 开发者 App → 你的 Apple ID → 信任` 一次即可。
6. 免费 Apple ID 的真机证书 7 天后失效；到期后重新 `⌘R` 一次即可重签。

### 真机 WebView 调试

1. iPhone：`设置 → Safari → 高级 → Web 检查器` 打开。
2. iPhone 接到 Mac，启动 App 并停留在登录页。
3. Mac Safari：`开发 → <你的 iPhone> → <WebView>` 即可。

### 命令行构建（CI 友好）

```bash
# 1. 生成工程（首次或修改 project.yml 后）
xcodegen generate

# 2. 仅编译（不签名），快速校验代码无误
xcodebuild \
  -project Jinitaimei.xcodeproj \
  -scheme Jinitaimei \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO
```

### 常见问题排查

- **App 界面只占屏幕中间，上下两条黑边** ——
  iOS 没识别到 LaunchScreen 配置，被强制按"iPhone 4 兼容模式"渲染。检查 [App/Info.plist](App/Info.plist) 里有 `UILaunchScreen` 键，然后在 Xcode 里 `Product → Clean Build Folder` (⇧⌘K) 一次再 ⌘R。
- **登录页一闪而过自动关闭** ——
  当前实现在每次进入 `LoginPage` 时调用 `TongjiAuthCoordinator.startFreshInteractiveLogin()` 主动清空 WKWebView 的 cookie/localStorage，强制重新走 SSO；如果你修改这条路径去掉清理逻辑，残留 cookie 会让 SSO 静默通过、登录页会瞬间关闭。（**注意**：静默续期路径 `attemptSilentRenew()` 故意**不**清数据，目的就是复用 IAM cookie，请勿混淆。）
- **第二天打开 App 又被踢出登录** ——
  正常情况下应当只看到顶部短暂出现"登录状态刷新中…"的 banner，几秒后自动消失。如果反复落到 `requiresInteractiveLogin`，看控制台 `[AuthRecovery]` / `[Auth]` 日志：
  - L1 失败 + 用户未开自动登录 → 直接进 L3，属于预期。建议在 `设置 → 自动登录` 中开启 Face ID 保护的自动登录。
  - L1 失败 + L2 也失败 → 多半学校 SSO 当时在弹验证码 / 短信码，搜索 `mfaRequired` 日志即可确认；只能手动登录一次。
  - L1 一直超时 → 检查根视图是否正确挂载了 `AuthRecoveryManager.shared.silentCoordinator.webView`（0×0 隐藏视图）。WKWebView 不挂在视图树上时 SPA JS 会被系统暂停，导致抽取失败。
- **修改 project.yml 后 Xcode 编译不到新文件** —— 重新跑 `xcodegen generate`。
- **修改了 SPM Package（TongjiKit / TongjiUI）后 Xcode 看似没更新** ——
  `File → Packages → Reset Package Caches`，或直接关闭 Xcode 后 `rm -rf Jinitaimei.xcodeproj/project.xcworkspace/xcshareddata/swiftpm` 再 `xcodegen generate`。
- **真机首次安装提示"不受信任的开发者"** —— 见上面"真机数据线调试"第 5 步。

## 上游参考链接

- 复旦 DanXi（Flutter）：<https://github.com/DanXi-Dev/DanXi>
- 复旦 DanXi-swift（SwiftUI）：<https://github.com/DanXi-Dev/DanXi-swift>
- 同济 wish_drom（.NET MAUI 原型， [https://github.com/wyyyz1937365497/wish_drom](https://github.com/wyyyz1937365497/wish_drom)）

> 本项目源代码均为重写而成，未直接复制上游代码。借鉴部分主要在：架构分层（DanXi-swift 的 `Fudan Kit` + `FudanUI` 双 Package 拆分）、信息架构（"校园服务首页 + 可点开列表"模式）、SwiftUI 视图组织与 WKWebView SSO 登录交互。

## License

待选（计划与上游 DanXi 一致，使用 MIT 或 Apache 2.0）。在确定前所有代码暂以"All Rights Reserved" 默认许可。
