# tools/test-signing-tools.ps1 — 用合成样本自检签名工具链（无需真机/真证书）
#
#   pwsh tools/test-signing-tools.ps1
#
# 覆盖：描述文件解析（含过期判定）、IPA 结构体检、Bundle ID 一致性、损坏包识别、
#       binary plist 读取（用 Python plistlib 生成，交叉验证解析器）
#
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/IpaInspect.ps1')

$out = Join-Path $PSScriptRoot 'test/out'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null

$pass = 0
$fail = @()

function Assert-That([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) {
        $script:pass++
        Write-Host "  ✓ $Name" -ForegroundColor DarkGreen
    }
    else {
        $script:fail += "$Name $Detail"
        Write-Host "  ✗ $Name  $Detail" -ForegroundColor Red
    }
}

function New-Profile {
    param(
        [string]$Path,
        [int]$DaysFromNow = 300,
        [string]$AppId = 'ABCDE12345.com.yg.aurora',
        [int]$Devices = 2,
        [bool]$GetTaskAllow = $false,
        [bool]$AllDevices = $false
    )

    $expiry = [datetime]::UtcNow.AddDays($DaysFromNow).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $created = [datetime]::UtcNow.AddDays(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')

    $deviceXml = ''
    if ($Devices -gt 0) {
        $ids = @()
        for ($i = 0; $i -lt $Devices; $i++) {
            $ids += "00008030-000A1B2C3D4E5F6$i"
        }
        $deviceXml = "<key>ProvisionedDevices</key><array>" + ($ids | ForEach-Object { "<string>$_</string>" }) + '</array>'
    }

    $allXml = if ($AllDevices) { '<key>ProvisionsAllDevices</key><true/>' } else { '' }
    $gte = if ($GetTaskAllow) { '<true/>' } else { '<false/>' }

    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AppIDName</key><string>Aurora</string>
	<key>CreationDate</key><date>$created</date>
	<key>ExpirationDate</key><date>$expiry</date>
	<key>Name</key><string>Aurora Test Profile</string>
	<key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
	<key>TeamName</key><string>YG Studio</string>
	<key>TimeToLive</key><integer>365</integer>
	<key>UUID</key><string>11111111-2222-3333-4444-555555555555</string>
	<key>Version</key><integer>1</integer>
	<key>Platform</key><array><string>iOS</string></array>
	$deviceXml
	$allXml
	<key>Entitlements</key>
	<dict>
		<key>application-identifier</key><string>$AppId</string>
		<key>com.apple.developer.team-identifier</key><string>ABCDE12345</string>
		<key>get-task-allow</key>$gte
		<key>keychain-access-groups</key><array><string>ABCDE12345.*</string></array>
	</dict>
</dict>
</plist>
"@

    # 真实的 .mobileprovision 是 CMS 包裹：前后都有二进制，中间是明文 plist
    $prefix = [byte[]](0x30, 0x82, 0x12, 0x34, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07)
    $suffix = [byte[]](0x00, 0xa2, 0x82, 0x12, 0x34, 0xff, 0xee)
    $body = [System.Text.Encoding]::UTF8.GetBytes($xml)
    $all = New-Object byte[] ($prefix.Length + $body.Length + $suffix.Length)
    [Array]::Copy($prefix, 0, $all, 0, $prefix.Length)
    [Array]::Copy($body, 0, $all, $prefix.Length, $body.Length)
    [Array]::Copy($suffix, 0, $all, $prefix.Length + $body.Length, $suffix.Length)
    [System.IO.File]::WriteAllBytes($Path, $all)
}

function New-BinaryInfoPlist {
    param(
        [string]$Path,
        [string]$BundleId = 'com.yg.aurora',
        [string]$ShortVersion = '1.4.0',
        [string]$Build = '1'
    )

    $python = 'C:\Users\12854\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
    if (-not (Test-Path -LiteralPath $python)) {
        $python = 'python'
    }

    $script = @'
import plistlib, sys
info = {
    "CFBundleIdentifier": sys.argv[2],
    "CFBundleExecutable": "AuroraApp",
    "CFBundleName": "AuroraApp",
    "CFBundleDisplayName": "极光",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": sys.argv[3],
    "CFBundleVersion": sys.argv[4],
    "MinimumOSVersion": "16.0",
    "UILaunchScreen": {},
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
    "API_BASE_URL": "http://192.168.1.10:8787",
    "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
    "ITSAppUsesNonExemptEncryption": False,
}
with open(sys.argv[1], "wb") as f:
    plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)
'@
    $scriptPath = Join-Path $out '_bplist.py'
    [System.IO.File]::WriteAllText($scriptPath, $script)
    & $python $scriptPath $Path $BundleId $ShortVersion $Build | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '生成 binary Info.plist 失败' }
}

