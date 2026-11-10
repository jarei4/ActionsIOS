# tools/resign.ps1 — Windows 侧稳定重签：一份 IPA 反复换描述文件，不用重新编译
#
# 常用：
#   pwsh tools/resign.ps1 -Ipa dist/Aurora-unsigned.ipa `
#        -P12 signing/dev.p12 -PasswordFile signing/pass.txt `
#        -Profile signing/Aurora_AdHoc.mobileprovision
#
# 说明：
#   · 描述文件过期只需换 -Profile 重签一次，二进制不用动
#   · entitlements 默认从描述文件里取，别手动加，多一个 key 就装不上
#   · 越狱/TrollStore 设备可用 -AdHoc（无证书、无有效期）
#
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Ipa,

    # 签名证书（.p12 / .pfx）。-AdHoc 时不需要
    [string]$P12,

    # 证书口令。建议用 -PasswordFile 或环境变量 AURORA_P12_PASSWORD
    [string]$Password,

    [string]$PasswordFile,

    # .mobileprovision。决定有效期、可安装设备、TeamID
    [string]$Profile,

    # 覆盖 Bundle ID（一般不要用；改了就等于另一个 App）
    [string]$BundleId,

    # 覆盖显示名（App 图标下的名字）
    [string]$DisplayName,

    # 输出路径，默认 <输入名>-signed.ipa
    [string]$Out,

    # 自定义 entitlements plist；默认不传，zsign 自动从描述文件抽取
    [string]$Entitlements,

    # zsign 可执行文件路径；默认自动在 tools/zsign 与 PATH 里找
    [string]$Zsign,

    # 无证书 ad-hoc 签名（仅越狱 / TrollStore）
    [switch]$AdHoc,

    # 只打印将要执行的命令
    [switch]$DryRun,

    # 描述文件已过期也继续
    [switch]$AllowExpired,

    # 允许覆盖已存在的输出文件
    [switch]$Force,

    # 跳过签名后的体检
    [switch]$NoVerify
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/IpaInspect.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot

function Fail([string]$Message) {
    Write-Host ''
    Write-Host "  ✗ $Message" -ForegroundColor Red
    Write-Host ''
    exit 1
}

function Find-Zsign {
    param([string]$Explicit)

    $candidates = @()
    if ($Explicit) { $candidates += $Explicit }
    $candidates += @(
        (Join-Path $repoRoot 'tools/zsign/zsign.exe'),
        (Join-Path $repoRoot 'tools/zsign/windows/zsign.exe'),
        (Join-Path $repoRoot 'tools/zsign/zsign'),
        (Join-Path $repoRoot 'tools/zsign/windows/zsign')
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $command = Get-Command 'zsign' -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    return $null
}

# ── 1. 输入检查 ───────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $Ipa)) { Fail "输入 IPA 不存在：$Ipa" }
$inputPath = (Resolve-Path -LiteralPath $Ipa).Path
$inputInfo = Get-Item -LiteralPath $inputPath

if (-not $Out) {
    $Out = Join-Path $inputInfo.DirectoryName ($inputInfo.BaseName + '-signed.ipa')
}
if (Test-Path -LiteralPath $Out) {
    if (-not $Force) { Fail "输出已存在：$Out（加 -Force 覆盖）" }
    Remove-Item -LiteralPath $Out -Force
}
$outPath = [System.IO.Path]::GetFullPath($Out)
$outDir = Split-Path -Parent $outPath
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$signer = Find-Zsign -Explicit $Zsign
if (-not $signer) {
    Fail @'
未找到 zsign。二选一：
  1) 下载 zsign 放到 tools/zsign/zsign.exe    https://github.com/zhlynn/zsign/releases
  2) 用 -Zsign <路径> 指定
'@
}

# ── 2. 读出包里的 Bundle ID ───────────────────────────────────
$inspection = Test-Ipa -Path $inputPath
if (-not $inspection.AppFolder) { Fail '输入文件不是可安装的 IPA（缺少 Payload/*.app）' }
$appBundleId = if ($BundleId) { $BundleId } else { $inspection.BundleId }

Write-Host ''
Write-Host '  重签准备' -ForegroundColor Cyan
Write-Host ('  ' + ('─' * 60)) -ForegroundColor DarkGray
Write-Host ("  输入        {0}" -f (Split-Path -Leaf $inputPath))
Write-Host ("  版本        {0} ({1})" -f $inspection.ShortVersion, $inspection.BuildVersion)
Write-Host ("  Bundle ID   {0}" -f $appBundleId)
Write-Host ("  架构        {0}" -f $(if ($inspection.Architectures.Count) { $inspection.Architectures -join ', ' } else { '(未识别)' }))
if ($inspection.HasProfile) {
    Write-Host '  原签名      已剥离（会整体替换）' -ForegroundColor DarkGray
}

# ── 3. 证书与描述文件 ─────────────────────────────────────────
$arguments = New-Object System.Collections.Generic.List[string]
$masked = New-Object System.Collections.Generic.List[string]

