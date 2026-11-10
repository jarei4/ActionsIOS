# tools/lib/IpaInspect.ps1 — IPA 结构与签名体检（Windows 上可用，零外部依赖）
# 被 verify-ipa.ps1 / resign.ps1 点源引用

. (Join-Path $PSScriptRoot 'PlistXml.ps1')

# Windows PowerShell 5.1 需要显式加载；PowerShell 7 默认已含，失败可忽略
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }

function Read-LeUInt32 {
    param([byte[]]$Bytes, [int]$Offset)
    return ([uint32]$Bytes[$Offset]) -bor
           ([uint32]$Bytes[$Offset + 1] -shl 8) -bor
           ([uint32]$Bytes[$Offset + 2] -shl 16) -bor
           ([uint32]$Bytes[$Offset + 3] -shl 24)
}

function Read-BeUInt32 {
    param([byte[]]$Bytes, [int]$Offset)
    return ([uint32]$Bytes[$Offset] -shl 24) -bor
           ([uint32]$Bytes[$Offset + 1] -shl 16) -bor
           ([uint32]$Bytes[$Offset + 2] -shl 8) -bor
           ([uint32]$Bytes[$Offset + 3])
}

# Mach-O 魔数：必须用字节构造。
# Windows PowerShell 5.1 会把 0xFEEDFACF 这类超过 int32 的字面量折成负数，直接比较永远不相等。
$script:MagicThin64 = [System.BitConverter]::ToUInt32([byte[]](0xCF, 0xFA, 0xED, 0xFE), 0)
$script:MagicThin32 = [System.BitConverter]::ToUInt32([byte[]](0xCE, 0xFA, 0xED, 0xFE), 0)
$script:MagicFat32 = [System.BitConverter]::ToUInt32([byte[]](0xCA, 0xFE, 0xBA, 0xBE), 0)
$script:MagicFat64 = [System.BitConverter]::ToUInt32([byte[]](0xCA, 0xFE, 0xBA, 0xBF), 0)

function Get-MachOArchitectures {
    <# 返回架构名数组；非 Mach-O 返回 @() #>
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -lt 8) { return @() }

    $le = Read-LeUInt32 -Bytes $Bytes -Offset 0
    $names = New-Object System.Collections.ArrayList

    $cpuName = {
        param([uint32]$cpu, [uint32]$sub)
        switch ($cpu) {
            7 { 'i386' }
            0x01000007 { 'x86_64' }
            12 {
                if (($sub -band 0x00FFFFFF) -eq 9) { 'armv7s' } else { 'armv7' }
            }
            0x0100000C {
                if (($sub -band 0x00FFFFFF) -eq 2) { 'arm64e' } else { 'arm64' }
            }
            default { ('cpu0x{0:x}' -f $cpu) }
        }
    }

    if ($le -eq $script:MagicThin64 -or $le -eq $script:MagicThin32) {
        $cpu = Read-LeUInt32 -Bytes $Bytes -Offset 4
        $sub = Read-LeUInt32 -Bytes $Bytes -Offset 8
        [void]$names.Add((& $cpuName $cpu $sub))
    }
    elseif ($le -eq $script:MagicFat32 -or $le -eq $script:MagicFat64) {
        $count = [int](Read-BeUInt32 -Bytes $Bytes -Offset 4)
        $stride = if ($le -eq $script:MagicFat64) { 32 } else { 20 }
        if ($count -gt 0 -and $count -le 16) {
            for ($i = 0; $i -lt $count; $i++) {
                $base = 8 + $i * $stride
                if ($base + 12 -gt $Bytes.Length) { break }
                $cpu = Read-BeUInt32 -Bytes $Bytes -Offset $base
                $sub = Read-BeUInt32 -Bytes $Bytes -Offset ($base + 4)
                [void]$names.Add((& $cpuName $cpu $sub))
            }
        }
    }

    return @($names | Select-Object -Unique)
}

