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
                                              ├─► WebKit (登录页 WKWebView)
                                              ├─► CommonCrypto / Security (AES + Keychain)
                                              └─► SafariServices (活动详情)
```

**禁止反向依赖**：`TongjiKit` 不得 `import TongjiUI`、不得 `import SwiftUI`（仅在确实需要 ObservableObject 时 import SwiftUI，且 View 不写在 Kit 内）。

## 4. 代码风格

- 注释、文档、commit message 使用简体中文；标识符保持英文。
- 业务复杂处必须有中文注释解释**为什么**（特别是协议逆向部分，如 AES paramHandler、XHR 拦截器 eval 拆分）。
- 不写废话注释（"// 设置变量"之类）。
- 函数尽量短，单一职责。
- 异常用 `throws` + `LocalizedError`；不要静默吞掉。
- 网络请求：401/403 必须清除对应凭证 + 抛 `AuthError.expired`。
- 避免 `any`：JSON 解析虽然用了 `[String: Any]`，但暴露给上层的类型必须强类型。

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
