# 变更记录

格式：语义化版本 + build 号。版本唯一来源是 [version.json](version.json)，
用 `tools/bump-version.ps1` 递增，会同步到 iOS 工程、后端与这里。

<!-- entries -->

## [1.4.0] - 2026-11-10  ·  build 1

- 初始可交付版本：SwiftUI 客户端 + 零依赖 Node 后端 + Windows 侧重签工具链
- 客户端：极光视觉系统、Keychain 令牌、401 自动刷新重放、乐观更新与冲突回滚
- 后端：scrypt 口令、HS256 访问令牌、刷新令牌旋转 + 复用检测、SQLite 迁移校验、多层限流
- 签名：zsign 重签脚本、描述文件体检（类型/TeamID/AppID/到期倒计时）、IPA 结构与架构体检
- 工具：自写 PNG 图标生成、binary plist 读取、签名工具链自检（30 项断言）
