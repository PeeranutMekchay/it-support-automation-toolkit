<#
.SYNOPSIS
    New PC Setup: ติดตั้งโปรแกรมจาก config/apps.json ผ่าน winget และตั้งค่าพื้นฐาน
.DESCRIPTION
    - แก้รายการโปรแกรมได้ที่ config/apps.json โดยไม่ต้องแก้โค้ด
    - ติดตั้งทีละรายการ พร้อมแสดงความคืบหน้า
    - ข้ามโปรแกรมที่ติดตั้งแล้ว แล้วสรุปผล สำเร็จ / ข้าม / ล้มเหลว
    - (เสริม) แสดงนามสกุลไฟล์ และตั้ง Power Plan ตาม config/settings.json
#>

# winget คืนค่า Exit Code เป็น HRESULT ซึ่ง PowerShell อ่านเป็น Int32 ติดลบ
$script:WingetExitCode = @{
    NoApplicationsFound = -1978335212   # 0x8A150014 ไม่พบ Package ตาม ID
    UpdateNotApplicable = -1978335189   # 0x8A15002B ติดตั้งแล้วและไม่มีเวอร์ชันใหม่
    PackageAlreadyInstalled = -1978335135   # 0x8A150061 ติดตั้งแล้ว
}

$script:PowerPlanGuid = @{
    Balanced        = '381b4222-f694-41f0-9685-ff5bb260df2e'
    HighPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    PowerSaver      = 'a1841308-3541-4fab-bc81-f71556f20b4a'
}

function Read-AppList {
    <#
    .SYNOPSIS
        อ่านและตรวจความถูกต้องของ apps.json
    .OUTPUTS
        รายการ Object ที่มี Name, Id, Source
    #>
    [CmdletBinding()]
    param([string]$Path = (Join-Path $script:ConfigDir 'apps.json'))

    if (-not (Test-Path -LiteralPath $Path)) { throw "ไม่พบไฟล์รายการโปรแกรม: $Path" }
    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "ไฟล์ $Path ไม่ใช่ JSON ที่ถูกต้อง: $($_.Exception.Message)"
    }
    if (-not $json.PSObject.Properties['apps']) { throw "ไฟล์ $Path ต้องมี property 'apps'" }

    $index = 0
    foreach ($app in @($json.apps)) {
        $index++
        if (-not $app.PSObject.Properties['id'] -or [string]::IsNullOrWhiteSpace($app.id)) {
            throw "รายการที่ $index ใน $Path ไม่มี 'id'"
        }
        $name = $app.id
        if ($app.PSObject.Properties['name'] -and -not [string]::IsNullOrWhiteSpace($app.name)) { $name = $app.name }
        $source = ''
        if ($app.PSObject.Properties['source']) { $source = [string]$app.source }

        [pscustomobject]@{
            Name   = $name
            Id     = $app.id.Trim()
            Source = $source
        }
    }
}

function Test-WingetAvailable {
    return [bool](Get-Command -Name winget -ErrorAction SilentlyContinue)
}

function Get-WingetResultText {
    <#
    .SYNOPSIS
        แปลง Exit Code ของ winget เป็นผลลัพธ์ที่อ่านง่าย
    #>
    param([Parameter(Mandatory)][int]$ExitCode)

    if ($ExitCode -eq 0) {
        return [pscustomobject]@{ Result = 'Installed'; Detail = 'ติดตั้งสำเร็จ' }
    }
    if ($ExitCode -eq $script:WingetExitCode.UpdateNotApplicable) {
        return [pscustomobject]@{ Result = 'Skipped'; Detail = 'ติดตั้งแล้ว (ไม่มีเวอร์ชันใหม่)' }
    }
    if ($ExitCode -eq $script:WingetExitCode.PackageAlreadyInstalled) {
        return [pscustomobject]@{ Result = 'Skipped'; Detail = 'ติดตั้งแล้ว' }
    }
    if ($ExitCode -eq $script:WingetExitCode.NoApplicationsFound) {
        return [pscustomobject]@{ Result = 'Failed'; Detail = 'ไม่พบ Package ID นี้ใน winget' }
    }
    return [pscustomobject]@{ Result = 'Failed'; Detail = ('winget exit code {0} (0x{0:X8})' -f $ExitCode) }
}

