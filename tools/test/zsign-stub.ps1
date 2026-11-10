<#
  测试替身：模拟 zsign 的参数契约
    zsign -k a.p12 -p pass -m b.mobileprovision [-b id] [-n name] [-d ent] -o out.ipa in.ipa
  只做一件事：把输入文件复制到 -o 指定的输出位置，用于验证 resign.ps1 的参数装配与后续体检。
#>
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)

$out = $null
$rest = @($Rest)
for ($i = 0; $i -lt $rest.Count; $i++) {
    if ($rest[$i] -eq '-o' -and $i + 1 -lt $rest.Count) { $out = $rest[$i + 1] }
}

$input = $rest[$rest.Count - 1]
if (-not $out) { Write-Host 'stub: 缺少 -o'; exit 2 }
if (-not (Test-Path -LiteralPath $input)) { Write-Host "stub: 输入不存在 $input"; exit 3 }

Copy-Item -LiteralPath $input -Destination $out -Force
Write-Host "stub: signed $([System.IO.Path]::GetFileName($input)) → $([System.IO.Path]::GetFileName($out))"
exit 0
