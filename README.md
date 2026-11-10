# 极光 · 稳定自签全栈套件

> 一套能装到 iPhone 上长期用的完整工程：**SwiftUI 客户端 + 零依赖 Node 后端 + Windows 上可执行的重签工具链**。
> 描述文件到期不用重新编译，一条命令换签名。

```
┌──────────────┐   HTTPS/HTTP   ┌────────────────────────┐
│  iOS 极光 App │ ─────────────► │ Node 后端 (零依赖)      │
│  SwiftUI      │ ◄───────────── │ SQLite · scrypt · JWT  │
└──────────────┘                └────────────────────────┘
        ▲                                  ▲
        │ 重签（Windows 一条命令）          │ 同源网页控制台
┌───────┴────────┐                ┌────────┴────────┐
│ zsign + 描述文件 │                │ /  (public/)    │
└────────────────┘                └─────────────────┘
```

---

## 1. 现在就能确认的事实

本机已实测（不是「应该能跑」）：

| 部位 | 验证方式 | 结果 |
|---|---|---|
| 后端 | `node tools/smoke.js`（真 HTTP，49 项断言） | **49 / 49 通过** |
| 网页前端 + 静态服务 | `node tools/test-web.mjs`（29 项） | **29 / 29 通过** |
| 重签工具链 | `tools/test-signing-tools.ps1`（30 项，含故障注入） | **30 / 30 通过** |
| 图标 | `node tools/gen-icons.js` 自写 PNG 编码器 | 已产出 1024/512/180/32 |

**唯一无法在本机完成的一步**：用 Xcode 把 Swift 编译成 Mach-O。这台机器是 Windows，
所以工程里配了 `.github/workflows/ios.yml`（macOS runner）来出未签名 IPA —— 详见第 5 节。

---

## 2. 目录

```
aurora/
├─ ios/                              ← iOS 客户端（Xcode 16 工程）
│  ├─ AuroraApp.xcodeproj/           · 同步分组工程，加文件不用改 pbxproj
│  ├─ AuroraApp/                     · 10 个 Swift 文件，约 2600 行
│  │  ├─ AuroraApp.swift  Config.swift  Theme.swift  Models.swift  Keychain.swift
│  │  ├─ APIClient.swift  AppStore.swift  RootView.swift  AuthView.swift
│  │  ├─ BoardView.swift  NoteEditorView.swift  SettingsView.swift
│  │  └─ Assets.xcassets/            · AppIcon（脚本生成）
│  └─ Config/Info.plist · AuroraApp.entitlements
├─ server/                           ← 后端（零第三方依赖）
│  ├─ index.js    入口：API + 静态资源 + 优雅退出 + TLS
│  ├─ routes.js   全部路由
│  ├─ auth.js     scrypt / HS256 / 刷新令牌旋转
│  ├─ security.js CSP、限流、校验、体积上限
│  ├─ db.js       SQLite + 版本化迁移（校验和防篡改）
│  └─ config.js   配置与密钥装载
├─ public/                           ← 网页控制台（原生 ESM，无框架）
├─ tools/                            ← 构建 / 签名 / 体检 / 版本
│  ├─ resign.ps1  verify-ipa.ps1  profile-report.ps1
│  ├─ build-ipa.sh  gen-icons.js  bump-version.ps1
│  ├─ test-signing-tools.ps1  test-web.mjs  smoke.js
│  └─ lib/  PlistXml.ps1（含 binary plist 解析） · IpaInspect.ps1
├─ signing/                          ← 签名材料（证书/描述文件已 gitignore）
│  └─ README.md                      ← **稳定自签的完整方法论**
├─ version.json                      ← 版本号唯一来源
└─ CHANGELOG.md
```

---

## 3. 跑起来（后端 + 网页，30 秒）

```powershell
cd aurora
node server/index.js
```

启动横幅会打印手机该用的地址：

```
  本机    http://127.0.0.1:8787
  局域网  http://192.168.1.10:8787  (WLAN)  ← 手机填这个
  注册用户上限 8 · 注册开放
  口令强度：scrypt N=16384 r=8 p=1
```

浏览器打开那个地址 → 创建账号（第一个账号自动是主控）→ 开始记条目。

常用环境变量：

| 变量 | 作用 | 默认 |
|---|---|---|
| `PORT` / `HOST` | 监听 | `8787` / `0.0.0.0` |
| `AURORA_SECRET` | 令牌密钥（≥32 字符） | 自动生成到 `data/.secret`(600) |
| `AURORA_MAX_USERS` | 注册人数上限 | `8` |
| `AURORA_ALLOW_REGISTER` | 设为 `0` 关闭注册 | 开放 |
| `AURORA_DATA` | 数据目录 | `./data` |
| `AURORA_TLS_CERT` / `AURORA_TLS_KEY` | 启用 HTTPS | 不启用 |
| `AURORA_TRUST_PROXY` | 反代后取真实 IP | `0` |

