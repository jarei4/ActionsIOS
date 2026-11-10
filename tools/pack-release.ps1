# tools/pack-release.ps1 — 打包成可直接传输的 zip（正斜杠路径，Mac/手机都能正确解压）
#
#   powershell -NoProfile -File tools/pack-release.ps1
#   powershell -NoProfile -File tools/pack-release.ps1 -Out D:\deliver\Aurora-1.4.0.zip -WithSecrets
#
# 默认不打包签名材料（p12 / mobileprovision / 口令 / data），
# 那些东西只在你自己机器上流转。
#
[CmdletBinding()]
param(
    [string]$Out,
    # 把 signing/ 里的证书与描述文件也打进去（仅用于本机备份，别发给别人）
    [switch]$WithSecrets,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }
$root = Split-Path -Parent $PSScriptRoot
$meta = Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $Out) {
    $Out = Join-Path (Join-Path (Split-Path -Parent $root) 'deliver') "Aurora-$($meta.version)-$($meta.build).zip"
}
$outFull = [System.IO.Path]::GetFullPath($Out)
$outDir = Split-Path -Parent $outFull
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if ((Test-Path -LiteralPath $outFull) -and -not $Force) {
    throw "输出已存在：$outFull（加 -Force 覆盖）"
}

# 排除规则：依赖、产物、运行期数据、签名材料、个人 Xcode 设置
$excludeDirs = @('node_modules', 'build', 'dist', 'DerivedData', '.git', 'data', 'out')
$excludeFiles = @('*.db', '*.db-wal', '*.db-shm', '.env', '.secret', '*.log')
$secretFiles = @('*.p12', '*.pfx', '*.cer', '*.mobileprovision', '*.provisionprofile', 'pass*.txt')

$secretPath = if ($WithSecrets) { Join-Path $root 'signing/secrets' } else { $null }
if ($WithSecrets) {
    Write-Host '  ! -WithSecrets：证书与描述文件会被打进这个包，只用于本机备份' -ForegroundColor Yellow
}

$files = New-Object System.Collections.Generic.List[object]
$stack = New-Object System.Collections.Generic.Stack[string]
$stack.Push($root)

while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    foreach ($entry in (Get-ChildItem -LiteralPath $dir -Force)) {
        $relative = $entry.FullName.Substring($root.Length + 1)
        if ($relative -match '\\\.acl-recovery') { continue }

        if ($entry.PSIsContainer) {
            if ($excludeDirs -contains $entry.Name) { continue }
            if (-not $WithSecrets -and $entry.Name -eq 'test' -and $dir -match '\\tools$') { continue }
            $stack.Push($entry.FullName)
            continue
        }

        $skip = $false
        foreach ($pattern in $excludeFiles) { if ($entry.Name -like $pattern) { $skip = $true } }
        if (-not $WithSecrets) {
            foreach ($pattern in $secretFiles) { if ($entry.Name -like $pattern) { $skip = $true } }
        }
        if (-not $WithSecrets -and $relative -like 'signing\secrets*') { $skip = $true }
        if ($relative -like 'tools\test\out*') { $skip = $true }
        if ($skip) { continue }

        $files.Add([pscustomobject]@{ Full = $entry.FullName; Relative = ($relative -replace '\\', '/') })
    }
}

if (Test-Path -LiteralPath $outFull) { Remove-Item -LiteralPath $outFull -Force }

$fileStream = [System.IO.File]::Open($outFull, [System.IO.FileMode]::Create)
$zip = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        # 全部放同一个根目录下，解压不会污染目标位置
        $entryName = "Aurora-$($meta.version)/$($file.Relative)"
        $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = (Get-Item -LiteralPath $file.Full).LastWriteTime
        $stream = $entry.Open()
        try {
            $bytes = [System.IO.File]::ReadAllBytes($file.Full)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $stream.Dispose()
        }
    }
}
finally {
    $zip.Dispose()
    $fileStream.Dispose()
}

$sizeMb = [math]::Round((Get-Item -LiteralPath $outFull).Length / 1MB, 2)
Write-Host ''
Write-Host ("  ✓ 打包完成  {0}" -f $outFull) -ForegroundColor Green
Write-Host ("    {0} 个文件 · {1} MB · 根目录 Aurora-{2}/" -f $files.Count, $sizeMb, $meta.version)
Write-Host ''
Write-Host '  其中签名材料：' -ForegroundColor DarkGray
$leaked = @($files | Where-Object { $_.Relative -match '\.(p12|mobileprovision|pfx)$' })
Write-Host ("    {0}" -f $(if ($leaked.Count) { "包含 $($leaked.Count) 个（-WithSecrets 开启）" } else { '无（证书/描述文件/口令已排除）' })) -ForegroundColor DarkGray
Write-Host ''
