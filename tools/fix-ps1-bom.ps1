# tools/fix-ps1-bom.ps1 — 给所有 .ps1 补 UTF-8 BOM
#
# 为什么需要：Windows PowerShell 5.1 会按系统 ANSI 代码页读取无 BOM 的 .ps1，
# 脚本里的中文会变成乱码进而破坏语法。改完脚本后跑一次这个即可。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/fix-ps1-bom.ps1
#
[CmdletBinding()]
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$bom = [byte[]](0xEF, 0xBB, 0xBF)
$fixed = 0
$skipped = 0

foreach ($file in (Get-ChildItem -LiteralPath $Root -Recurse -Filter *.ps1 -File)) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if ($hasBom) {
        $skipped++
        continue
    }
    $merged = New-Object byte[] ($bytes.Length + 3)
    [Array]::Copy($bom, 0, $merged, 0, 3)
    [Array]::Copy($bytes, 0, $merged, 3, $bytes.Length)
    [System.IO.File]::WriteAllBytes($file.FullName, $merged)
    Write-Host ("  +BOM {0}" -f $file.FullName.Substring($Root.Length + 1))
    $fixed++
}

Write-Host ''
Write-Host ("  已补 {0} 个，跳过 {1} 个（本来就有 BOM）" -f $fixed, $skipped)
Write-Host ''
