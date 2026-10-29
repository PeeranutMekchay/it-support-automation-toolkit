<#
.SYNOPSIS
    ฟังก์ชันกลางที่ทุกโมดูลใช้ร่วมกัน
.DESCRIPTION
    - ตำแหน่งโฟลเดอร์ของ Toolkit (config, reports, logs, templates)
    - โหลดค่าตั้งค่าจาก config/settings.json
    - บันทึก Log ลงโฟลเดอร์ logs/
    - ตรวจสิทธิ์ Administrator และถามยืนยันก่อนทำงานที่มีผลกับเครื่อง
    - แสดงสถานะ ผ่าน / ควรตรวจสอบ / มีปัญหา และสร้างรายงาน HTML / CSV
#>

$script:ToolkitRoot = Split-Path -Parent $PSScriptRoot
$script:ConfigDir   = Join-Path $script:ToolkitRoot 'config'
$script:ReportDir   = Join-Path $script:ToolkitRoot 'reports'
$script:LogDir      = Join-Path $script:ToolkitRoot 'logs'
$script:TemplateDir = Join-Path $script:ToolkitRoot 'templates'
$script:ToolkitSettings = $null

function Initialize-Toolkit {
    <#
    .SYNOPSIS
        สร้างโฟลเดอร์ reports/ และ logs/ (ถ้ายังไม่มี) แล้วโหลดค่าตั้งค่า
    #>
    [CmdletBinding()]
    param()

    foreach ($dir in @($script:ReportDir, $script:LogDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    $script:ToolkitSettings = Import-ToolkitSetting
}

function Import-ToolkitSetting {
    <#
    .SYNOPSIS
        อ่านไฟล์ config/settings.json แล้วคืนค่าเป็น Object
    #>
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $script:ConfigDir 'settings.json')
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "ไม่พบไฟล์ตั้งค่า: $Path"
    }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        throw "ไฟล์ตั้งค่า $Path ไม่ใช่ JSON ที่ถูกต้อง: $($_.Exception.Message)"
    }
}

function Get-ToolkitSetting {
    <#
    .SYNOPSIS
        คืนค่าตั้งค่าที่โหลดไว้ (โหลดใหม่ถ้ายังไม่เคยโหลด)
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:ToolkitSettings) {
        $script:ToolkitSettings = Import-ToolkitSetting
    }
    return $script:ToolkitSettings
}

function Write-ToolkitLog {
    <#
    .SYNOPSIS
        เขียนบรรทัด Log ลงไฟล์ logs/toolkit_yyyyMMdd.log
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        $now  = Get-Date
        $file = Join-Path $script:LogDir ('toolkit_{0:yyyyMMdd}.log' -f $now)
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] [{2}] {3}' -f $now, $Level, $env:USERNAME, $Message
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8
    }
    catch {
        # การเขียน Log ไม่สำเร็จต้องไม่ทำให้เครื่องมือหยุดทำงาน
        Write-Verbose "เขียน Log ไม่สำเร็จ: $($_.Exception.Message)"
    }
}

function Test-IsWindows {
    return ($env:OS -eq 'Windows_NT')
}

