#Requires -Version 5.1
<#
.SYNOPSIS
    IT Support Automation Toolkit - เมนูหลัก
.DESCRIPTION
    รวมเครื่องมือ IT Support ไว้ในเมนูเดียว:
    [1] System Info Report   [2] Health Check   [3] Network Troubleshooter
    [4] Cleanup Tool         [5] New PC Setup   [6] เปิดโฟลเดอร์รายงาน
.PARAMETER Run
    รันเครื่องมือเดียวแบบไม่มีเมนูและไม่ถามคำถาม (เหมาะกับ Task Scheduler)
    ใช้ได้กับ SystemInfo, HealthCheck, Network
    Exit Code ของ HealthCheck / Network: 0 = ผ่าน, 1 = ควรตรวจสอบ, 2 = มีปัญหา
.EXAMPLE
    .\Toolkit.ps1
.EXAMPLE
    .\Toolkit.ps1 -Run HealthCheck
#>
[CmdletBinding()]
param(
    [ValidateSet('SystemInfo', 'HealthCheck', 'Network')]
    [string]$Run
)

if ($env:OS -ne 'Windows_NT') {
    Write-Error 'IT Support Automation Toolkit ใช้งานได้บน Windows เท่านั้น'
    exit 1
}

try {
    # ให้ Console แสดงภาษาไทยได้ถูกต้อง
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}
catch {
    Write-Verbose 'ตั้งค่า Encoding ของ Console ไม่ได้'
}

$moduleDir = Join-Path $PSScriptRoot 'modules'
foreach ($module in 'Common', 'SystemInfo', 'HealthCheck', 'NetworkTroubleshooter', 'Cleanup', 'NewPCSetup') {
    . (Join-Path $moduleDir "$module.ps1")
}
Initialize-Toolkit

function Show-MainMenu {
    param([bool]$IsAdmin)

    Clear-Host
    $line = '=' * 42
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host '        IT Support Automation Toolkit' -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkCyan
    if ($IsAdmin) {
        Write-Host '  สิทธิ์: Administrator' -ForegroundColor Green
    }
    else {
        Write-Host '  สิทธิ์: ผู้ใช้ทั่วไป (เมนูที่มี * ใช้ได้บางส่วน)' -ForegroundColor Yellow
    }
    Write-Host ('  เครื่อง: {0}   ผู้ใช้: {1}' -f $env:COMPUTERNAME, $env:USERNAME) -ForegroundColor DarkGray
    Write-Host $line -ForegroundColor DarkCyan

    $mark = ''
    if (-not $IsAdmin) { $mark = ' *' }
    Write-Host '  [1] System Info Report'
    Write-Host '  [2] Health Check'
    Write-Host "  [3] Network Troubleshooter$mark"
    Write-Host "  [4] Cleanup Tool$mark"
    Write-Host "  [5] New PC Setup$mark"
    Write-Host '  [6] เปิดโฟลเดอร์รายงาน'
    if (-not $IsAdmin) {
        Write-Host '  [9] เปิด Toolkit ใหม่ด้วยสิทธิ์ Administrator' -ForegroundColor Yellow
    }
    Write-Host '  [0] ออก'
    Write-Host $line -ForegroundColor DarkCyan
}

function Show-AdminNotice {
    param(
        [bool]$IsAdmin,
        [string]$Message
    )

    if (-not $IsAdmin) {
        Write-Host ''
        Write-StatusLine -Status Warn -Message $Message
    }
}

function Start-ElevatedToolkit {
    <#
    .SYNOPSIS
        เปิด Toolkit หน้าต่างใหม่ด้วยสิทธิ์ Administrator (ขึ้น UAC)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $hostExe = (Get-Process -Id $PID).Path
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    if ($PSCmdlet.ShouldProcess($hostExe, 'Run as Administrator')) {
        Start-Process -FilePath $hostExe -ArgumentList $arguments -Verb RunAs -ErrorAction Stop
        Write-ToolkitLog -Message 'Menu: เปิด Toolkit ใหม่ด้วยสิทธิ์ Admin'
    }
}

