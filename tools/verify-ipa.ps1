# tools/verify-ipa.ps1 — 交付前体检：结构 / 架构 / 描述文件 / 签名目录 / Bundle ID 一致性
#
#   pwsh tools/verify-ipa.ps1 -Ipa dist/Aurora-1.4.0-1-signed.ipa
#   pwsh tools/verify-ipa.ps1 -Ipa x.ipa -ExpectBundleId com.yg.aurora -Strict
#
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Ipa,

    [string]$ExpectBundleId,

    # 有任何 problem 时返回非零退出码
    [switch]$Strict,

    # 输出 JSON，便于流水线消费
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/IpaInspect.ps1')

$report = Test-Ipa -Path $Ipa -ExpectBundleId $ExpectBundleId

if ($AsJson) {
    $report | ConvertTo-Json -Depth 6
    if ($Strict -and -not $report.Ok) { exit 1 }
    exit 0
}

function Write-Row([string]$Label, $Value, [string]$Color = 'Gray') {
    Write-Host ("  {0,-12} {1}" -f $Label, $Value) -ForegroundColor $Color
}

Write-Host ''
Write-Host '  IPA 体检' -ForegroundColor Cyan
Write-Host ('  ' + ('─' * 60)) -ForegroundColor DarkGray
Write-Row '文件' (Split-Path -Leaf $report.Path)
Write-Row '体积' $(if ($report.SizeBytes -ge 1MB) { "{0:N2} MB" -f ($report.SizeBytes / 1MB) } else { "{0:N0} KB" -f ($report.SizeBytes / 1KB) })
Write-Row 'bundle' $report.BundleId
Write-Row '版本' ("{0} ({1})" -f $report.ShortVersion, $report.BuildVersion)
Write-Row '最低系统' $report.MinimumOS
Write-Row '包内目录' $report.AppFolder
Write-Row '可执行' $report.Executable
Write-Row '架构' $(if ($report.Architectures.Count) { $report.Architectures -join ', ' } else { '(未识别)' })
Write-Row '内嵌框架' $report.Frameworks

if ($report.Profile) {
    Write-Host ('  ' + ('─' * 60)) -ForegroundColor DarkGray
    Write-Row '签名类型' $report.Profile.Kind 'White'
    Write-Row '可安装于' $report.Profile.Installable
    Write-Row 'TeamID' $report.Profile.TeamId
    Write-Row 'AppID' $report.Profile.AppId
    if ($report.Profile.ExpiresUtc) {
        $color = if ($report.Profile.DaysLeft -lt 0) { 'Red' } elseif ($report.Profile.DaysLeft -lt 10) { 'Yellow' } else { 'Green' }
        Write-Row '到期' ("{0:yyyy-MM-dd} · 剩 {1} 天" -f $report.Profile.ExpiresUtc, $report.Profile.DaysLeft) $color
    }
}

Write-Host ('  ' + ('─' * 60)) -ForegroundColor DarkGray
Write-Row '代码签名' $(if ($report.HasCodeSig) { '✓ _CodeSignature 完整' } else { '✗ 缺失' }) $(if ($report.HasCodeSig) { 'Green' } else { 'Red' })

foreach ($warning in $report.Warnings) {
    Write-Host ("  ! {0}" -f $warning) -ForegroundColor Yellow
}
foreach ($problem in $report.Problems) {
    Write-Host ("  ✗ {0}" -f $problem) -ForegroundColor Red
}

Write-Host ''
if ($report.Ok) {
    Write-Host '  ✓ 通过：可以安装' -ForegroundColor Green
    if ($report.Profile -and $report.Profile.Kind -like 'Ad Hoc*') {
        Write-Host '    装到手机上需要该设备 UDID 已登记在这份描述文件里。' -ForegroundColor DarkGray
    }
    if ($report.Profile -and $report.Profile.DaysLeft -ne $null -and $report.Profile.DaysLeft -lt 10) {
        Write-Host ('    到期前 {0} 天需要重签（zsign 重签不需要重新编译）。' -f $report.Profile.DaysLeft) -ForegroundColor Yellow
    }
}
else {
    Write-Host '  ✗ 未通过：先修掉上面的 problem 再分发' -ForegroundColor Red
}
Write-Host ''

if ($Strict -and -not $report.Ok) { exit 1 }
exit 0