function Test-WingetPackageInstalled {
    <#
    .SYNOPSIS
        ตรวจว่าติดตั้ง Package นี้แล้วหรือยัง (winget list คืน 0 เมื่อพบ)
    #>
    param([Parameter(Mandatory)][string]$Id)

    & winget list --id $Id --exact --accept-source-agreements 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Install-WingetPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Source = ''
    )

    if (-not $PSCmdlet.ShouldProcess($Id, 'winget install')) { return }

    $wingetArgs = @('install', '--id', $Id, '--exact', '--silent',
        '--accept-package-agreements', '--accept-source-agreements')
    if ($Source) { $wingetArgs += @('--source', $Source) }

    $output = & winget @wingetArgs 2>&1
    $code = $LASTEXITCODE
    $result = Get-WingetResultText -ExitCode $code
    $lastLine = @($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) | Select-Object -Last 1
    return [pscustomobject]@{
        ExitCode = $code
        Result   = $result.Result
        Detail   = $result.Detail
        Output   = [string]$lastLine
    }
}

function Install-AppList {
    <#
    .SYNOPSIS
        ติดตั้งทุกโปรแกรมในรายการ ทีละรายการ แล้วคืนผลสรุป
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Apps)

    $total = $Apps.Count
    $i = 0
    foreach ($app in $Apps) {
        $i++
        $percent = [int](($i - 1) / [math]::Max($total, 1) * 100)
        Write-Progress -Activity 'New PC Setup' -Status ('[{0}/{1}] {2}' -f $i, $total, $app.Name) -PercentComplete $percent
        Write-Host ('  [{0}/{1}] {2} ({3}) ... ' -f $i, $total, $app.Name, $app.Id) -NoNewline

        if (Test-WingetPackageInstalled -Id $app.Id) {
            Write-Host 'ติดตั้งแล้ว ข้าม' -ForegroundColor DarkGray
            $row = [pscustomobject]@{ Name = $app.Name; Id = $app.Id; Result = 'Skipped'; Detail = 'ติดตั้งแล้ว' }
        }
        elseif ($PSCmdlet.ShouldProcess($app.Id, 'Install')) {
            $r = Install-WingetPackage -Id $app.Id -Source $app.Source -Confirm:$false
            $row = [pscustomobject]@{ Name = $app.Name; Id = $app.Id; Result = $r.Result; Detail = $r.Detail }
            switch ($r.Result) {
                'Installed' { Write-Host $r.Detail -ForegroundColor Green }
                'Skipped'   { Write-Host $r.Detail -ForegroundColor DarkGray }
                default     { Write-Host "$($r.Detail) $($r.Output)" -ForegroundColor Red }
            }
        }
        else {
            continue
        }

        Write-ToolkitLog -Level $(if ($row.Result -eq 'Failed') { 'ERROR' } else { 'INFO' }) `
            -Message "NewPCSetup: $($app.Id) = $($row.Result) ($($row.Detail))"
        $row
    }
    Write-Progress -Activity 'New PC Setup' -Completed
}

function Set-ShowFileExtension {
    <#
    .SYNOPSIS
        ให้ File Explorer แสดงนามสกุลไฟล์ (ของผู้ใช้ปัจจุบัน)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    if ($PSCmdlet.ShouldProcess($key, 'HideFileExt = 0')) {
        Set-ItemProperty -Path $key -Name 'HideFileExt' -Value 0 -Type DWord -ErrorAction Stop
        Write-ToolkitLog -Message 'NewPCSetup: เปิดการแสดงนามสกุลไฟล์'
    }
}

function Set-ToolkitPowerPlan {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet('Balanced', 'HighPerformance', 'PowerSaver')][string]$Plan)

    $guid = $script:PowerPlanGuid[$Plan]
    if ($PSCmdlet.ShouldProcess($Plan, 'powercfg /setactive')) {
        $output = & powercfg.exe /setactive $guid 2>&1
        if ($LASTEXITCODE -ne 0) {
            # เครื่องที่ใช้ Modern Standby อาจไม่มี Power Plan อื่นนอกจาก Balanced
            throw "ตั้ง Power Plan $Plan ไม่สำเร็จ: $($output -join ' ')"
        }
        Write-ToolkitLog -Message "NewPCSetup: ตั้ง Power Plan เป็น $Plan"
    }
}

function Invoke-BasicSetting {
    <#
    .SYNOPSIS
        ตั้งค่าพื้นฐานตาม settings.json (newPcSetup) หลังผู้ใช้ยืนยัน
    #>
    [CmdletBinding()]
    param()

    $config = (Get-ToolkitSetting).newPcSetup
    $tasks = @()
    if ($config.showFileExtensions) { $tasks += 'แสดงนามสกุลไฟล์' }
    if ($config.powerPlan) { $tasks += "Power Plan = $($config.powerPlan)" }
    if ($tasks.Count -eq 0) { return }

    if (-not (Confirm-ToolkitAction -Message "  ตั้งค่าพื้นฐานด้วยไหม? ($($tasks -join ', '))")) { return }

    if ($config.showFileExtensions) {
        try {
            Set-ShowFileExtension -Confirm:$false
            Write-StatusLine -Status Pass -Message 'แสดงนามสกุลไฟล์แล้ว (มีผลเมื่อเปิด File Explorer ใหม่)'
        }
        catch { Write-StatusLine -Status Fail -Message "แสดงนามสกุลไฟล์ไม่สำเร็จ: $($_.Exception.Message)" }
    }
    if ($config.powerPlan) {
        try {
            Set-ToolkitPowerPlan -Plan $config.powerPlan -Confirm:$false
            Write-StatusLine -Status Pass -Message "ตั้ง Power Plan เป็น $($config.powerPlan) แล้ว"
        }
        catch { Write-StatusLine -Status Fail -Message $_.Exception.Message }
    }
}

function Export-NewPCSetupReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results)

    $htmlPath = Get-ReportFilePath -Name 'NewPCSetup' -Extension 'html'
    $statusMap = @{ Installed = 'Pass'; Skipped = 'Skip'; Failed = 'Fail' }
    $rows = $Results | Select-Object Name, Id, @{ Name = 'Status'; Expression = { Get-StatusLabel $statusMap[$_.Result] } }, Detail

    $failed = @($Results | Where-Object Result -eq 'Failed').Count
    $overall = 'Pass'
    if ($failed -gt 0) { $overall = 'Fail' }
    $text = 'สำเร็จ {0} | ข้าม (มีอยู่แล้ว) {1} | ล้มเหลว {2}' -f @($Results | Where-Object Result -eq 'Installed').Count,
        @($Results | Where-Object Result -eq 'Skipped').Count, $failed

    $body = @(
        ConvertTo-HtmlBanner -Status $overall -Text $text
        ConvertTo-HtmlSection -Heading 'ผลการติดตั้งโปรแกรม' -Data @($rows)
    )
    return (Export-HtmlReport -Title 'New PC Setup Report' -Body $body -Path $htmlPath)
}

function Invoke-NewPCSetup {
    <#
    .SYNOPSIS
        เมนู [5] ติดตั้งโปรแกรมเครื่องใหม่
    #>
    [CmdletBinding()]
    param()

    Write-SectionHeader -Title 'New PC Setup'

    if (-not (Test-WingetAvailable)) {
        Write-StatusLine -Status Fail -Message 'ไม่พบ winget: ติดตั้ง/อัปเดต "App Installer" จาก Microsoft Store ก่อน'
        Write-ToolkitLog -Level ERROR -Message 'NewPCSetup: ไม่พบ winget'
        return
    }
    if (-not (Test-IsAdministrator)) {
        Write-StatusLine -Status Warn -Message 'ไม่ได้รันแบบ Admin: บางโปรแกรมอาจเด้งหน้าต่าง UAC หรือติดตั้งไม่สำเร็จ'
    }

    $apps = @(Read-AppList)
    Write-StatusLine -Status Info -Message ('รายการจาก config/apps.json ({0} โปรแกรม):' -f $apps.Count)
    $apps | Format-Table Name, Id -AutoSize | Out-Host

    if ($apps.Count -gt 0 -and (Confirm-ToolkitAction -Message '  เริ่มติดตั้งเลยไหม?')) {
        Write-ToolkitLog -Message "NewPCSetup: เริ่มติดตั้ง $($apps.Count) รายการ"
        $results = @(Install-AppList -Apps $apps -Confirm:$false)

        $installed = @($results | Where-Object Result -eq 'Installed').Count
        $skipped   = @($results | Where-Object Result -eq 'Skipped').Count
        $failed    = @($results | Where-Object Result -eq 'Failed')
        Write-Host ''
        Write-StatusLine -Status $(if ($failed.Count) { 'Warn' } else { 'Pass' }) `
            -Message ('สรุป: ติดตั้งสำเร็จ {0} | ข้าม (มีอยู่แล้ว) {1} | ล้มเหลว {2}' -f $installed, $skipped, $failed.Count)
        foreach ($f in $failed) { Write-StatusLine -Status Fail -Message "$($f.Name): $($f.Detail)" }

        $report = Export-NewPCSetupReport -Results $results
        Write-StatusLine -Status Info -Message "รายงาน HTML: $report"
    }

    Invoke-BasicSetting
}
