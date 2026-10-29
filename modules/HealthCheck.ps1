<#
.SYNOPSIS
    Health Check: ตรวจสุขภาพเครื่องแล้วสรุปเป็น ผ่าน / ควรตรวจสอบ / มีปัญหา
.DESCRIPTION
    ตรวจ: พื้นที่ดิสก์, การใช้ RAM, Service สำคัญ, ระยะเวลาที่ไม่ได้ Restart,
    Windows Defender และ Error ล่าสุดจาก Event Log
    ค่าเกณฑ์ทั้งหมดอยู่ใน config/settings.json (หมวด healthCheck)
#>

# ---------- ฟังก์ชันประเมินผล (ไม่แตะระบบ ทดสอบด้วย Pester ได้) ----------

function Get-DiskHealthStatus {
    param(
        [Parameter(Mandatory)][double]$FreePercent,
        [double]$WarnPercent = 15,
        [double]$CriticalPercent = 5
    )

    if ($FreePercent -lt $CriticalPercent) { return 'Fail' }
    if ($FreePercent -lt $WarnPercent) { return 'Warn' }
    return 'Pass'
}

function Get-MemoryHealthStatus {
    param(
        [Parameter(Mandatory)][double]$UsedPercent,
        [double]$WarnPercent = 90,
        [double]$CriticalPercent = 97
    )

    if ($UsedPercent -ge $CriticalPercent) { return 'Fail' }
    if ($UsedPercent -gt $WarnPercent) { return 'Warn' }
    return 'Pass'
}

function Get-UptimeHealthStatus {
    param(
        [Parameter(Mandatory)][double]$Days,
        [double]$WarnDays = 7,
        [double]$CriticalDays = 30
    )

    if ($Days -gt $CriticalDays) { return 'Fail' }
    if ($Days -gt $WarnDays) { return 'Warn' }
    return 'Pass'
}

function Get-ServiceHealthStatus {
    <#
    .SYNOPSIS
        ประเมินสถานะ Service
    .PARAMETER MustBeRunning
        true = ต้องทำงานอยู่ตลอด (เช่น DNS Client)
        false = Service แบบเปิดเมื่อมีงาน (เช่น Windows Update) หยุดอยู่ถือว่าปกติ แต่ห้าม Disabled
    #>
    param(
        [AllowNull()][string]$Status,
        [AllowNull()][string]$StartType,
        [bool]$MustBeRunning = $true
    )

    if ([string]::IsNullOrEmpty($Status)) {
        return [pscustomobject]@{ Status = 'Warn'; Detail = 'ไม่พบ Service นี้ในเครื่อง' }
    }
    if ($StartType -eq 'Disabled') {
        return [pscustomobject]@{ Status = 'Fail'; Detail = "ถูกปิดใช้งาน (Disabled), สถานะ $Status" }
    }
    if ($Status -eq 'Running') {
        return [pscustomobject]@{ Status = 'Pass'; Detail = "ทำงานอยู่ (StartType: $StartType)" }
    }
    if ($MustBeRunning) {
        return [pscustomobject]@{ Status = 'Fail'; Detail = "ไม่ได้ทำงาน (สถานะ $Status, StartType: $StartType)" }
    }
    return [pscustomobject]@{ Status = 'Pass'; Detail = "หยุดอยู่ ซึ่งปกติสำหรับ Service นี้ (StartType: $StartType)" }
}