if ($AdHoc) {
    Write-Host '  签名方式    Ad Hoc 无证书（仅越狱 / TrollStore）' -ForegroundColor Yellow
    $arguments.Add('-z')
    $masked.Add('-z')
}
else {
    if (-not $P12) { Fail '缺少 -P12（或用 -AdHoc 走无证书签名）' }
    if (-not $Profile) { Fail '缺少 -Profile（.mobileprovision 决定有效期与可安装设备）' }
    if (-not (Test-Path -LiteralPath $P12)) { Fail "证书不存在：$P12" }
    if (-not (Test-Path -LiteralPath $Profile)) { Fail "描述文件不存在：$Profile" }

    if (-not $Password) {
        if ($PasswordFile -and (Test-Path -LiteralPath $PasswordFile)) {
            $Password = (Get-Content -LiteralPath $PasswordFile -Raw).Trim()
        }
        elseif ($env:AURORA_P12_PASSWORD) {
            $Password = $env:AURORA_P12_PASSWORD
        }
        else {
            Write-Host '  证书口令    未提供，按空口令尝试（.p12 通常有口令）' -ForegroundColor Yellow
            $Password = ''
        }
    }

    $profileReport = Show-ProvisionSummary -Path $Profile
    if ($profileReport.Expired -and -not $AllowExpired) {
        Fail "描述文件已于 $($profileReport.ExpiresUtc.ToString('yyyy-MM-dd')) 过期。请到开发者后台重新生成，或加 -AllowExpired 强行继续。"
    }
    if ($profileReport.Kind -like 'App Store*') {
        Fail '这是 App Store 描述文件，不能用于自签侧载。请改用 Ad Hoc 或 Development。'
    }

    # AppID 与 Bundle ID 一致性：这是侧载失败最常见的原因
    $pattern = if ($profileReport.AppId) { ([string]$profileReport.AppId -split '\.', 2)[1] } else { $null }
    if ($pattern -and $pattern -ne '*') {
        $matchesId = if ($pattern.Contains('*')) {
            $appBundleId.StartsWith($pattern.TrimEnd('*'), [System.StringComparison]::OrdinalIgnoreCase)
        }
        else {
            $pattern -eq $appBundleId
        }
        if (-not $matchesId) {
            Fail "描述文件 AppID($pattern) 与 Bundle ID($appBundleId) 不匹配。改 -BundleId，或换一份描述文件。"
        }
    }

    if ($profileReport.DeviceCount -eq 0 -and $profileReport.Kind -like 'Ad Hoc*') {
        Write-Host '  ! 描述文件里没有任何设备 UDID，装到手机上会被拒。' -ForegroundColor Yellow
    }

    $arguments.Add('-k'); $arguments.Add((Resolve-Path -LiteralPath $P12).Path); $masked.Add('-k'); $masked.Add((Split-Path -Leaf $P12))
    $arguments.Add('-p'); $arguments.Add($Password); $masked.Add('-p'); $masked.Add('********')
    $arguments.Add('-m'); $arguments.Add((Resolve-Path -LiteralPath $Profile).Path); $masked.Add('-m'); $masked.Add((Split-Path -Leaf $Profile))
}

if ($BundleId) { $arguments.Add('-b'); $arguments.Add($BundleId); $masked.Add('-b'); $masked.Add($BundleId) }
if ($DisplayName) { $arguments.Add('-n'); $arguments.Add($DisplayName); $masked.Add('-n'); $masked.Add($DisplayName) }
if ($Entitlements) {
    if (-not (Test-Path -LiteralPath $Entitlements)) { Fail "entitlements 不存在：$Entitlements" }
    $arguments.Add('-d'); $arguments.Add((Resolve-Path -LiteralPath $Entitlements).Path)
    $masked.Add('-d'); $masked.Add((Split-Path -Leaf $Entitlements))
}

$arguments.Add('-o'); $arguments.Add($outPath); $masked.Add('-o'); $masked.Add((Split-Path -Leaf $outPath))
$arguments.Add($inputPath); $masked.Add((Split-Path -Leaf $inputPath))

Write-Host ("  签名器      {0}" -f $signer)
Write-Host ("  输出        {0}" -f (Split-Path -Leaf $outPath))
Write-Host ('  ' + ('─' * 60)) -ForegroundColor DarkGray
Write-Host ''
Write-Host ('  zsign ' + ($masked -join ' ')) -ForegroundColor DarkGray
Write-Host ''

if ($DryRun) {
    Write-Host '  （-DryRun：未执行）' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

# ── 4. 执行 ───────────────────────────────────────────────────
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$output = & $signer @arguments 2>&1
$code = $LASTEXITCODE
$sw.Stop()

if ($output) { $output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }

if ($code -ne 0 -or -not (Test-Path -LiteralPath $outPath)) {
    Fail "签名失败（退出码 $code）。常见原因：p12 口令错、描述文件与证书不是同一 Team、entitlements 冲突。"
}

Write-Host ''
Write-Host ("  ✓ 签名完成 · {0:N1} MB · {1:N1}s" -f ((Get-Item -LiteralPath $outPath).Length / 1MB), $sw.Elapsed.TotalSeconds) -ForegroundColor Green

# ── 5. 体检 ───────────────────────────────────────────────────
if (-not $NoVerify) {
    & (Join-Path $PSScriptRoot 'verify-ipa.ps1') -Ipa $outPath
}

Write-Host '  下一步' -ForegroundColor Cyan
Write-Host ('  ' + ('─' * 60)) -ForegroundColor DarkGray
Write-Host '  1) AirDrop / 文件 App 传到 iPhone，点开即装（需信任描述文件）'
Write-Host '  2) 或本地起服务：node server/index.js 后从手机浏览器下载'
Write-Host '  3) 首次安装后到「设置 → 通用 → VPN与设备管理」信任该描述文件'
Write-Host '  4) 描述文件到期前用同一条命令重签（不用重新编译、不用重装 App）'
Write-Host ''
