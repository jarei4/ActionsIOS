# tools/profile-report.ps1 — 描述文件体检：类型、TeamID、AppID、到期倒计时
#
#   pwsh tools/profile-report.ps1 -Profile signing/Aurora.mobileprovision
#   pwsh tools/profile-report.ps1 -Profile x.mobileprovision -Strict   # 过期或 <10 天时以非零码退出
#
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Profile,

    # 到期前多少天开始告警
    [int]$WarnDays = 10,

    # 过期或即将过期时返回非零退出码，便于 CI / 脚本卡口
    [switch]$Strict,

    # 只输出键值对，便于管道处理
    [switch]$AsObject
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/PlistXml.ps1')

$report = Show-ProvisionSummary -Path $Profile -Quiet:$AsObject.IsPresent

if ($AsObject) {
    return $report
}

$exit = 0
if ($report.Expired) {
    Write-Host '  ✗ 描述文件已过期，必须重新生成后再签名。' -ForegroundColor Red
    $exit = 2
}
elseif ($null -ne $report.DaysLeft -and $report.DaysLeft -lt $WarnDays) {
    Write-Host ("  ! 只剩 {0} 天，建议现在就准备下一份描述文件。" -f $report.DaysLeft) -ForegroundColor Yellow
    $exit = 1
}
else {
    Write-Host ("  ✓ 有效期充足（{0} 天），可以放心分发。" -f $report.DaysLeft) -ForegroundColor Green
}

if ($report.Kind -like 'App Store*') {
    Write-Host '  ! 该描述文件不能用于自签侧载，请换 Ad Hoc 或 Development。' -ForegroundColor Yellow
    if ($exit -eq 0) { $exit = 1 }
}

if ($Strict -and $exit -ne 0) { exit $exit }
exit 0