function Get-DefenderHealthStatus {
    param(
        [bool]$AntivirusEnabled,
        [bool]$RealTimeProtectionEnabled,
        [Nullable[datetime]]$SignatureLastUpdated,
        [double]$MaxAgeDays = 3,
        [datetime]$Now = (Get-Date)
    )

    if (-not $AntivirusEnabled) {
        return [pscustomobject]@{ Status = 'Fail'; Detail = 'Windows Defender ปิดอยู่' }
    }
    if (-not $RealTimeProtectionEnabled) {
        return [pscustomobject]@{ Status = 'Fail'; Detail = 'Real-time Protection ปิดอยู่' }
    }
    if ($null -eq $SignatureLastUpdated) {
        return [pscustomobject]@{ Status = 'Warn'; Detail = 'ไม่ทราบวันที่อัปเดต Signature' }
    }
    # PowerShell แกะค่า Nullable ให้อัตโนมัติ จึงใช้เป็น DateTime ได้เลย
    $updated = [datetime]$SignatureLastUpdated
    $age = ($Now - $updated).TotalDays
    $detail = 'Signature อัปเดตล่าสุด {0:yyyy-MM-dd HH:mm} ({1:N1} วันที่แล้ว)' -f $updated, $age
    if ($age -gt $MaxAgeDays) {
        return [pscustomobject]@{ Status = 'Warn'; Detail = $detail }
    }
    return [pscustomobject]@{ Status = 'Pass'; Detail = $detail }
}

function Get-HealthOverallStatus {
    <#
    .SYNOPSIS
        สถานะรวม: มี Fail = Fail, มี Warn = Warn, นอกนั้น Pass
    #>
    param([AllowNull()][object[]]$Results)

    $statuses = @($Results | ForEach-Object { $_.Status })
    if ($statuses -contains 'Fail') { return 'Fail' }
    if ($statuses -contains 'Warn') { return 'Warn' }
    return 'Pass'
}

function New-HealthResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'สร้าง Object ในหน่วยความจำเท่านั้น ไม่ได้เปลี่ยนแปลงระบบ')]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Warn', 'Fail', 'Skip')][string]$Status,
        [string]$Detail = '',
        [string]$Recommendation = ''
    )

    return [pscustomobject]@{
        Category       = $Category
        Item           = $Item
        Status         = $Status
        Detail         = $Detail
        Recommendation = $Recommendation
    }
}

# ---------- ฟังก์ชันตรวจจริง ----------

function Test-DiskHealth {
    param([Parameter(Mandatory)][object]$Config)

    $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)
    foreach ($d in $disks) {
        if (-not $d.Size) { continue }
        $freePercent = [math]::Round(($d.FreeSpace / $d.Size) * 100, 1)
        $status = Get-DiskHealthStatus -FreePercent $freePercent -WarnPercent $Config.diskFreeWarnPercent -CriticalPercent $Config.diskFreeCriticalPercent
        $advice = ''
        if ($status -ne 'Pass') { $advice = 'ใช้ Cleanup Tool (เมนู 4) หรือย้ายไฟล์ใหญ่ออก / ตรวจด้วย Storage Sense' }
        New-HealthResult -Category 'Disk' -Item "ไดรฟ์ $($d.DeviceID)" -Status $status `
            -Detail ('เหลือ {0} จาก {1} ({2}%)' -f (Format-ByteSize $d.FreeSpace), (Format-ByteSize $d.Size), $freePercent) `
            -Recommendation $advice
    }
}

function Test-MemoryHealth {
    param([Parameter(Mandatory)][object]$Config)

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $totalKB = [double]$os.TotalVisibleMemorySize
    $freeKB  = [double]$os.FreePhysicalMemory
    $usedPercent = [math]::Round((($totalKB - $freeKB) / $totalKB) * 100, 1)
    $status = Get-MemoryHealthStatus -UsedPercent $usedPercent -WarnPercent $Config.memoryUsedWarnPercent -CriticalPercent $Config.memoryUsedCriticalPercent

    $advice = ''
    if ($status -ne 'Pass') {
        $top = Get-Process -ErrorAction SilentlyContinue | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First 3
        $topText = ($top | ForEach-Object { '{0} ({1})' -f $_.ProcessName, (Format-ByteSize $_.WorkingSet64) }) -join ', '
        $advice = "ปิดโปรแกรมที่ใช้ RAM มาก: $topText"
    }
    New-HealthResult -Category 'Memory' -Item 'RAM' -Status $status `
        -Detail ('ใช้ไป {0}% ({1} จาก {2})' -f $usedPercent, (Format-ByteSize (($totalKB - $freeKB) * 1KB)), (Format-ByteSize ($totalKB * 1KB))) `
        -Recommendation $advice
}

