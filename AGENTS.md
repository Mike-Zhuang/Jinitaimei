# Jinitaimei 项目代理指令

本 `AGENTS.md` 仅对 `Jinitaimei/` 子目录生效，提供本项目内部的工程约定。仓库根目录的边界约束见 [../AGENTS.md](../AGENTS.md)，必须先遵守。

## 1. 编辑权限

- 本目录 (`Jinitaimei/`) 可读可写。
- 兄弟目录 `DanXi/` `DanXi-swift/` `wish_drom/` **只读**。引用它们用相对路径链接，**不复制源代码**。

## 2. 命名规范（与用户根规则一致）

| 类型 | 命名格式 | 示例 |
| --- | --- | --- |
| Swift 变量 / 函数 | `camelCase` | `fetchTimetableRaw`, `isLoading` |
| Swift 类 / 结构体 / 枚举 / Protocol | `PascalCase` | `CourseSchedule`, `TongjiAuthCoordinator` |
| 常量 / Keychain Key | `UPPER_SNAKE_CASE` 或 `camelCase` 静态字段 | `CredentialStore.Keys.tongjiCookies` |
| 文件 / 文件夹 | 大类目录 `PascalCase`（与 SPM target 同名），通用脚本 `kebab-case` | `TongjiKit/Sources/TongjiKit/Authentication/CredentialStore.swift` |

> 例外：Swift 类型与同名文件统一用 `PascalCase`，不强制 `kebab-case`，符合 Swift 生态约定且与 DanXi-swift 一致。

## 3. 模块依赖方向（单向）

```
App (Jinitaimei target)  ──►  TongjiUI  ──►  TongjiKit
                                              │
                                              ├─► Foundation / SwiftData
                                              ├─► WebKit (登录 / 静默续期 / 密码回填 WKWebView)
                                              ├─► CommonCrypto / Security (AES + Keychain)
                                              ├─► LocalAuthentication (Face ID / Touch ID 解锁自动登录凭证)
                                              └─► SafariServices (活动详情)
```

**禁止反向依赖**：`TongjiKit` 不得 `import TongjiUI`、不得 `import SwiftUI`（仅在确实需要 ObservableObject 时 import SwiftUI，且 View 不写在 Kit 内）。

## 4. 代码风格

- 注释、文档、commit message 使用简体中文；标识符保持英文。
- 业务复杂处必须有中文注释解释**为什么**（特别是协议逆向部分，如 AES paramHandler、XHR 拦截器 eval 拆分）。
- 不写废话注释（"// 设置变量"之类）。
- 函数尽量短，单一职责。
- 异常用 `throws` + `LocalizedError`；不要静默吞掉。
- 网络请求：401/403 **只抛 `AuthError.expired`**，**禁止** `store.remove` 凭证。
  - 凭证清理由 `AuthRecoveryManager` 统一调度（只有 `CampusModel.logout()` 才允许真正清空）。
  - 所有对外公开的 API 方法（如 `fetchTimetableRaw`）必须用 `withAuthRetry { ... }`（或 STAR 平台的 `withStarAuthRetry`）包一层，让框架自动触发静默续期 + 重试一次。
  - 同时提供一个不带 retry 的 `*Once` 版本，供续期协调器内部调用，避免再次进入 `AuthRecoveryManager` 造成 single-flight 死锁。
  - 收到响应后把 `Set-Cookie` 通过 `CookieJar.shared.mergeSetCookieFields` 回写，保证 sessionId 滚动刷新能被本地感知。
- 避免 `any`：JSON 解析虽然用了 `[String: Any]`，但暴露给上层的类型必须强类型。

## 4.1 鉴权与登录态约定

- 全局状态机走 `CampusModel.authState`（`CampusAuthState`）五态：`loggedOut / valid / renewing / expiredRecoverable / requiresInteractiveLogin`。
  - `loggedIn` 是计算属性 = `authState != .loggedOut`。`requiresInteractiveLogin` 也算"有本地账户"，UI 应继续展示本地缓存。
  - 仅 `markValid / markRenewing / markRecoverableExpired / markRequiresInteractiveLogin` 这四个入口允许推进状态；其余地方不得直接写 `authState`。
- 本地数据清空入口**唯一**：`CampusModel.logout()`，会同时清 `CredentialStore.clearAll()` + `CookieJar.clear()` + `removeAutoLoginCredentials()`。其他任何位置**禁止**主动清缓存。
- Cookie 全部通过 `CookieJar.shared`（结构化存储 + 持久化 Keychain `tongji_cookies_jar`）。旧版扁平字符串 `tongji_cookies` 仅作首次迁移读取，不要再写入。
- 登录协调器分三个入口：
  - `TongjiAuthCoordinator.startFreshInteractiveLogin()`：仅"用户主动重登"使用，会清 WebView 数据。
  - `TongjiAuthCoordinator.attemptSilentRenew()`：API 401 触发；不清数据，复用 IAM SSO。
  - `TongjiAuthCoordinator.attemptPasswordRelogin(username:password:)`：L1 失败后由 `AuthRecoveryManager` 调用，JS 注入填表；遇验证码 / MFA 抛 `AuthError.mfaRequired`。
- 自动登录账号密码使用 `kSecAttrAccessControl(biometryCurrentSet)` + Secure Enclave，读取必经 `LAContext`。**禁止**写入未加生物识别保护的密码副本，也禁止在内存中长期持有明文（仅交互登录瞬间到 `LoginPage` 弹 prompt 这段窗口允许）。
- STAR 平台用独立的 `StarAuthCoordinator.shared`，**与 `CampusModel.authState` 完全解耦**——STAR token 失效不应让一系统状态变 `requiresInteractiveLogin`。

## 5. 新增功能流程

新加一项校园服务（例：图书馆人数）时：

1. 在 `TongjiKit/Sources/TongjiKit/<FeatureName>/` 下创建：Model（@Model）、API（URLSession + 鉴权头）、Parser（纯函数）、Store（@MainActor ObservableObject）。
2. 在 `TongjiUI/Sources/TongjiUI/Pages/` 创建 `<FeatureName>Page.swift`。
3. 在 `TongjiUI/Navigation/CampusHome.swift` 新增一个 `NavigationLink` 入口。
4. 在 `App/JinitaimeiApp.swift` 的 `ModelContainer(for: ...)` 中注册新 `@Model` 类。

## 6. 上游代码引用规则

- 在注释或文档中引用上游文件用相对路径（如 `wish_drom/Services/DataProviders/TongjiScheduleProvider.cs`）。
- 移植算法（如 AES studentCode 加密、XHR 拦截器）时在 doc-comment 里**显式注明"移植自 …"**，便于追溯。
- 不要从上游复制粘贴整段代码——重写并适配 Swift 风格。

## 7. 构建与测试

- 修改 `project.yml` 后必须运行 `xcodegen generate` 重新生成 `.xcodeproj`。
- 提交前推荐跑一次：
  ```bash
  xcodebuild -project Jinitaimei.xcodeproj -scheme Jinitaimei \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build CODE_SIGNING_ALLOWED=NO
  ```
- 暂未引入测试 target；后续若需测试，在各 SPM Package 内加 `Tests/<Module>Tests/` 即可。