---

## 4. iOS 客户端

**设计**：极光色板（`#6D5BFF → #C94BFF → #27E1F5`）、三团漂移光斑背景、玻璃面板 + 内描边、
逐条弹簧动效、`UIImpactFeedbackGenerator` 触感。列表用原生 `List`，所以滑动操作是系统级手感：

* 左滑：删除 / 编辑
* 右滑：完成 / 置顶（满滑直接触发）

**响应式细节**：乐观更新（点一下立刻变，失败自动回滚）、409 冲突提示并自动刷新、
搜索本地即时过滤、下拉刷新、骨架屏、空状态、错误态带重试。

**安全**：访问令牌只进 Keychain（`AfterFirstUnlockThisDeviceOnly`，不随备份迁移）；
刷新 Cookie 手动管理（不依赖系统 Cookie 存储的时序）；401 自动刷新一次并重放，
并发刷新合并为一次。

### 用 Xcode 打开

```bash
open ios/AuroraApp.xcodeproj     # 需要 Xcode 16+（工程用了同步分组格式）
```

真机跑之前改服务端地址（不用改代码）：

```
Signing & Capabilities → 选你的 Team
Build Settings → API_BASE_URL = http://你电脑的局域网IP:8787
```

或命令行：

```bash
xcodebuild -project ios/AuroraApp.xcodeproj -scheme AuroraApp \
  -destination 'generic/platform=iOS' \
  API_BASE_URL=http://192.168.1.20:8787 archive
```

---

## 5. 出 IPA：两步，其中第二步在 Windows 上做

### 第一步：编译出未签名 IPA（macOS 或 CI）

```bash
API_BASE_URL=http://192.168.1.20:8787 tools/build-ipa.sh
# → dist/Aurora-1.4.0-1-unsigned.ipa
```

没有 Mac：把仓库推到 GitHub，仓库里已带 `ios` workflow（macos-14），
`Actions → ios → Run workflow` 即可下载 artifact。**签名材料不进 CI**，这是故意的。

### 第二步：在 Windows 上重签（这就是「稳定」的关键）

```powershell
# 描述文件先体检：类型 / TeamID / AppID / 剩余天数
powershell -NoProfile -File tools/profile-report.ps1 -Profile signing/Aurora_AdHoc.mobileprovision

# 重签 + 自动体检产物
powershell -NoProfile -File tools/resign.ps1 `
  -Ipa dist/Aurora-1.4.0-1-unsigned.ipa `
  -P12 signing/dev.p12 -PasswordFile signing/pass.txt `
  -Profile signing/Aurora_AdHoc.mobileprovision
```

重签脚本会先做四道卡口（Bundle ID 一致性、描述文件是否过期、类型是否可侧载、设备列表是否为空），
任何一道不过直接拒绝，不会产出装不上的包。签完自动调 `verify-ipa.ps1` 体检结构、arm64、`_CodeSignature`、
内嵌描述文件与到期倒计时。

> zsign：<https://github.com/zhlynn/zsign/releases> → 解压到 `tools/zsign/zsign.exe`。
> 需要 `-AdHoc`（越狱/TrollStore 无证书签名）也支持。

**完整方法论**（通道对比、五个不变量、到期管理、安装失败排查表）在 **[signing/README.md](signing/README.md)**。

---

## 6. 版本控制

版本号只有一处真相：`version.json`。
`Info.plist` 用 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` 变量引用，所以**永远不会漏改**。

```powershell
powershell -NoProfile -File tools/bump-version.ps1 -Bump patch -Note "修复登录卡顿"
```

会同步：`version.json` → `package.json` → `project.pbxproj`（两处配置）→ `tools/.build`（后端 `/api/version`）→ `CHANGELOG.md`。

首次入库：

```bash
git init
git add -A
git commit -m "chore: 极光全栈套件 v1.4.0"
git tag -a v1.4.0 -m "v1.4.0 build 1"
```

（这一步没替你执行 —— 提交与打标签应当由你确认后再做。）

---

## 7. 安全设计（逐条对应实现）