function Test-UptimeHealth {
    param([Parameter(Mandatory)][object]$Config)

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $uptime = (Get-Date) - $os.LastBootUpTime
    $status = Get-UptimeHealthStatus -Days $uptime.TotalDays -WarnDays $Config.uptimeWarnDays -CriticalDays $Config.uptimeCriticalDays
    $advice = ''
    if ($status -ne 'Pass') { $advice = 'ควร Restart เครื่องเพื่อให้ Update ติดตั้งครบและคืนหน่วยความจำ' }
    New-HealthResult -Category 'System' -Item 'Uptime' -Status $status `
        -Detail ('เปิดเครื่องมา {0} (Boot ล่าสุด {1:yyyy-MM-dd HH:mm})' -f (Format-Uptime $uptime), $os.LastBootUpTime) `
        -Recommendation $advice
}

function Test-ServiceHealth {
    param([Parameter(Mandatory)][object]$Config)

    foreach ($svcConfig in @($Config.services)) {
        $svc = Get-Service -Name $svcConfig.name -ErrorAction SilentlyContinue
        $statusText = $null
        $startType = $null
        if ($svc) {
            $statusText = [string]$svc.Status
            $startType = [string]$svc.StartType
        }
        $eval = Get-ServiceHealthStatus -Status $statusText -StartType $startType -MustBeRunning ([bool]$svcConfig.mustBeRunning)
        $advice = ''
        if ($eval.Status -eq 'Fail') {
            $advice = "ลองสั่ง Start-Service -Name $($svcConfig.name) (ต้องใช้ Admin) และตรวจ StartType ใน services.msc"
        }
        New-HealthResult -Category 'Service' -Item ('{0} ({1})' -f $svcConfig.displayName, $svcConfig.name) `
            -Status $eval.Status -Detail $eval.Detail -Recommendation $advice
    }
}

function Test-DefenderHealth {
    param([Parameter(Mandatory)][object]$Config)

    if (-not (Get-Command -Name Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        return New-HealthResult -Category 'Security' -Item 'Windows Defender' -Status 'Warn' `
            -Detail 'ไม่พบคำสั่ง Get-MpComputerStatus' -Recommendation 'ตรวจว่าเครื่องใช้ Antivirus ตัวอื่นแทนหรือไม่'
    }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
    }
    catch {
        return New-HealthResult -Category 'Security' -Item 'Windows Defender' -Status 'Warn' `
            -Detail "อ่านสถานะไม่ได้: $($_.Exception.Message)" `
            -Recommendation 'ถ้าใช้ Antivirus ตัวอื่น Defender จะถูกปิดอัตโนมัติ ให้ตรวจสถานะของตัวนั้นแทน'
    }

    $eval = Get-DefenderHealthStatus -AntivirusEnabled ([bool]$mp.AntivirusEnabled) `
        -RealTimeProtectionEnabled ([bool]$mp.RealTimeProtectionEnabled) `
        -SignatureLastUpdated $mp.AntivirusSignatureLastUpdated -MaxAgeDays $Config.defenderSignatureMaxAgeDays
    $advice = ''
    if ($eval.Status -ne 'Pass') { $advice = 'เปิด Windows Security แล้วกด Check for updates / เปิด Real-time protection' }
    New-HealthResult -Category 'Security' -Item 'Windows Defender' -Status $eval.Status -Detail $eval.Detail -Recommendation $advice
}