function New-FakeApp {
    param(
        [string]$Root,
        [string]$ProfilePath,
        [bool]$WithSignature = $true,
        [string]$BundleId = 'com.yg.aurora'
    )

    $appDir = Join-Path $Root 'Payload/AuroraApp.app'
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null

    New-BinaryInfoPlist -Path (Join-Path $appDir 'Info.plist') -BundleId $BundleId
    [System.IO.File]::WriteAllText((Join-Path $appDir 'PkgInfo'), 'APPL????')

    # 伪造 arm64 Mach-O 头：magic CF FA ED FE + cputype 0x0100000C + subtype 2(arm64e) 
    $macho = [byte[]](0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0x02, 0x00, 0x00, 0x00,
                      0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
    $big = New-Object byte[] (512 * 1024)
    [Array]::Copy($macho, 0, $big, 0, $macho.Length)
    [System.IO.File]::WriteAllBytes((Join-Path $appDir 'AuroraApp'), $big)

    if ($WithSignature) {
        $sigDir = Join-Path $appDir '_CodeSignature'
        New-Item -ItemType Directory -Path $sigDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sigDir 'CodeResources'), '<plist><dict/></plist>')
    }

    if ($ProfilePath) {
        Copy-Item -LiteralPath $ProfilePath -Destination (Join-Path $appDir 'embedded.mobileprovision')
    }

    return $appDir
}

function Compress-Ipa {
    <#
      手写 zip 条目名，确保用正斜杠 —— 与真实 IPA 一致。
      （.NET Framework 的 ZipFile.CreateFromDirectory 会写成反斜杠，那样 iOS 装不上）
    #>
    param([string]$Root, [string]$Ipa)

    if (Test-Path -LiteralPath $Ipa) { Remove-Item -LiteralPath $Ipa -Force }
    $fileStream = [System.IO.File]::Open($Ipa, [System.IO.FileMode]::Create)
    $zip = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $rootFull = (Resolve-Path -LiteralPath $Root).Path
        foreach ($file in (Get-ChildItem -LiteralPath $rootFull -Recurse -File)) {
            $relative = $file.FullName.Substring($rootFull.Length + 1) -replace '\\', '/'
            $entry = $zip.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
                $entryStream.Write($bytes, 0, $bytes.Length)
            }
            finally {
                $entryStream.Dispose()
            }
        }
    }
    finally {
        $zip.Dispose()
        $fileStream.Dispose()
    }
}

Write-Host ''
Write-Host '签名工具链自检' -ForegroundColor Cyan
Write-Host ('─' * 62) -ForegroundColor DarkGray

# ── 1. 描述文件解析 ───────────────────────────────────────────
$profileOk = Join-Path $out 'adhoc.mobileprovision'
New-Profile -Path $profileOk -DaysFromNow 300 -Devices 2

$summary = Show-ProvisionSummary -Path $profileOk -Quiet
Assert-That '描述文件：判为 Ad Hoc' ($summary.Kind -like 'Ad Hoc*') "实际 $($summary.Kind)"
Assert-That '描述文件：TeamID 解析' ($summary.TeamId -eq 'ABCDE12345') "实际 $($summary.TeamId)"
Assert-That '描述文件：AppID 解析' ($summary.AppId -eq 'ABCDE12345.com.yg.aurora') "实际 $($summary.AppId)"
Assert-That '描述文件：设备数 2' ($summary.DeviceCount -eq 2) "实际 $($summary.DeviceCount)"
Assert-That '描述文件：剩余天数约 300' ([math]::Abs($summary.DaysLeft - 300) -le 1) "实际 $($summary.DaysLeft)"
Assert-That '描述文件：未过期' (-not $summary.Expired)

