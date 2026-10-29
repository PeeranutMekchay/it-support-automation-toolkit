<#
.SYNOPSIS
    System Info Report: เก็บข้อมูลเครื่องแล้ว Export เป็น HTML และ CSV
.DESCRIPTION
    ดึงข้อมูลผ่าน CIM (Get-CimInstance) และ Get-NetIPConfiguration
    รายการโปรแกรมอ่านจาก Registry (Uninstall key) แทน Win32_Product
    เพราะ Win32_Product ช้ามากและสั่งให้ Windows Installer ตรวจซ่อมทุกโปรแกรม MSI
#>

function Format-Uptime {
    <#
    .SYNOPSIS
        แปลง TimeSpan เป็นข้อความ เช่น "3 วัน 4 ชั่วโมง 5 นาที"
    #>
    param([Parameter(Mandatory)][timespan]$Uptime)

    return '{0} วัน {1} ชั่วโมง {2} นาที' -f [math]::Floor($Uptime.TotalDays), $Uptime.Hours, $Uptime.Minutes
}

function ConvertFrom-InstallDate {
    <#
    .SYNOPSIS
        แปลงวันที่ติดตั้งจาก Registry (yyyyMMdd) เป็น yyyy-MM-dd ถ้าแปลงไม่ได้คืนค่าว่าง
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($Value.Trim(), 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$parsed)
    if ($ok) { return $parsed.ToString('yyyy-MM-dd') }
    return ''
}

function Get-InstalledApplication {
    <#
    .SYNOPSIS
        รายการโปรแกรมที่ติดตั้ง (ทั้ง 64-bit, 32-bit และของผู้ใช้ปัจจุบัน)
    #>
    [CmdletBinding()]
    param()

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object {
            # ซ่อน Component ของระบบและ Update ย่อยที่ไม่ได้แสดงใน "Apps & features"
            $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -and
            -not ($_.PSObject.Properties['SystemComponent'] -and $_.SystemComponent -eq 1) -and
            -not $_.PSObject.Properties['ParentKeyName']
        } |
        ForEach-Object {
            $app = $_
            [pscustomobject]@{
                Name        = $app.DisplayName.Trim()
                Version     = [string]$app.DisplayVersion
                Publisher   = [string]$app.Publisher
                InstallDate = ConvertFrom-InstallDate -Value ([string]$app.InstallDate)
            }
        } |
        Sort-Object -Property Name, Version -Unique
}

function Get-NetworkConfigurationSummary {
    <#
    .SYNOPSIS
        IP, MAC, Gateway, DNS ของการ์ดเครือข่ายที่เชื่อมต่ออยู่
    #>
    [CmdletBinding()]
    param()

    Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' } |
        ForEach-Object {
            $cfg = $_
            $ipInterface = Get-NetIPInterface -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $dhcp = 'ไม่ทราบ'
            if ($ipInterface) {
                if ($ipInterface.Dhcp -eq 'Enabled') { $dhcp = 'DHCP' } else { $dhcp = 'Static' }
            }
            $dns = @($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses })

            [pscustomobject]@{
                Adapter     = $cfg.InterfaceAlias
                Description = $cfg.InterfaceDescription
                IPv4        = (@($cfg.IPv4Address) | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength }) -join ', '
                Mode        = $dhcp
                MACAddress  = $cfg.NetAdapter.MacAddress
                Gateway     = (@($cfg.IPv4DefaultGateway) | ForEach-Object { $_.NextHop }) -join ', '
                DNS         = $dns -join ', '
                LinkSpeed   = $cfg.NetAdapter.LinkSpeed
            }
        }
}

function Get-SystemInfo {
    <#
    .SYNOPSIS
        เก็บข้อมูลเครื่องทั้งหมดเป็น Object เดียว
    .PARAMETER SkipApplications
        ไม่ต้องเก็บรายการโปรแกรม (เร็วขึ้น)
    #>
    [CmdletBinding()]
    param([switch]$SkipApplications)

    $cs   = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $os   = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $cpus = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
    $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)
    $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)
    $ntInfo = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

    $build = [string]$os.BuildNumber
    if ($ntInfo -and $ntInfo.PSObject.Properties['UBR']) { $build = '{0}.{1}' -f $os.BuildNumber, $ntInfo.UBR }
    $displayVersion = ''
    if ($ntInfo -and $ntInfo.PSObject.Properties['DisplayVersion']) { $displayVersion = $ntInfo.DisplayVersion }
    elseif ($ntInfo -and $ntInfo.PSObject.Properties['ReleaseId']) { $displayVersion = $ntInfo.ReleaseId }

    if ($cs.PartOfDomain) { $membership = 'Domain: {0}' -f $cs.Domain }
    else { $membership = 'Workgroup: {0}' -f $cs.Workgroup }

    $loggedOn = $cs.UserName
    if ([string]::IsNullOrWhiteSpace($loggedOn)) { $loggedOn = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME }

    $cpuNames = ($cpus | ForEach-Object { $_.Name.Trim() }) -join ' / '
    $cores    = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
    $threads  = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

    $summary = [pscustomobject]@{
        ComputerName      = $cs.Name
        LoggedOnUser      = $loggedOn
        DomainOrWorkgroup = $membership
        OperatingSystem   = $os.Caption
        Version           = $displayVersion
        Build             = $build
        Architecture      = $os.OSArchitecture
        InstallDate       = '{0:yyyy-MM-dd}' -f $os.InstallDate
        LastBoot          = '{0:yyyy-MM-dd HH:mm}' -f $os.LastBootUpTime
        Uptime            = Format-Uptime -Uptime ((Get-Date) - $os.LastBootUpTime)
        Manufacturer      = $cs.Manufacturer
        Model             = $cs.Model
        SerialNumber      = if ($bios) { $bios.SerialNumber } else { '' }
        BIOSVersion       = if ($bios) { $bios.SMBIOSBIOSVersion } else { '' }
        CPU               = $cpuNames
        CoresThreads      = '{0} Cores / {1} Threads' -f $cores, $threads
        RAM               = Format-ByteSize -Bytes $cs.TotalPhysicalMemory
    }

    $diskInfo = foreach ($d in $disks) {
        $freePercent = 0
        if ($d.Size -gt 0) { $freePercent = [math]::Round(($d.FreeSpace / $d.Size) * 100, 1) }
        [pscustomobject]@{
            Drive       = $d.DeviceID
            Label       = $d.VolumeName
            FileSystem  = $d.FileSystem
            Size        = Format-ByteSize -Bytes $d.Size
            Free        = Format-ByteSize -Bytes $d.FreeSpace
            FreePercent = $freePercent
        }
    }

    $gpuInfo = foreach ($g in $gpus) {
        $resolution = ''
        if ($g.CurrentHorizontalResolution) {
            $resolution = '{0} x {1}' -f $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution
        }
        [pscustomobject]@{
            Name          = $g.Name
            DriverVersion = $g.DriverVersion
            Resolution    = $resolution
        }
    }

    $apps = @()
    if (-not $SkipApplications) { $apps = @(Get-InstalledApplication) }

    return [pscustomobject]@{
        CollectedAt  = Get-Date
        Summary      = $summary
        Disks        = @($diskInfo)
        GPUs         = @($gpuInfo)
        Network      = @(Get-NetworkConfigurationSummary)
        Applications = $apps
    }
}