function Get-ZipEntryBytes {
    param($Archive, [string]$Name, $Map)

    $entry = $null
    if ($Map -and $Map.ContainsKey($Name)) {
        $entry = $Map[$Name]
    }
    else {
        $entry = $Archive.GetEntry($Name)
        if ($null -eq $entry) { $entry = $Archive.GetEntry(($Name -replace '/', '\')) }
    }
    if ($null -eq $entry) { return $null }
    $stream = $entry.Open()
    try {
        $memory = New-Object System.IO.MemoryStream
        $stream.CopyTo($memory)
        return $memory.ToArray()
    }
    finally {
        $stream.Dispose()
    }
}

function Read-PlistFromBytes {
    <# 落临时文件后复用统一解析（binary/XML 自动识别），读完即删 #>
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $temp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllBytes($temp, $Bytes)
        return Read-PlistFile -Path $temp
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Test-Ipa {
    <#
      .SYNOPSIS
        IPA 体检：结构、Info.plist、可执行文件架构、内嵌描述文件、代码签名目录。
      .OUTPUTS
        pscustomobject，含 Problems/Warnings 数组与 Ok 布尔。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectBundleId
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $problems = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList

    $full = (Resolve-Path -LiteralPath $Path).Path
    $size = (Get-Item -LiteralPath $full).Length

    $result = [ordered]@{
        Path          = $full
        SizeBytes     = $size
        AppFolder     = $null
        BundleId      = $null
        ShortVersion  = $null
        BuildVersion  = $null
        MinimumOS     = $null
        Executable    = $null
        Architectures = @()
        Frameworks    = 0
        HasCodeSig    = $false
        HasProfile    = $false
        Profile       = $null
        Problems      = @()
        Warnings      = @()
        Ok            = $false
    }

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($full)
    }
    catch {
        [void]$problems.Add("不是有效的 zip/ipa：$($_.Exception.Message)")
        $result.Problems = @($problems)
        $result.Warnings = @($warnings)
        return [pscustomobject]$result
    }

    try {
        # 部分 Windows 打包工具把分隔符写成反斜杠，这里统一成 / 再判断
        $entryMap = @{}
        foreach ($entry in $archive.Entries) {
            $entryMap[($entry.FullName -replace '\\', '/')] = $entry
        }
        $entryNames = @($entryMap.Keys)

        $appFolders = @(
            $entryNames |
                Where-Object { $_ -match '^Payload/[^/]+\.app/' } |
                ForEach-Object { (($_ -split '/')[0..1]) -join '/' } |
                Select-Object -Unique
        )

        if ($appFolders.Count -eq 0) {
            [void]$problems.Add('缺少 Payload/*.app 目录，这不是可安装的 IPA')
        }
        elseif ($appFolders.Count -gt 1) {
            [void]$problems.Add("Payload 下存在多个 .app：$($appFolders -join ', ')")
        }
        else {
            $appDir = $appFolders[0]
            $result.AppFolder = $appDir

            $infoBytes = Get-ZipEntryBytes -Archive $archive -Name "$appDir/Info.plist" -Map $entryMap
            if ($null -eq $infoBytes) {
                [void]$problems.Add('缺少 Info.plist')
            }
            else {
                $info = Read-PlistFromBytes -Bytes $infoBytes
                $result.BundleId = Get-PlistValue -Dictionary $info -Key 'CFBundleIdentifier'
                $result.ShortVersion = Get-PlistValue -Dictionary $info -Key 'CFBundleShortVersionString'
                $result.BuildVersion = Get-PlistValue -Dictionary $info -Key 'CFBundleVersion'
                $result.MinimumOS = Get-PlistValue -Dictionary $info -Key 'MinimumOSVersion'
                $result.Executable = Get-PlistValue -Dictionary $info -Key 'CFBundleExecutable'

                if (-not $result.BundleId) { [void]$problems.Add('Info.plist 缺少 CFBundleIdentifier') }
                if (-not $result.Executable) { [void]$problems.Add('Info.plist 缺少 CFBundleExecutable') }

                if ($ExpectBundleId -and $result.BundleId -and $result.BundleId -ne $ExpectBundleId) {
                    [void]$problems.Add("Bundle ID 不一致：包内 $($result.BundleId)，期望 $ExpectBundleId")
                }

                $exeName = "$appDir/$($result.Executable)"
                $exeBytes = if ($result.Executable) { Get-ZipEntryBytes -Archive $archive -Name $exeName -Map $entryMap } else { $null }
                if ($null -eq $exeBytes) {
                    [void]$problems.Add("可执行文件缺失：$exeName")
                }
                else {
                    $result.Architectures = Get-MachOArchitectures -Bytes $exeBytes
                    if ($result.Architectures.Count -eq 0) {
                        [void]$problems.Add('可执行文件不是 Mach-O（打包被破坏）')
                    }
                    elseif (-not ($result.Architectures -contains 'arm64' -or $result.Architectures -contains 'arm64e')) {
                        [void]$warnings.Add("未包含 arm64：$($result.Architectures -join ', ') —— 真机可能无法安装")
                    }
                }
            }

            $result.Frameworks = @(
                $entryNames |
                    Where-Object { $_ -match "^$([regex]::Escape($appDir))/Frameworks/[^/]+\.framework/" } |
                    ForEach-Object { (($_ -split '/')[2]) } |
                    Select-Object -Unique
            ).Count

            $result.HasCodeSig = $entryNames -contains "$appDir/_CodeSignature/CodeResources"

            $profileBytes = Get-ZipEntryBytes -Archive $archive -Name "$appDir/embedded.mobileprovision" -Map $entryMap
            if ($null -eq $profileBytes) {
                [void]$problems.Add('缺少 embedded.mobileprovision：没有签名，或签名被剥离')
            }
            else {
                $result.HasProfile = $true
                $profileTemp = [System.IO.Path]::GetTempFileName()
                try {
                    [System.IO.File]::WriteAllBytes($profileTemp, $profileBytes)
                    $summary = Show-ProvisionSummary -Path $profileTemp -Quiet
                    $summary | Add-Member -NotePropertyName 'Path' -NotePropertyValue '(包内 embedded.mobileprovision)' -Force
                    $result.Profile = $summary

                    if ($summary.Expired) { [void]$problems.Add('内嵌描述文件已过期') }

                    $appId = [string]$summary.AppId
                    if ($appId -and $result.BundleId) {
                        $pattern = ($appId -split '\.', 2)[1]
                        if ($pattern -and $pattern -ne '*') {
                            if ($pattern.Contains('*')) {
                                $prefix = $pattern.TrimEnd('*')
                                if (-not $result.BundleId.StartsWith($prefix)) {
                                    [void]$problems.Add("描述文件 AppID($pattern) 与 Bundle ID($($result.BundleId)) 不匹配")
                                }
                            }
                            elseif ($pattern -ne $result.BundleId) {
                                [void]$problems.Add("描述文件 AppID($pattern) 与 Bundle ID($($result.BundleId)) 不匹配")
                            }
                        }
                    }
                }
                finally {
                    Remove-Item -LiteralPath $profileTemp -Force -ErrorAction SilentlyContinue
                }
            }

            if (-not $result.HasCodeSig) {
                [void]$problems.Add('缺少 _CodeSignature/CodeResources：签名不完整')
            }

            if ($entryNames -notcontains "$appDir/PkgInfo") {
                [void]$warnings.Add('缺少 PkgInfo（多数情况下无影响）')
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    if ($size -lt 200KB) { [void]$warnings.Add("体积仅 $([math]::Round($size / 1KB, 1)) KB，确认不是空壳包") }

    $result.Problems = @($problems)
    $result.Warnings = @($warnings)
    $result.Ok = ($problems.Count -eq 0)
    return [pscustomobject]$result
}
