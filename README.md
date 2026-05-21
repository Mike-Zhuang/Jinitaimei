# Jinitaimei · 同济大学 iPhone App

一个面向同济大学学生的开源 iOS App，仅支持 iPhone（不支持 iPad / Mac / watchOS）。当前为 v0.1.0 早期版本，按"逐步开发"的方式从最小可用功能开始迭代。

> Jinitaimei 在架构与 UI 设计上重度参考了复旦大学的优秀开源项目 [DanXi](https://github.com/DanXi-Dev/DanXi)（Flutter）与 [DanXi-swift](https://github.com/DanXi-Dev/DanXi-swift)（SwiftUI 重写版）；同济业务数据抓取逻辑参考了同一作者的 .NET MAUI 原型 [wish_drom](../wish_drom)。在此致谢上游项目。

## 当前已实现功能

| Tab | 功能 | 数据来源 | 状态 |
|-----|------|---------|------|
| 日程 | 周课表查看（按周切换、点击节次看详情） | 一系统 `1.tongji.edu.cn` `findStudentTimetab` | v0.1 可用 |
| 校园 | 卓越星活动列表（点击跳官方详情页） | STAR 平台 `star.tongji.edu.cn` `/api/app-api/activity/index/list` | v0.1 可用 |

登录方式：**仅同济统一身份认证（iam/ids.tongji.edu.cn）**。用户在登录页 WebView 内完成一次 SSO 后，App 在后台依次跳转 `1.tongji.edu.cn/workbench` 与 `star.tongji.edu.cn`，复用 SSO Cookie 自动完成两边的凭证抓取（一系统：Cookie + sessionid + 加密 studentCode；STAR：Bearer Token）。后续访问课表与卓越星都不再需要重复登录。

## 暂未实现 / 不计划在 v0.1 实现

> 已删除 / 不创建（参考 DanXi 但本项目不实现）：树洞社区、课评、AI 助手、教师日程、图书馆人数、食堂排队、巴士、电费、本科教务通知、运动数据、钱包、宿舍预约…… 后续按需独立 module 增量加入。

## 项目结构

```
Jinitaimei/
├── project.yml                # XcodeGen 项目描述（修改后跑 `xcodegen` 重新生成 .xcodeproj）
├── Jinitaimei.xcodeproj/      # Xcode 壳工程（由 project.yml 生成）
├── App/                       # iOS App 入口
│   ├── JinitaimeiApp.swift    # @main 入口，注册 SwiftData ModelContainer
│   ├── Info.plist
│   └── Assets.xcassets/
├── TongjiKit/                 # 业务 SDK（本地 SPM Package）
│   └── Sources/TongjiKit/
│       ├── Authentication/    # SSO 登录协调器 / Keychain CredentialStore / studentCode AES-CBC
│       ├── Course/            # 一系统课表 API + 解析 + SwiftData 仓储
│       ├── Activity/          # STAR 活动 API + 解析 + SwiftData 仓储
│       ├── CampusModel.swift  # 全局登录态
│       └── Util/              # JSON 等工具
└── TongjiUI/                  # UI 层（本地 SPM Package，依赖 TongjiKit）
    └── Sources/TongjiUI/
        ├── Navigation/        # RootView（TabBar） / CampusHome（校园服务列表）
        ├── Pages/             # LoginPage / ActivityListPage
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
- 一个 Apple ID（免费即可，真机 7 天证书；如有付费开发者账号可直接长期签）
- 仅用命令行构建时还需 `xcodegen`（`brew install xcodegen`）

### 首次打开

```bash
cd Jinitaimei
# 如果 .xcodeproj 已经存在可直接打开；如果只有 project.yml，则先生成：
xcodegen generate
open Jinitaimei.xcodeproj
```

> 修改 `project.yml`（增删文件、改 bundle id 等）后，需要重新跑 `xcodegen generate`。直接在 Xcode 里改也行，但 `project.yml` 才是单一事实来源。

### 在 iPhone 模拟器中运行

1. 打开 `Jinitaimei.xcodeproj`。
2. 顶部 scheme 选 **Jinitaimei**。
3. 顶部 device 选择任意 iPhone 模拟器（例如 `iPhone 15` / `iPhone 15 Pro`，iOS 17.x）。
4. `⌘R` 运行。首次启动会自动弹出 SSO 登录页，用学号 + 统一身份密码登录即可。
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
# 仅编译（不签名），快速校验代码无误
xcodebuild \
  -project Jinitaimei.xcodeproj \
  -scheme Jinitaimei \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO
```

## 上游参考链接

- 复旦 DanXi（Flutter）：<https://github.com/DanXi-Dev/DanXi>
- 复旦 DanXi-swift（SwiftUI）：<https://github.com/DanXi-Dev/DanXi-swift>
- 同济 wish_drom（.NET MAUI 原型，本仓库内的 [../wish_drom](../wish_drom)）

> 本项目源代码均为重写而成，未直接复制上游代码。借鉴部分主要在：架构分层（DanXi-swift 的 `Fudan Kit` + `FudanUI` 双 Package 拆分）、信息架构（"校园服务首页 + 可点开列表"模式）、SwiftUI 视图组织与 WKWebView SSO 登录交互。

## License

待选（计划与上游 DanXi 一致，使用 MIT 或 Apache 2.0）。在确定前所有代码暂以"All Rights Reserved" 默认许可。