function Get-RecentErrorEvent {
    <#
    .SYNOPSIS
        Event ระดับ Critical / Error ล่าสุดจาก System และ Application log
    #>
    param(
        [int]$Hours = 24,
        [int]$MaxEvents = 20
    )

    $filter = @{
        LogName   = @('System', 'Application')
        Level     = @(1, 2)
        StartTime = (Get-Date).AddHours(-$Hours)
    }
    try {
        $events = Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop
    }
    catch {
        # Get-WinEvent โยน Error เมื่อไม่พบ Event ซึ่งในกรณีนี้คือข่าวดี
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return @() }
        throw
    }

    foreach ($e in $events) {
        $message = ''
        if ($e.Message) { $message = ($e.Message -split "`r?`n")[0] }
        if ($message.Length -gt 200) { $message = $message.Substring(0, 200) + '...' }
        [pscustomobject]@{
            Time    = '{0:yyyy-MM-dd HH:mm:ss}' -f $e.TimeCreated
            Log     = $e.LogName
            Level   = $(if ($e.Level -eq 1) { 'Critical' } else { 'Error' })
            Source  = $e.ProviderName
            EventId = $e.Id
            Message = $message
        }
    }
}

function Test-EventLogHealth {
    param([Parameter(Mandatory)][object]$Config)

    $events = @(Get-RecentErrorEvent -Hours $Config.eventLogHours -MaxEvents $Config.eventLogMaxEvents)
    $script:HealthCheckEvents = $events

    if ($events.Count -eq 0) {
        return New-HealthResult -Category 'Event Log' -Item 'Error ล่าสุด' -Status 'Pass' `
            -Detail ('ไม่พบ Error ใน {0} ชั่วโมงที่ผ่านมา' -f $Config.eventLogHours)
    }

    $critical = @($events | Where-Object { $_.Level -eq 'Critical' }).Count
    $status = 'Warn'
    if ($critical -gt 0) { $status = 'Fail' }
    $topSources = ($events | Group-Object -Property Source | Sort-Object -Property Count -Descending |
        Select-Object -First 3 | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Count }) -join ', '
    $countText = "$($events.Count)"
    if ($events.Count -ge $Config.eventLogMaxEvents) { $countText = "$countText+" }

    New-HealthResult -Category 'Event Log' -Item 'Error ล่าสุด' -Status $status `
        -Detail ('พบ {0} รายการใน {1} ชั่วโมง (Critical {2}) แหล่งที่พบบ่อย: {3}' -f $countText, $Config.eventLogHours, $critical, $topSources) `
        -Recommendation 'ดูรายละเอียดในรายงาน HTML หรือ Event Viewer แล้วค้นหาจาก Source + Event ID'
}

function Invoke-HealthCheck {
    <#
    .SYNOPSIS
        รันการตรวจทุกหมวดแล้วคืนรายการผลลัพธ์ (การตรวจหมวดไหนพัง จะไม่กระทบหมวดอื่น)
    #>
    [CmdletBinding()]
    param()

    $config = (Get-ToolkitSetting).healthCheck
    $script:HealthCheckEvents = @()

    $checks = [ordered]@{
        'Disk'      = { Test-DiskHealth -Config $config }
        'Memory'    = { Test-MemoryHealth -Config $config }
        'Service'   = { Test-ServiceHealth -Config $config }
        'System'    = { Test-UptimeHealth -Config $config }
        'Security'  = { Test-DefenderHealth -Config $config }
        'Event Log' = { Test-EventLogHealth -Config $config }
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($name in $checks.Keys) {
        try {
            foreach ($r in @(& $checks[$name])) { $results.Add($r) }
        }
        catch {
            Write-ToolkitLog -Level WARN -Message "HealthCheck: ตรวจหมวด $name ไม่สำเร็จ - $($_.Exception.Message)"
            $results.Add((New-HealthResult -Category $name -Item 'การตรวจ' -Status 'Warn' `
                -Detail "ตรวจไม่สำเร็จ: $($_.Exception.Message)" -Recommendation 'ลองรันด้วยสิทธิ์ Admin'))
        }
    }
    return $results.ToArray()
}