function Test-IsAdministrator {
    <#
    .SYNOPSIS
        ตรวจว่า PowerShell ปัจจุบันรันด้วยสิทธิ์ Administrator หรือไม่
    #>
    if (-not (Test-IsWindows)) { return $false }
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-ConfirmAnswer {
    <#
    .SYNOPSIS
        แปลงคำตอบของผู้ใช้เป็น True/False (ยอมรับ y, yes, ใช่)
    #>
    param([AllowEmptyString()][AllowNull()][string]$Answer)

    if ([string]::IsNullOrWhiteSpace($Answer)) { return $false }
    return @('y', 'yes', 'ใช่') -contains $Answer.Trim().ToLowerInvariant()
}

function Confirm-ToolkitAction {
    <#
    .SYNOPSIS
        ถามยืนยันก่อนทำงานที่มีผลกับเครื่อง ค่าเริ่มต้นคือ "ไม่"
    #>
    param([Parameter(Mandatory)][string]$Message)

    $answer = Read-Host "$Message (y/N)"
    return (Test-ConfirmAnswer -Answer $answer)
}

function Get-StatusLabel {
    <#
    .SYNOPSIS
        แปลงรหัสสถานะเป็นข้อความสำหรับรายงาน
    #>
    param([Parameter(Mandatory)][ValidateSet('Pass', 'Warn', 'Fail', 'Skip')][string]$Status)

    switch ($Status) {
        'Pass' { return '✅ ผ่าน' }
        'Warn' { return '⚠️ ควรตรวจสอบ' }
        'Fail' { return '❌ มีปัญหา' }
        'Skip' { return '⏭️ ข้าม' }
    }
}

function Write-StatusLine {
    <#
    .SYNOPSIS
        แสดงผลบน Console พร้อมสีตามสถานะ
    .NOTES
        ใช้ป้ายข้อความ [PASS]/[WARN]/[FAIL] แทน Emoji เพราะ Console ของ Windows PowerShell 5.1
        หลายเครื่องแสดง Emoji ไม่ได้
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Pass', 'Warn', 'Fail', 'Skip', 'Info')][string]$Status,
        [Parameter(Mandatory)][string]$Message
    )

    $map = @{
        Pass = @{ Tag = '[PASS]'; Color = 'Green' }
        Warn = @{ Tag = '[WARN]'; Color = 'Yellow' }
        Fail = @{ Tag = '[FAIL]'; Color = 'Red' }
        Skip = @{ Tag = '[SKIP]'; Color = 'DarkGray' }
        Info = @{ Tag = '[INFO]'; Color = 'Cyan' }
    }
    Write-Host ('  {0} ' -f $map[$Status].Tag) -ForegroundColor $map[$Status].Color -NoNewline
    Write-Host $Message
}

function Write-SectionHeader {
    param([Parameter(Mandatory)][string]$Title)

    Write-Host ''
    Write-Host ('=' * 50) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 50) -ForegroundColor DarkCyan
}

function Format-ByteSize {
    <#
    .SYNOPSIS
        แปลงจำนวนไบต์เป็นข้อความอ่านง่าย เช่น 1.50 GB
    #>
    param([Parameter(Mandatory)][double]$Bytes)

    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1TB) { return [string]::Format($culture, '{0:N2} TB', $Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return [string]::Format($culture, '{0:N2} GB', $Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return [string]::Format($culture, '{0:N2} MB', $Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return [string]::Format($culture, '{0:N2} KB', $Bytes / 1KB) }
    return [string]::Format($culture, '{0:N0} B', $Bytes)
}

function Get-ReportFilePath {
    <#
    .SYNOPSIS
        สร้างชื่อไฟล์รายงานแบบ <ชื่อรายงาน>_<ชื่อเครื่อง>_<วันเวลา>.<นามสกุล>
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Extension,
        [datetime]$Timestamp = (Get-Date)
    )

    $computer = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($computer)) { $computer = 'PC' }
    $fileName = '{0}_{1}_{2:yyyyMMdd_HHmmss}.{3}' -f $Name, $computer, $Timestamp, $Extension.TrimStart('.')
    return (Join-Path $script:ReportDir $fileName)
}

