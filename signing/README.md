# 稳定自签：把「7 天掉签」变成可管理的事

自签的不稳定来源从来不是重签技术，而是**签名材料本身会过期、会吊销、会换 Team**。
这份文档只做一件事：把这四个变量钉死，让重签变成一条命令。

---

## 1. 先选通道：稳定性差异是量级上的

| 通道 | 有效期 | 可装设备 | 成本 | 稳定性 |
|---|---|---|---|---|
| 免费 Apple ID（Xcode 个人团队） | **7 天** | 已注册设备（≤3 台） | 0 | 差，必须每周重签 |
| 付费开发者 · Development | 1 年 | 已注册设备（≤100 台） | $99/年 | 好 |
| **付费开发者 · Ad Hoc**（推荐） | **1 年** | 已登记 UDID（≤100 台） | $99/年 | **最好，侧载语义最干净** |
| 企业 In-House | 1 年 | 任意设备 | $299/年 | 好但易被吊销，且违反条款会被封 |
| TrollStore / 越狱 ad-hoc | 无期限 | 越狱或支持机型 | 0 | 取决于机型与系统版本 |

**结论**：想「装一次用一年」，用付费账号 + Ad Hoc。本项目的脚本都按这条路铺的。

---

## 2. 稳定的五个不变量（改动任何一个，就要全部重签）

1. **TeamID 不变** —— 换开发者账号等于换根，钥匙串、iCloud 关联全部重建。
2. **Bundle ID 不变** —— 变了就是另一个 App，覆盖安装会失败（要卸载旧的）。
3. **签名证书不吊销** —— 在后台「Revoke」一次，已装 App 全部失效。
4. **目标设备 UDID 在描述文件里** —— Ad Hoc 装不上的第一原因。
5. **entitlements 与描述文件完全一致** —— 多声明一个 key 就启动即崩。

这五条就是本仓库 `ios/Config/AuroraApp.entitlements` 故意只留 `keychain-access-groups` 的原因：
**少声明 = 少冲突**。不要为了「看起来完整」去加 `aps-environment`、`com.apple.developer.*` 之类，
描述文件里没有的能力，签出来的包一定装不上或起不来。

---

## 3. 一次性配好（Apple Developer 后台）

1. **Certificates** → 新建 `Apple Distribution`（或 `iOS Distribution`）→ 下载 `.cer` → 导入 macOS 钥匙串
   → 从钥匙串导出 **`.p12`**（设口令），放到 `signing/dev.p12`（已在 .gitignore 里）。
2. **Identifiers** → 新建 App ID：`com.yg.aurora`（显式 App ID，不要用通配符，通配符用不了 Keychain 分组）。
3. **Devices** → 把每台要装的 iPhone 的 **UDID** 加进去。
   取 UDID：Finder 连上手机点设备信息，或「设置 → 通用 → 关于本机」看不到，用 Finder / Apple Configurator。
4. **Profiles** → 新建 **Ad Hoc** 描述文件 → 选证书 + 选 App ID + 勾全部设备 → 下载 `.mobileprovision`
   → 放到 `signing/Aurora_AdHoc.mobileprovision`。
5. 口令单独存：`signing/pass.txt`（一行纯口令，同样被 .gitignore 排除）。

**一年后**：只需回到第 4 步重新生成描述文件（证书通常也一起续），换掉文件即可，代码一行不动。

---

## 4. 重签：一条命令（Windows 上就能做）

```powershell
# 0) 先体检描述文件：类型 / TeamID / AppID / 还剩几天
powershell -NoProfile -File tools/profile-report.ps1 -Profile signing/Aurora_AdHoc.mobileprovision

# 1) 重签（自动做一致性校验，签完自动体检产物）
powershell -NoProfile -File tools/resign.ps1 `
  -Ipa dist/Aurora-1.4.0-1-unsigned.ipa `
  -P12 signing/dev.p12 `
  -PasswordFile signing/pass.txt `
  -Profile signing/Aurora_AdHoc.mobileprovision
```

脚本会依次做：

1. 找 zsign（放 `tools/zsign/zsign.exe`，或 `-Zsign` 指定）
2. 读包内 Bundle ID，与描述文件 `application-identifier` 比对——**不匹配直接拒绝，不浪费一次签名**
3. 描述文件过期 → 拒绝（`-AllowExpired` 可强过）
4. App Store 类型描述文件 → 拒绝（这种包不能侧载）
5. 调 zsign 重签，`entitlements` 默认从描述文件自动抽取
6. 体检产物：结构 / arm64 / `_CodeSignature` / 内嵌描述文件 / 到期天数

需要真 ad-hoc（越狱/TrollStore，无证书）：`-AdHoc`。

> zsign 下载：<https://github.com/zhlynn/zsign/releases> —— Windows 版解压后把
> `zsign.exe` 放到 `tools/zsign/zsign.exe`。

---

## 5. 到期管理：让过期这件事提前两周自己冒出来

```powershell
# 到期前 10 天返回退出码 1，可以直接挂到计划任务/CI 里当卡口
powershell -NoProfile -File tools/profile-report.ps1 -Profile signing/Aurora_AdHoc.mobileprovision -Strict
```

建议再设一条 Windows 计划任务，每周一跑一次；输出里 `剩余 N 天` 变黄就该动手了。
真过期了也不慌：**重签不需要重新编译，也不需要卸载重装**——用同一份 IPA 换新描述文件重签，
覆盖安装即可，数据（登录态除外）保留。

---

## 6. 安装失败排查表（按命中概率排序）

| 现象 | 原因 | 处理 |
|---|---|---|
| 点安装图标灰掉 / 提示无法安装 | 设备 UDID 不在描述文件里 | 后台加 UDID → 重新生成描述文件 → 重签 |
| 提示「无法验证 App」 | 未在手机上信任证书 | 设置 → 通用 → VPN与设备管理 → 信任 |
| 装完闪退 | entitlements 与描述文件不一致 | 去掉多余能力，只留 `keychain-access-groups` |
| 覆盖安装失败 | Bundle ID 变了 | 用同一个 Bundle ID 重签，或先删旧 App |
| 提示「App 需要更新」 | 版本号没变 | `tools/bump-version.ps1` 递增 build |
| 一段时间后全部打不开 | 描述文件到期 / 证书被吊销 | `tools/profile-report.ps1` 查到期，重签 |
| 签名成功但装不上，zsign 无报错 | 描述文件是 App Store 类型 | 换 Ad Hoc / Development |

---

## 7. 关于数据：重签会清掉登录态（正常现象）

钥匙串访问组绑定 `application-identifier`（含 TeamID）。换 Team 或换描述文件后，
系统认为「不是同一个 App」，旧令牌读不出来 → 需要重新登录一次。
业务数据在服务端，不受影响。

---

## 8. 本目录约定

```
signing/
├─ README.md                      ← 本文件（入库）
├─ dev.p12                        ← 证书私钥（不入库）
├─ pass.txt                       ← 证书口令（不入库）
├─ Aurora_AdHoc.mobileprovision   ← 描述文件（不入库）
└─ ExportOptions-*.plist          ← xcodebuild -exportArchive 模板（入库）
```

`tools/resign.ps1` 支持 `-PasswordFile`、也读环境变量 `AURORA_P12_PASSWORD`，
避免口令出现在命令历史里。