function Show-HealthCheckResult {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results)

    $category = ''
    foreach ($r in $Results) {
        if ($r.Category -ne $category) {
            $category = $r.Category
            Write-Host ''
            Write-Host "  [$category]" -ForegroundColor White
        }
        Write-StatusLine -Status $r.Status -Message ('{0}: {1}' -f $r.Item, $r.Detail)
        if ($r.Recommendation) { Write-Host "         -> $($r.Recommendation)" -ForegroundColor DarkYellow }
    }

    $overall = Get-HealthOverallStatus -Results $Results
    $pass = @($Results | Where-Object Status -eq 'Pass').Count
    $warn = @($Results | Where-Object Status -eq 'Warn').Count
    $fail = @($Results | Where-Object Status -eq 'Fail').Count
    Write-Host ''
    Write-StatusLine -Status $overall -Message ('สรุป: ผ่าน {0} | ควรตรวจสอบ {1} | มีปัญหา {2}' -f $pass, $warn, $fail)
}

function Export-HealthCheckReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [AllowNull()][object[]]$Events = @()
    )

    $timestamp = Get-Date
    $htmlPath = Get-ReportFilePath -Name 'HealthCheck' -Extension 'html' -Timestamp $timestamp
    $csvPath  = Get-ReportFilePath -Name 'HealthCheck' -Extension 'csv' -Timestamp $timestamp

    $overall = Get-HealthOverallStatus -Results $Results
    $pass = @($Results | Where-Object Status -eq 'Pass').Count
    $warn = @($Results | Where-Object Status -eq 'Warn').Count
    $fail = @($Results | Where-Object Status -eq 'Fail').Count
    $bannerText = '{0}  —  ผ่าน {1} | ควรตรวจสอบ {2} | มีปัญหา {3}' -f (Get-StatusLabel $overall), $pass, $warn, $fail

    $tableRows = $Results | Select-Object Category, Item,
        @{ Name = 'Status'; Expression = { Get-StatusLabel $_.Status } }, Detail, Recommendation

    $body = @(
        ConvertTo-HtmlBanner -Status $overall -Text $bannerText
        ConvertTo-HtmlSection -Heading 'ผลการตรวจ' -Data @($tableRows)
        ConvertTo-HtmlSection -Heading 'Error ล่าสุดจาก Event Log' -Data $Events -EmptyText 'ไม่พบ Error'
    )
    Export-HtmlReport -Title 'Health Check Report' -Body $body -Path $htmlPath | Out-Null

    $csvRows = $Results | Select-Object @{ Name = 'Computer'; Expression = { $env:COMPUTERNAME } },
        @{ Name = 'CheckedAt'; Expression = { '{0:yyyy-MM-dd HH:mm:ss}' -f $timestamp } },
        Category, Item, Status, Detail, Recommendation
    Export-ToolkitCsv -InputObject @($csvRows) -Path $csvPath | Out-Null

    return [pscustomobject]@{ Html = $htmlPath; Csv = $csvPath; Overall = $overall }
}

function Invoke-HealthCheckMenu {
    <#
    .SYNOPSIS
        เมนู [2] ตรวจสุขภาพเครื่อง แสดงผล และสร้างรายงาน
    #>
    [CmdletBinding()]
    param([switch]$NoOpen)

    Write-SectionHeader -Title 'Health Check'
    Write-StatusLine -Status Info -Message 'กำลังตรวจสุขภาพเครื่อง...'
    Write-ToolkitLog -Message 'HealthCheck: เริ่มตรวจ'

    $results = Invoke-HealthCheck
    Show-HealthCheckResult -Results $results
    $files = Export-HealthCheckReport -Results $results -Events $script:HealthCheckEvents

    Write-Host ''
    Write-StatusLine -Status Info -Message "รายงาน HTML: $($files.Html)"
    Write-StatusLine -Status Info -Message "CSV: $($files.Csv)"
    Write-ToolkitLog -Message "HealthCheck: ผลรวม $($files.Overall) รายงาน $($files.Html)"

    if (-not $NoOpen -and (Confirm-ToolkitAction -Message 'เปิดรายงาน HTML เลยไหม?')) {
        Invoke-Item -LiteralPath $files.Html
    }
    return $files
}