| 关注点 | 做法 | 位置 |
|---|---|---|
| 口令存储 | scrypt（N=16384,r=8,p=1，16 字节随机盐），比较用 `timingSafeEqual` | `server/auth.js` |
| 登录时序泄漏 | 邮箱不存在时也跑一次 scrypt（dummy hash） | `server/routes.js` |
| 令牌 | HS256 访问令牌 15 分钟；刷新令牌是随机串，**只存 SHA-256 哈希** | `auth.js` |
| 令牌被盗用 | 刷新令牌一次性旋转；旧令牌被复用 → 判定泄露，吊销该用户全部会话 | `auth.js` |
| 越权 | 每条 SQL 都带 `user_id = ?`，跨用户访问一律 404 | `routes.js` |
| 写入冲突 | `rev` 乐观并发，过期 rev → 409 | `routes.js` |
| 注入 | 全部参数化 SQL；搜索的 `%`/`_` 被转义 | `routes.js` |
| 限流 | 登录 8/5min/账号、注册 12/h/IP、常规 240/min/IP + 突发桶 | `security.js` |
| 请求体积 | 96KB 上限；超限仍能读到 413（不是连接被重置） | `security.js` |
| 响应头 | CSP（无内联脚本）、nosniff、DENY、no-referrer、Permissions-Policy、HSTS | `security.js` |
| 静态资源 | 路径穿越拦截、ETag、HTML 不缓存 | `server/index.js` |
| 数据库 | WAL + `synchronous=FULL` + 外键 + `trusted_schema=OFF` | `db.js` |
| 迁移 | 每条迁移带校验和，历史迁移被改动即启动失败 | `db.js` |
| 客户端令牌 | 只落 Keychain，`AfterFirstUnlockThisDeviceOnly` | `ios/AuroraApp/Keychain.swift` |
| 客户端网络 | ephemeral URLSession、无磁盘缓存、无 Cookie 存储、15s 超时 | `APIClient.swift` |
| 秘密入库 | `.gitignore` 排除 p12 / mobileprovision / 口令 / data | `.gitignore` |

**已知取舍**：`Info.plist` 里 `NSAllowsArbitraryLoads = true` 是为了让手机能连局域网的明文服务端。
正式分发前把服务端切 HTTPS（`AURORA_TLS_CERT`/`AURORA_TLS_KEY`）并删掉这项。

---

## 8. 命令速查

| 想做什么 | 命令 |
|---|---|
| 启动后端 | `node server/index.js` |
| 后端全量测试 | `node tools/smoke.js` |
| 前端契约测试 | `node tools/test-web.mjs` |
| 签名工具自检 | `powershell -NoProfile -File tools/test-signing-tools.ps1` |
| 重新生成图标 | `node tools/gen-icons.js` |
| 描述文件体检 | `powershell -NoProfile -File tools/profile-report.ps1 -Profile x.mobileprovision` |
| IPA 体检 | `powershell -NoProfile -File tools/verify-ipa.ps1 -Ipa x.ipa` |
| 重签 | `powershell -NoProfile -File tools/resign.ps1 -Ipa x.ipa -P12 c.p12 -PasswordFile p.txt -Profile y.mobileprovision` |
| 升版本 | `powershell -NoProfile -File tools/bump-version.ps1 -Bump patch -Note "..."` |
| 补 .ps1 的 BOM | `powershell -NoProfile -File tools/fix-ps1-bom.ps1` |

### API 面

```
GET    /api/version                       版本 / build / channel
GET    /api/health                        健康检查
POST   /api/auth/register  {email,password}
POST   /api/auth/login     {email,password}
POST   /api/auth/refresh                  用 HttpOnly Cookie 换新访问令牌
POST   /api/auth/logout
GET    /api/me
GET    /api/stats                         总数/待办/紧急/完成/逾期
GET    /api/notes?q=&status=
POST   /api/notes          {title,body,priority,tags,due}
PATCH  /api/notes/:id      支持 rev 乐观并发
DELETE /api/notes/:id
```

---

## 9. 边界说明

* **iOS 编译必须在 macOS 上**（Xcode 或 CI 的 macOS runner）。Windows 侧负责的是签名与分发，
  这也是自签工程里最容易出错、最值得脚本化的部分。
* 工程用 Xcode 16 的对象版本（同步分组）。Xcode 15 打不开 —— 需要的话把
  `PBXFileSystemSynchronizedRootGroup` 换回传统 `PBXGroup` 文件列表。
* PowerShell 脚本按 Windows PowerShell 5.1 兼容编写；改脚本后若中文报语法错，
  跑一次 `tools/fix-ps1-bom.ps1`（5.1 读无 BOM 的 .ps1 会按 ANSI 解码）。
* 单实例后端（限流在内存里）。要多实例，把 `security.js` 的桶换成 Redis。