function Export-SystemInfoReport {
    <#
    .SYNOPSIS
        Export ข้อมูลเครื่องเป็น HTML 1 ไฟล์ และ CSV 2 ไฟล์ (สรุป + รายการโปรแกรม)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Info)

    $timestamp = $Info.CollectedAt
    $htmlPath = Get-ReportFilePath -Name 'SystemInfo' -Extension 'html' -Timestamp $timestamp
    $csvPath  = Get-ReportFilePath -Name 'SystemInfo' -Extension 'csv' -Timestamp $timestamp
    $appsPath = Get-ReportFilePath -Name 'InstalledApps' -Extension 'csv' -Timestamp $timestamp

    $body = @(
        ConvertTo-HtmlSection -Heading 'ข้อมูลเครื่อง' -Data @($Info.Summary) -AsList
        ConvertTo-HtmlSection -Heading 'ดิสก์' -Data $Info.Disks
        ConvertTo-HtmlSection -Heading 'การ์ดจอ (GPU)' -Data $Info.GPUs
        ConvertTo-HtmlSection -Heading 'เครือข่าย' -Data $Info.Network -EmptyText 'ไม่พบการ์ดเครือข่ายที่เชื่อมต่ออยู่'
        ConvertTo-HtmlSection -Heading ('โปรแกรมที่ติดตั้ง ({0} รายการ)' -f @($Info.Applications).Count) -Data $Info.Applications
    )
    Export-HtmlReport -Title 'System Info Report' -Body $body -Path $htmlPath | Out-Null

    $rows = @()
    $rows += ConvertTo-PropertyRow -InputObject $Info.Summary -Section 'System'
    $i = 0
    foreach ($d in $Info.Disks) { $i++; $rows += ConvertTo-PropertyRow -InputObject $d -Section "Disk $i" }
    $i = 0
    foreach ($g in $Info.GPUs) { $i++; $rows += ConvertTo-PropertyRow -InputObject $g -Section "GPU $i" }
    $i = 0
    foreach ($n in $Info.Network) { $i++; $rows += ConvertTo-PropertyRow -InputObject $n -Section "Network $i" }
    Export-ToolkitCsv -InputObject $rows -Path $csvPath | Out-Null
    Export-ToolkitCsv -InputObject $Info.Applications -Path $appsPath | Out-Null

    return [pscustomobject]@{ Html = $htmlPath; Csv = $csvPath; AppsCsv = $appsPath }
}

function Invoke-SystemInfoReport {
    <#
    .SYNOPSIS
        เมนู [1] เก็บข้อมูล แสดงสรุป และสร้างรายงาน
    #>
    [CmdletBinding()]
    param([switch]$NoOpen)

    Write-SectionHeader -Title 'System Info Report'
    Write-StatusLine -Status Info -Message 'กำลังเก็บข้อมูลเครื่อง...'
    Write-ToolkitLog -Message 'SystemInfo: เริ่มเก็บข้อมูล'

    $info = Get-SystemInfo
    $info.Summary | Format-List | Out-Host
    if ($info.Disks) { $info.Disks | Format-Table -AutoSize | Out-Host }
    if ($info.Network) { $info.Network | Format-Table Adapter, IPv4, Mode, MACAddress, Gateway, DNS -AutoSize | Out-Host }
    Write-StatusLine -Status Info -Message ('พบโปรแกรมที่ติดตั้ง {0} รายการ' -f @($info.Applications).Count)

    $files = Export-SystemInfoReport -Info $info
    Write-StatusLine -Status Pass -Message "รายงาน HTML: $($files.Html)"
    Write-StatusLine -Status Pass -Message "CSV สรุป: $($files.Csv)"
    Write-StatusLine -Status Pass -Message "CSV โปรแกรม: $($files.AppsCsv)"
    Write-ToolkitLog -Message "SystemInfo: สร้างรายงาน $($files.Html)"

    if (-not $NoOpen -and (Confirm-ToolkitAction -Message 'เปิดรายงาน HTML เลยไหม?')) {
        Invoke-Item -LiteralPath $files.Html
    }
    return $files
}
