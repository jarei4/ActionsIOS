# tools/bump-version.ps1 — 单一版本源 → 同步到 iOS 工程 / 后端 / CHANGELOG
#
#   powershell -NoProfile -File tools/bump-version.ps1 -Bump patch -Note "修复登录卡顿"
#   powershell -NoProfile -File tools/bump-version.ps1 -Bump minor -Note "新增离线缓存" -Commit
#
# 版本号的唯一来源是 version.json：
#   · iOS 用 MARKETING_VERSION / CURRENT_PROJECT_VERSION 引用（Info.plist 是 $(...) 变量）
#   · 后端 package.json 与 /api/version 走同一个值
#
[CmdletBinding()]
param(
    [ValidateSet('major', 'minor', 'patch', 'none')]
    [string]$Bump = 'patch',

    # 显式指定 build 号；默认自增
    [int]$Build = 0,

    # CHANGELOG 条目说明
    [string]$Note = '',

    # 同步后直接 git commit + tag
    [switch]$Commit,

    # 只预览不落盘
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Read-Json([string]$Path) {
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-Utf8([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

$versionFile = Join-Path $root 'version.json'
$meta = Read-Json $versionFile

$current = [version]$meta.version
$major = $current.Major
$minor = $current.Minor
$patch = $current.Build

switch ($Bump) {
    'major' { $major++; $minor = 0; $patch = 0 }
    'minor' { $minor++; $patch = 0 }
    'patch' { $patch++ }
    'none' { }
}

$newVersion = "$major.$minor.$patch"
$newBuild = if ($Build -gt 0) { $Build } else { [int]$meta.build + 1 }

Write-Host ''
Write-Host '  版本递增' -ForegroundColor Cyan
Write-Host ('  ' + ('─' * 52)) -ForegroundColor DarkGray
Write-Host ("  {0} ({1})  →  {2} ({3})" -f $meta.version, $meta.build, $newVersion, $newBuild)

if ($DryRun) {
    Write-Host '  （-DryRun：未落盘）' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

# ── 1. version.json ──────────────────────────────────────────
$meta.version = $newVersion
$meta.build = $newBuild
Write-Utf8 $versionFile (($meta | ConvertTo-Json -Depth 6) + "`n")
Write-Host '  ✓ version.json'

# ── 2. 后端 package.json ─────────────────────────────────────
$pkgPath = Join-Path $root 'package.json'
if (Test-Path -LiteralPath $pkgPath) {
    $pkg = Read-Json $pkgPath
    $pkg.version = $newVersion
    Write-Utf8 $pkgPath (($pkg | ConvertTo-Json -Depth 8) + "`n")
    Write-Host '  ✓ package.json'
}

# ── 3. Xcode 工程（Info.plist 用变量，无需改动） ──────────────
$pbxPath = Join-Path $root 'ios/AuroraApp.xcodeproj/project.pbxproj'
if (Test-Path -LiteralPath $pbxPath) {
    $pbx = [System.IO.File]::ReadAllText($pbxPath, [System.Text.Encoding]::UTF8)
    $pbx = [regex]::Replace($pbx, 'MARKETING_VERSION = [^;]+;', "MARKETING_VERSION = $newVersion;")
    $pbx = [regex]::Replace($pbx, 'CURRENT_PROJECT_VERSION = [^;]+;', "CURRENT_PROJECT_VERSION = $newBuild;")
    Write-Utf8 $pbxPath $pbx
    Write-Host '  ✓ project.pbxproj (MARKETING_VERSION / CURRENT_PROJECT_VERSION)'
}

# ── 4. 构建标记（后端 /api/version 的 build 字段） ────────────
$buildFile = Join-Path $root 'tools/.build'
New-Item -ItemType Directory -Path (Split-Path -Parent $buildFile) -Force | Out-Null
Write-Utf8 $buildFile $newBuild
Write-Host '  ✓ tools/.build'

# ── 5. CHANGELOG ─────────────────────────────────────────────
$changelog = Join-Path $root 'CHANGELOG.md'
$entry = @()
$entry += "## [$newVersion] - $((Get-Date).ToString('yyyy-MM-dd'))  ·  build $newBuild"
$entry += ''
if ($Note) {
    foreach ($line in ($Note -split "`n")) { $entry += "- $($line.Trim())" }
}
else {
    $entry += '- （未填写说明）'
}
$entry += ''

if (Test-Path -LiteralPath $changelog) {
    $existing = [System.IO.File]::ReadAllText($changelog, [System.Text.Encoding]::UTF8)
    $marker = '<!-- entries -->'
    if ($existing.Contains($marker)) {
        $parts = $existing -split [regex]::Escape($marker), 2
        $merged = $parts[0] + $marker + "`n`n" + ($entry -join "`n") + "`n" + $parts[1]
    }
    else {
        $merged = $existing.TrimEnd() + "`n`n" + ($entry -join "`n")
    }
    Write-Utf8 $changelog $merged
}
else {
    $header = "# 变更记录`n`n<!-- entries -->`n`n" + ($entry -join "`n")
    Write-Utf8 $changelog $header
}
Write-Host '  ✓ CHANGELOG.md'

Write-Host ('  ' + ('─' * 52)) -ForegroundColor DarkGray

if ($Commit) {
    git -C $root add -A
    git -C $root commit -m "chore(release): v$newVersion ($newBuild)"
    if ($LASTEXITCODE -eq 0) {
        git -C $root tag -a "v$newVersion" -m "v$newVersion build $newBuild"
        Write-Host "  ✓ 已提交并打标签 v$newVersion"
    }
    else {
        Write-Host '  ! git 提交失败（先 git init / 配置 user.name）' -ForegroundColor Yellow
    }
}
else {
    Write-Host '  下一步：' -ForegroundColor DarkGray
    Write-Host "    git add -A && git commit -m `"chore(release): v$newVersion`"" -ForegroundColor DarkGray
    Write-Host "    git tag -a v$newVersion -m `"v$newVersion build $newBuild`"" -ForegroundColor DarkGray
}

Write-Host ''