$profileDev = Join-Path $out 'dev.mobileprovision'
New-Profile -Path $profileDev -DaysFromNow 5 -Devices 1 -GetTaskAllow $true
$devSummary = Show-ProvisionSummary -Path $profileDev -Quiet
Assert-That '开发描述文件：判为 Development' ($devSummary.Kind -like 'Development*') "实际 $($devSummary.Kind)"
Assert-That '开发描述文件：5 天内到期' ($devSummary.DaysLeft -ge 3 -and $devSummary.DaysLeft -le 5) "实际 $($devSummary.DaysLeft)"
Assert-That '开发描述文件：状态给出告警' ($devSummary.State -match '即将过期') "实际 $($devSummary.State)"

$profileExpired = Join-Path $out 'expired.mobileprovision'
New-Profile -Path $profileExpired -DaysFromNow -3 -Devices 1
$expiredSummary = Show-ProvisionSummary -Path $profileExpired -Quiet
Assert-That '过期描述文件：被识别为过期' ($expiredSummary.Expired -eq $true)
Assert-That '过期描述文件：剩余为负' ($expiredSummary.DaysLeft -lt 0)

$profileEnterprise = Join-Path $out 'enterprise.mobileprovision'
New-Profile -Path $profileEnterprise -DaysFromNow 200 -Devices 0 -AllDevices $true
$entSummary = Show-ProvisionSummary -Path $profileEnterprise -Quiet
Assert-That '企业描述文件：判为 In-House' ($entSummary.Kind -like 'In-House*') "实际 $($entSummary.Kind)"

$profileAppStore = Join-Path $out 'appstore.mobileprovision'
New-Profile -Path $profileAppStore -DaysFromNow 200 -Devices 0
$asSummary = Show-ProvisionSummary -Path $profileAppStore -Quiet
Assert-That 'App Store 描述文件：判为 App Store' ($asSummary.Kind -like 'App Store*') "实际 $($asSummary.Kind)"

# ── 2. binary plist 交叉验证 ──────────────────────────────────
$plistProbe = Join-Path $out 'probe.plist'
New-BinaryInfoPlist -Path $plistProbe -BundleId 'com.yg.aurora' -ShortVersion '1.4.0' -Build '7'
$parsed = Read-PlistFile -Path $plistProbe
Assert-That 'binary plist：识别 Bundle ID' ((Get-PlistValue $parsed 'CFBundleIdentifier') -eq 'com.yg.aurora')
Assert-That 'binary plist：识别版本号' ((Get-PlistValue $parsed 'CFBundleShortVersionString') -eq '1.4.0')
Assert-That 'binary plist：识别布尔值' ((Get-PlistValue $parsed 'ITSAppUsesNonExemptEncryption') -eq $false)
Assert-That 'binary plist：识别嵌套字典' ((Get-PlistValue (Get-PlistValue $parsed 'NSAppTransportSecurity') 'NSAllowsArbitraryLoads') -eq $true)
Assert-That 'binary plist：识别数组' (@(Get-PlistValue $parsed 'UISupportedInterfaceOrientations').Count -eq 1)

# ── 3. 完整 IPA 体检 ──────────────────────────────────────────
$goodRoot = Join-Path $out 'good'
New-Item -ItemType Directory -Path $goodRoot -Force | Out-Null
$null = New-FakeApp -Root $goodRoot -ProfilePath $profileOk
$goodIpa = Join-Path $out 'Aurora-good.ipa'
Compress-Ipa -Root $goodRoot -Ipa $goodIpa

