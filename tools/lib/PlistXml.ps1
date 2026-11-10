# tools/lib/PlistXml.ps1 — plist 读取（XML + binary）与描述文件解析，零外部依赖
# 被 profile-report.ps1 / verify-ipa.ps1 / resign.ps1 点源引用

# ─────────────────────────────────────────────────────────────
# XML plist
# ─────────────────────────────────────────────────────────────

function ConvertFrom-PlistXmlNode {
    param([Parameter(Mandatory)][System.Xml.XmlNode]$Node)

    switch ($Node.Name) {
        'dict' {
            $result = [ordered]@{}
            $children = @($Node.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
            for ($i = 0; $i -lt $children.Count; $i += 2) {
                if ($children[$i].Name -ne 'key') { continue }
                if ($i + 1 -ge $children.Count) { break }
                $result[$children[$i].InnerText] = ConvertFrom-PlistXmlNode -Node $children[$i + 1]
            }
            return $result
        }
        'array' {
            $items = @()
            foreach ($child in @($Node.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
                $items += ,(ConvertFrom-PlistXmlNode -Node $child)
            }
            return $items
        }
        'true' { return $true }
        'false' { return $false }
        'integer' { return [int64]$Node.InnerText }
        'real' { return [double]$Node.InnerText }
        'date' {
            return [datetime]::Parse($Node.InnerText, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        }
        'data' { return $Node.InnerText }
        default { return $Node.InnerText }
    }
}

function ConvertFrom-PlistXmlText {
    param([Parameter(Mandatory)][string]$XmlText)

    $start = $XmlText.IndexOf('<plist', [System.StringComparison]::Ordinal)
    if ($start -lt 0) { throw '未找到 plist 根节点' }
    $end = $XmlText.IndexOf('</plist>', $start, [System.StringComparison]::Ordinal)
    if ($end -lt 0) { throw 'plist 结构不完整' }
    $end += '</plist>'.Length

    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $doc.LoadXml($XmlText.Substring($start, $end - $start))

    $root = $doc.SelectSingleNode('/plist/*')
    if ($null -eq $root) { throw 'plist 根节点缺失' }
    return ConvertFrom-PlistXmlNode -Node $root
}

function Read-PlistFile {
    <#
      .SYNOPSIS
        读取 plist 文件，自动识别 XML 与 binary 两种格式。
      .DESCRIPTION
        .mobileprovision 是 CMS/PKCS#7 包裹，内部嵌了一段明文 XML plist。
        这里按字节扫描 <?xml ... </plist> 取元数据，不做签名链校验。
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "文件不存在: $Path" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)

    if ($bytes.Length -ge 8 -and [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8) -eq 'bplist00') {
        return Read-BinaryPlist -Bytes $bytes
    }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    return ConvertFrom-PlistXmlText -XmlText $text
}

# ─────────────────────────────────────────────────────────────
# Binary plist (bplist00)
# ─────────────────────────────────────────────────────────────

function Read-BigEndianUInt {
    param([byte[]]$Bytes, [int]$Offset, [int]$Size)

    [uint64]$value = 0
    for ($i = 0; $i -lt $Size; $i++) {
        $value = ($value -shl 8) -bor [uint64]$Bytes[$Offset + $i]
    }
    return $value
}

function Read-BplistCount {
    param([byte[]]$Bytes, [int]$Offset, [int]$Info)

    if ($Info -ne 0x0F) { return [pscustomobject]@{ Count = $Info; Skip = 0 } }
    $marker = $Bytes[$Offset + 1]
    if (($marker -shr 4) -ne 0x1) { throw 'bplist 长度字段非法' }
    $size = 1 -shl ($marker -band 0x0F)
    $count = Read-BigEndianUInt -Bytes $Bytes -Offset ($Offset + 2) -Size $size
    return [pscustomobject]@{ Count = [int]$count; Skip = 1 + $size }
}

function Read-BinaryPlist {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    if ($Bytes.Length -lt 40) { throw 'bplist 长度不足' }
    if ([System.Text.Encoding]::ASCII.GetString($Bytes, 0, 8) -ne 'bplist00') { throw '不是 bplist00' }

    $trailer = $Bytes.Length - 32
    $offsetIntSize = [int]$Bytes[$trailer + 6]
    $objectRefSize = [int]$Bytes[$trailer + 7]
    $numObjects = [int](Read-BigEndianUInt -Bytes $Bytes -Offset ($trailer + 8) -Size 8)
    $topObject = [int](Read-BigEndianUInt -Bytes $Bytes -Offset ($trailer + 16) -Size 8)
    $tableOffset = [int](Read-BigEndianUInt -Bytes $Bytes -Offset ($trailer + 24) -Size 8)

    if ($objectRefSize -lt 1 -or $objectRefSize -gt 8) { throw "bplist objectRefSize 非法: $objectRefSize" }
    if ($offsetIntSize -lt 1 -or $offsetIntSize -gt 8) { throw "bplist offsetIntSize 非法: $offsetIntSize" }
    if ($numObjects -lt 1 -or $tableOffset -le 0 -or $tableOffset -ge $Bytes.Length) { throw 'bplist 结构非法' }

    $offsets = New-Object 'int[]' $numObjects
    for ($i = 0; $i -lt $numObjects; $i++) {
        $offsets[$i] = [int](Read-BigEndianUInt -Bytes $Bytes -Offset ($tableOffset + $i * $offsetIntSize) -Size $offsetIntSize)
    }

    $script:bpBytes = $Bytes
    $script:bpOffsets = $offsets
    $script:bpRefSize = $objectRefSize
    $script:bpDepth = 0

    return Read-BplistObject -Index $topObject
}

function Read-BplistObject {
    param([int]$Index)

    if ($Index -lt 0 -or $Index -ge $script:bpOffsets.Count) { throw "bplist 引用越界: $Index" }
    if ($script:bpDepth -gt 24) { throw 'bplist 嵌套过深' }

    $script:bpDepth++
    try {
        $bytes = $script:bpBytes
        $offset = $script:bpOffsets[$Index]
        $marker = $bytes[$offset]
        $type = $marker -shr 4
        $info = $marker -band 0x0F

        switch ($type) {
            0x0 {
                switch ($info) {
                    0x0 { return $null }
                    0x8 { return $false }
                    0x9 { return $true }
                    default { return $null }
                }
            }
            0x1 {
                $size = 1 -shl $info
                return [int64](Read-BigEndianUInt -Bytes $bytes -Offset ($offset + 1) -Size $size)
            }
            0x2 {
                $size = 1 -shl $info
                $raw = New-Object byte[] $size
                [Array]::Copy($bytes, $offset + 1, $raw, 0, $size)
                [Array]::Reverse($raw)
                if ($size -eq 4) { return [double][System.BitConverter]::ToSingle($raw, 0) }
                return [System.BitConverter]::ToDouble($raw, 0)
            }
            0x3 {
                $raw = New-Object byte[] 8
                [Array]::Copy($bytes, $offset + 1, $raw, 0, 8)
                [Array]::Reverse($raw)
                $seconds = [System.BitConverter]::ToDouble($raw, 0)
                $epoch = [datetime]::SpecifyKind([datetime]'2001-01-01', [System.DateTimeKind]::Utc)
                return $epoch.AddSeconds($seconds)
            }
            0x4 {
                $c = Read-BplistCount -Bytes $bytes -Offset $offset -Info $info
                $len = [int]$c.Count
                return [System.Convert]::ToBase64String($bytes, $offset + 1 + $c.Skip, $len)
            }
            0x5 {
                $c = Read-BplistCount -Bytes $bytes -Offset $offset -Info $info
                $len = [int]$c.Count
                return [System.Text.Encoding]::ASCII.GetString($bytes, $offset + 1 + $c.Skip, $len)
            }
            0x6 {
                $c = Read-BplistCount -Bytes $bytes -Offset $offset -Info $info
                $len = [int]$c.Count * 2
                return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, $offset + 1 + $c.Skip, $len)
            }
            0x8 {
                $size = $info + 1
                return [int64](Read-BigEndianUInt -Bytes $bytes -Offset ($offset + 1) -Size $size)
            }
            0xA {
                $c = Read-BplistCount -Bytes $bytes -Offset $offset -Info $info
                $count = [int]$c.Count
                $start = $offset + 1 + $c.Skip
                $list = New-Object System.Collections.ArrayList
                for ($i = 0; $i -lt $count; $i++) {
                    $ref = [int](Read-BigEndianUInt -Bytes $bytes -Offset ($start + $i * $script:bpRefSize) -Size $script:bpRefSize)
                    [void]$list.Add((Read-BplistObject -Index $ref))
                }
                return , ($list.ToArray())
            }
            0xD {
                $c = Read-BplistCount -Bytes $bytes -Offset $offset -Info $info
                $count = [int]$c.Count
                $start = $offset + 1 + $c.Skip
                $dict = @{}
                for ($i = 0; $i -lt $count; $i++) {
                    $keyRef = [int](Read-BigEndianUInt -Bytes $bytes -Offset ($start + $i * $script:bpRefSize) -Size $script:bpRefSize)
                    $valRef = [int](Read-BigEndianUInt -Bytes $bytes -Offset ($start + ($count + $i) * $script:bpRefSize) -Size $script:bpRefSize)
                    $key = [string](Read-BplistObject -Index $keyRef)
                    $dict[$key] = Read-BplistObject -Index $valRef
                }
                return $dict
            }
            default {
                return $null
            }
        }
    }
    finally {
        $script:bpDepth--
    }
}

function Get-PlistValue {
    <# 同时兼容 Hashtable 与 OrderedDictionary 的安全取值 #>
    param($Dictionary, [string]$Key, $Default = $null)

    if ($null -eq $Dictionary) { return $Default }
    if ($Dictionary -is [System.Collections.IDictionary]) {
        if ($Dictionary.Contains($Key)) { return $Dictionary[$Key] }
    }
    return $Default
}

# ─────────────────────────────────────────────────────────────
# 描述文件
# ─────────────────────────────────────────────────────────────

function Get-ProvisionKind {
    <#
      按苹果的描述文件语义判定分发类型。判定顺序不能改：
      ProvisionsAllDevices 优先，其次看设备列表与 get-task-allow。
    #>
    param([Parameter(Mandatory)]$Profile)

    $entitlements = Get-PlistValue -Dictionary $Profile -Key 'Entitlements'
    $getTaskAllow = $false
    $gte = Get-PlistValue -Dictionary $entitlements -Key 'get-task-allow'
    if ($null -ne $gte) { $getTaskAllow = [bool]$gte }

    if ((Get-PlistValue -Dictionary $Profile -Key 'ProvisionsAllDevices') -eq $true) {
        return [pscustomobject]@{ Kind = 'In-House 企业分发'; Installable = '任意设备'; Risk = '证书易被吊销' }
    }

    $devices = Get-PlistValue -Dictionary $Profile -Key 'ProvisionedDevices'
    $deviceCount = 0
    if ($null -ne $devices) { $deviceCount = @($devices).Count }

    if ($deviceCount -gt 0 -and $getTaskAllow) {
        return [pscustomobject]@{ Kind = 'Development 开发'; Installable = "$deviceCount 台已注册设备"; Risk = '免费证书 7 天到期' }
    }
    if ($deviceCount -gt 0) {
        return [pscustomobject]@{ Kind = 'Ad Hoc 分发'; Installable = "$deviceCount 台已注册设备"; Risk = '有效期 1 年' }
    }
    if ($getTaskAllow) {
        return [pscustomobject]@{ Kind = 'Development 开发'; Installable = '仅本机调试'; Risk = '免费证书 7 天到期' }
    }
    return [pscustomobject]@{ Kind = 'App Store'; Installable = '仅商店渠道'; Risk = '不能侧载自签' }
}

function Show-ProvisionSummary {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Quiet
    )

    $profile = Read-PlistFile -Path $Path
    $kind = Get-ProvisionKind -Profile $profile

    $teamIds = @(Get-PlistValue -Dictionary $profile -Key 'TeamIdentifier' -Default @())
    $teamId = if ($teamIds.Count -gt 0 -and $teamIds[0]) { $teamIds[0] } else { '(未标注)' }

    $expiration = $null
    $rawExpiration = Get-PlistValue -Dictionary $profile -Key 'ExpirationDate'
    if ($rawExpiration) { $expiration = ([datetime]$rawExpiration).ToUniversalTime() }

    $daysLeft = $null
    if ($expiration) { $daysLeft = [math]::Floor(($expiration - [datetime]::UtcNow).TotalDays) }

    $entitlements = Get-PlistValue -Dictionary $profile -Key 'Entitlements'
    $appId = Get-PlistValue -Dictionary $entitlements -Key 'application-identifier'
    $keychain = @(Get-PlistValue -Dictionary $entitlements -Key 'keychain-access-groups' -Default @())
    $push = Get-PlistValue -Dictionary $entitlements -Key 'aps-environment' -Default '(无)'

    $state = '有效'
    $color = 'Green'
    if ($null -ne $daysLeft) {
        if ($daysLeft -lt 0) { $state = '已过期'; $color = 'Red' }
        elseif ($daysLeft -lt 10) { $state = "即将过期（$daysLeft 天）"; $color = 'Yellow' }
        elseif ($daysLeft -lt 30) { $state = "需要留意（$daysLeft 天）"; $color = 'Yellow' }
    }

    $created = Get-PlistValue -Dictionary $profile -Key 'CreationDate'
    $createdUtc = if ($created) { ([datetime]$created).ToUniversalTime() } else { $null }

    if (-not $Quiet) {
        Write-Host ''
        Write-Host '  描述文件体检' -ForegroundColor Cyan
        Write-Host ('  ' + ('─' * 60)) -ForegroundColor DarkGray
        Write-Host ("  名称        {0}" -f (Get-PlistValue -Dictionary $profile -Key 'Name'))
        Write-Host ("  UUID        {0}" -f (Get-PlistValue -Dictionary $profile -Key 'UUID'))
        Write-Host ("  类型        {0}" -f $kind.Kind)
        Write-Host ("  可安装于    {0}" -f $kind.Installable)
        Write-Host ("  TeamID      {0}" -f $teamId)
        Write-Host ("  AppID       {0}" -f $appId)
        Write-Host ("  Keychain    {0}" -f $(if ($keychain.Count -and $keychain[0]) { $keychain -join ', ' } else { '(未声明)' }))
        Write-Host ("  推送环境    {0}" -f $push)
        if ($createdUtc) { Write-Host ("  创建时间    {0:yyyy-MM-dd HH:mm} UTC" -f $createdUtc) }
        if ($expiration) {
            Write-Host ("  到期时间    {0:yyyy-MM-dd HH:mm} UTC" -f $expiration)
            Write-Host ("  剩余        {0} 天" -f $daysLeft) -ForegroundColor $color
        }
        Write-Host ("  状态        {0}" -f $state) -ForegroundColor $color
        if ($kind.Kind -like 'Development*' -and $null -ne $daysLeft -and $daysLeft -lt 10) {
            Write-Host '  提示        免费证书 7 天必须重签；换付费账号可一次签一年。' -ForegroundColor Yellow
        }
        Write-Host ('  ' + ('─' * 60)) -ForegroundColor DarkGray
        Write-Host ''
    }

    return [pscustomobject]@{
        Path         = (Resolve-Path -LiteralPath $Path).Path
        Name         = Get-PlistValue -Dictionary $profile -Key 'Name'
        Uuid         = Get-PlistValue -Dictionary $profile -Key 'UUID'
        Kind         = $kind.Kind
        Installable  = $kind.Installable
        TeamId       = $teamId
        AppId        = $appId
        Keychain     = $keychain
        Push         = $push
        ExpiresUtc   = $expiration
        DaysLeft     = $daysLeft
        Expired      = ($null -ne $daysLeft -and $daysLeft -lt 0)
        DeviceCount  = $(if ($null -ne (Get-PlistValue -Dictionary $profile -Key 'ProvisionedDevices')) { @(Get-PlistValue -Dictionary $profile -Key 'ProvisionedDevices').Count } else { 0 })
        State        = $state
        Entitlements = $entitlements
    }
}