function Get-StatusExitCode {
    param([string]$Status)

    switch ($Status) {
        'Pass' { return 0 }
        'Warn' { return 1 }
        default { return 2 }
    }
}

$isAdmin = Test-IsAdministrator
Write-ToolkitLog -Message ('Toolkit เริ่มทำงาน (PowerShell {0}, Admin={1}, Run={2})' -f $PSVersionTable.PSVersion, $isAdmin, $Run)

# ---------- โหมดไม่มีเมนู ----------
if ($Run) {
    $exitCode = 0
    try {
        switch ($Run) {
            'SystemInfo' {
                Invoke-SystemInfoReport -NoOpen | Out-Null
            }
            'HealthCheck' {
                $files = Invoke-HealthCheckMenu -NoOpen
                $exitCode = Get-StatusExitCode -Status $files.Overall
            }
            'Network' {
                $results = Invoke-NetworkTroubleshooter -NoInteractive
                $exitCode = Get-StatusExitCode -Status (Get-NetworkDiagnosisSummary -Results $results).Status
            }
        }
    }
    catch {
        Write-ToolkitLog -Level ERROR -Message "$Run ล้มเหลว: $($_.Exception.Message)"
        Write-Error $_
        $exitCode = 2
    }
    Write-ToolkitLog -Message "Toolkit จบการทำงาน ($Run, exit=$exitCode)"
    exit $exitCode
}

# ---------- โหมดเมนู ----------
while ($true) {
    Show-MainMenu -IsAdmin $isAdmin
    $choice = (Read-Host 'เลือกเมนู').Trim()
    Write-ToolkitLog -Message "Menu: เลือก '$choice'"

    if ($choice -eq '0') { break }

    try {
        switch ($choice) {
            '1' { Invoke-SystemInfoReport | Out-Null }
            '2' { Invoke-HealthCheckMenu | Out-Null }
            '3' {
                Show-AdminNotice -IsAdmin $isAdmin -Message 'Release / Renew IP ต้องใช้สิทธิ์ Admin (การตรวจทำได้ปกติ)'
                Invoke-NetworkTroubleshooter | Out-Null
            }
            '4' { Invoke-CleanupTool }
            '5' {
                Show-AdminNotice -IsAdmin $isAdmin -Message 'แนะนำให้รันแบบ Admin เพื่อติดตั้งโปรแกรมแบบทั้งเครื่อง'
                Invoke-NewPCSetup
            }
            '6' {
                Invoke-Item -LiteralPath $script:ReportDir
                Write-ToolkitLog -Message 'Menu: เปิดโฟลเดอร์รายงาน'
            }
            '9' {
                if ($isAdmin) { Write-StatusLine -Status Info -Message 'รันด้วยสิทธิ์ Admin อยู่แล้ว' }
                elseif (Confirm-ToolkitAction -Message 'เปิด Toolkit ใหม่ด้วยสิทธิ์ Administrator แล้วปิดหน้าต่างนี้?') {
                    Start-ElevatedToolkit -Confirm:$false
                    Write-ToolkitLog -Message 'Toolkit จบการทำงาน (เปิดใหม่แบบ Admin)'
                    exit 0
                }
            }
            default {
                Write-StatusLine -Status Warn -Message 'ไม่มีเมนูนี้ กรุณาเลือกใหม่'
            }
        }
    }
    catch {
        Write-StatusLine -Status Fail -Message "เกิดข้อผิดพลาด: $($_.Exception.Message)"
        Write-Host ('         ที่ {0} บรรทัด {1}' -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber) -ForegroundColor DarkGray
        Write-ToolkitLog -Level ERROR -Message "Menu '$choice' ล้มเหลว: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
    }

    Write-Host ''
    Read-Host 'กด Enter เพื่อกลับเมนูหลัก' | Out-Null
}

Write-ToolkitLog -Message 'Toolkit จบการทำงาน'