$report = Test-Ipa -Path $goodIpa -ExpectBundleId 'com.yg.aurora'
Assert-That 'IPA：结构通过' ($report.Ok) ($report.Problems -join '; ')
Assert-That 'IPA：读出 Bundle ID' ($report.BundleId -eq 'com.yg.aurora')
Assert-That 'IPA：读出架构为 arm64e' ($report.Architectures -contains 'arm64e') ($report.Architectures -join ', ')
Assert-That 'IPA：识别代码签名目录' ($report.HasCodeSig)
Assert-That 'IPA：识别内嵌描述文件' ($report.HasProfile)
Assert-That 'IPA：内嵌描述文件未过期' (-not $report.Profile.Expired)

# ── 4. 故障注入 ───────────────────────────────────────────────
$noSigRoot = Join-Path $out 'nosig'
New-Item -ItemType Directory -Path $noSigRoot -Force | Out-Null
$null = New-FakeApp -Root $noSigRoot -ProfilePath $profileOk -WithSignature $false
$noSigIpa = Join-Path $out 'Aurora-nosig.ipa'
Compress-Ipa -Root $noSigRoot -Ipa $noSigIpa
$noSigReport = Test-Ipa -Path $noSigIpa
Assert-That '无签名包：被判定不合格' (-not $noSigReport.Ok)
Assert-That '无签名包：指出缺 _CodeSignature' (($noSigReport.Problems -join ' ') -match '_CodeSignature')

$mismatchRoot = Join-Path $out 'mismatch'
New-Item -ItemType Directory -Path $mismatchRoot -Force | Out-Null
$null = New-FakeApp -Root $mismatchRoot -ProfilePath $profileOk -BundleId 'com.other.app'
$mismatchIpa = Join-Path $out 'Aurora-mismatch.ipa'
Compress-Ipa -Root $mismatchRoot -Ipa $mismatchIpa
$mismatchReport = Test-Ipa -Path $mismatchIpa
Assert-That 'AppID 不匹配：被拦住' (($mismatchReport.Problems -join ' ') -match '不匹配')

$expiredRoot = Join-Path $out 'expired'
New-Item -ItemType Directory -Path $expiredRoot -Force | Out-Null
$null = New-FakeApp -Root $expiredRoot -ProfilePath $profileExpired
$expiredIpa = Join-Path $out 'Aurora-expired.ipa'
Compress-Ipa -Root $expiredRoot -Ipa $expiredIpa
$expiredReport = Test-Ipa -Path $expiredIpa
Assert-That '过期签名包：被拦住' (($expiredReport.Problems -join ' ') -match '已过期')

$junkIpa = Join-Path $out 'Aurora-junk.ipa'
[System.IO.File]::WriteAllText($junkIpa, 'not a zip at all')
$junkReport = Test-Ipa -Path $junkIpa
Assert-That '非 zip 文件：被识别' (($junkReport.Problems -join ' ') -match '不是有效的')

$emptyRoot = Join-Path $out 'empty'
New-Item -ItemType Directory -Path (Join-Path $emptyRoot 'Payload') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $emptyRoot 'Payload/readme.txt'), 'x')
$emptyIpa = Join-Path $out 'Aurora-empty.ipa'
Compress-Ipa -Root $emptyRoot -Ipa $emptyIpa
$emptyReport = Test-Ipa -Path $emptyIpa
Assert-That '空 Payload：被识别' (($emptyReport.Problems -join ' ') -match 'Payload')

Write-Host ('─' * 62) -ForegroundColor DarkGray
Write-Host ("  {0} 通过, {1} 失败" -f $pass, $fail.Count) -ForegroundColor $(if ($fail.Count) { 'Red' } else { 'Green' })
if ($fail.Count) {
    foreach ($item in $fail) { Write-Host "  FAIL $item" -ForegroundColor Red }
    Write-Host ''
    exit 1
}
Write-Host ''
Write-Host '  合成样本保留在 tools/test/out，可用于手工验证 CLI：' -ForegroundColor DarkGray
Write-Host '    pwsh tools/verify-ipa.ps1 -Ipa tools/test/out/Aurora-good.ipa' -ForegroundColor DarkGray
Write-Host '    pwsh tools/profile-report.ps1 -Profile tools/test/out/adhoc.mobileprovision' -ForegroundColor DarkGray
Write-Host ''