function ConvertTo-HtmlEncoded {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Format-HtmlStatusCell {
    <#
    .SYNOPSIS
        ใส่ class สีให้ช่องตารางที่เป็นสถานะ (ผลจาก ConvertTo-Html)
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Html)

    foreach ($status in 'Pass', 'Warn', 'Fail', 'Skip') {
        $label = Get-StatusLabel -Status $status
        $Html = $Html.Replace("<td>$label</td>", "<td class=`"status-$($status.ToLowerInvariant())`">$label</td>")
    }
    return $Html
}

function ConvertTo-HtmlSection {
    <#
    .SYNOPSIS
        แปลงข้อมูลเป็น <section> ที่มีหัวข้อและตาราง
    .PARAMETER AsList
        แสดงแบบ Property : Value (เหมาะกับข้อมูล 1 รายการ เช่น สรุปข้อมูลเครื่อง)
    #>
    param(
        [Parameter(Mandatory)][string]$Heading,
        [AllowNull()][AllowEmptyCollection()][object[]]$Data,
        [switch]$AsList,
        [string]$EmptyText = 'ไม่มีข้อมูล'
    )

    $title = ConvertTo-HtmlEncoded $Heading
    if (-not $Data -or $Data.Count -eq 0) {
        return "<section><h2>$title</h2><p class=`"empty`">$(ConvertTo-HtmlEncoded $EmptyText)</p></section>"
    }

    if ($AsList) {
        $table = ($Data | ConvertTo-Html -Fragment -As List) -join "`n"
        $table = $table -replace '^<table>', '<table class="list">'
    }
    else {
        $table = ($Data | ConvertTo-Html -Fragment) -join "`n"
    }
    $table = Format-HtmlStatusCell -Html $table
    return "<section><h2>$title</h2>`n$table`n</section>"
}

function ConvertTo-HtmlBanner {
    <#
    .SYNOPSIS
        กล่องสรุปผลด้านบนรายงาน
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Pass', 'Warn', 'Fail')][string]$Status,
        [Parameter(Mandatory)][string]$Text
    )

    return "<div class=`"banner $($Status.ToLowerInvariant())`">$(ConvertTo-HtmlEncoded $Text)</div>"
}

function Export-HtmlReport {
    <#
    .SYNOPSIS
        รวม HTML Fragment เป็นไฟล์รายงานเดียว พร้อมฝัง CSS จาก templates/report.css
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Body,
        [Parameter(Mandatory)][string]$Path
    )

    $cssPath = Join-Path $script:TemplateDir 'report.css'
    $css = ''
    if (Test-Path -LiteralPath $cssPath) {
        $css = Get-Content -LiteralPath $cssPath -Raw -Encoding UTF8
    }

    $encodedTitle = ConvertTo-HtmlEncoded $Title
    $meta = ConvertTo-HtmlEncoded ('เครื่อง: {0} | ผู้ใช้: {1} | สร้างเมื่อ: {2:yyyy-MM-dd HH:mm:ss}' -f $env:COMPUTERNAME, $env:USERNAME, (Get-Date))
    $content = $Body -join "`n"

    $html = @"
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$encodedTitle</title>
<style>
$css
</style>
</head>
<body>
<header>
<h1>$encodedTitle</h1>
<p class="meta">$meta</p>
</header>
<main>
$content
</main>
<footer>สร้างโดย IT Support Automation Toolkit</footer>
</body>
</html>
"@

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    # ใส่ BOM เพื่อให้เบราว์เซอร์และ Windows PowerShell 5.1 อ่านภาษาไทยถูกต้อง
    [System.IO.File]::WriteAllText($Path, $html, (New-Object System.Text.UTF8Encoding($true)))
    return $Path
}

function Export-ToolkitCsv {
    <#
    .SYNOPSIS
        Export CSV เป็น UTF-8 แบบมี BOM เพื่อให้ Excel เปิดภาษาไทยได้ถูกต้อง
    .NOTES
        PowerShell 7 ใช้ -Encoding utf8 แบบไม่มี BOM จึงต้องระบุ utf8BOM แยก
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )

    $encoding = 'UTF8'
    if ($PSVersionTable.PSVersion.Major -ge 6) { $encoding = 'utf8BOM' }

    if (-not $InputObject) {
        [System.IO.File]::WriteAllText($Path, '', (New-Object System.Text.UTF8Encoding($true)))
    }
    else {
        $InputObject | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding $encoding
    }
    return $Path
}

function ConvertTo-PropertyRow {
    <#
    .SYNOPSIS
        แปลง Object 1 ตัวเป็นแถว Property / Value (ใช้ทำ CSV แบบสรุป)
    #>
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [string]$Section = ''
    )

    foreach ($prop in $InputObject.PSObject.Properties) {
        [pscustomobject]@{
            Section  = $Section
            Property = $prop.Name
            Value    = [string]$prop.Value
        }
    }
}
