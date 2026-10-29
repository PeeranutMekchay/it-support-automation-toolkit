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

function Get-RegistryValueSafe {
    <#
    .SYNOPSIS
        อ่านค่า Registry 1 ค่า ถ้าค่าเสียหรืออ่านไม่ได้จะคืน $null แทนการโยน Error
    #>
    param(
        [Parameter(Mandatory)][object]$Key,
        [Parameter(Mandatory)][string]$Name
    )

    try { return $Key.GetValue($Name) }
    catch { return $null }
}

function Get-InstalledApplication {
    <#
    .SYNOPSIS
        รายการโปรแกรมที่ติดตั้ง (ทั้ง 64-bit, 32-bit และของผู้ใช้ปัจจุบัน)
    .NOTES
        อ่าน Registry ผ่าน .NET ทีละ Key แทน Get-ItemProperty เพราะถ้ามีโปรแกรมใดเขียนค่า Registry
        ผิดรูปแบบไว้ Get-ItemProperty จะโยน "Specified cast is not valid" จน -ErrorAction ก็กันไม่ได้
    #>
    [CmdletBinding()]
    param()

    $uninstallPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $sources = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64 }
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32 }
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Default }
    )

    $apps = foreach ($source in $sources) {
        $baseKey = $null
        $uninstallKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($source.Hive, $source.View)
            $uninstallKey = $baseKey.OpenSubKey($uninstallPath)
            if (-not $uninstallKey) { continue }

            foreach ($subKeyName in $uninstallKey.GetSubKeyNames()) {
                $appKey = $null
                try {
                    $appKey = $uninstallKey.OpenSubKey($subKeyName)
                    if (-not $appKey) { continue }

                    $displayName = [string](Get-RegistryValueSafe -Key $appKey -Name 'DisplayName')
                    if ([string]::IsNullOrWhiteSpace($displayName)) { continue }
                    # ซ่อน Component ของระบบและ Update ย่อยที่ไม่ได้แสดงใน "Apps & features"
                    if ("$(Get-RegistryValueSafe -Key $appKey -Name 'SystemComponent')" -eq '1') { continue }
                    if ($null -ne (Get-RegistryValueSafe -Key $appKey -Name 'ParentKeyName')) { continue }

                    [pscustomobject]@{
                        Name        = $displayName.Trim()
                        Version     = [string](Get-RegistryValueSafe -Key $appKey -Name 'DisplayVersion')
                        Publisher   = [string](Get-RegistryValueSafe -Key $appKey -Name 'Publisher')
                        InstallDate = ConvertFrom-InstallDate -Value ([string](Get-RegistryValueSafe -Key $appKey -Name 'InstallDate'))
                    }
                }
                catch {
                    Write-Verbose "อ่าน Registry ของ $subKeyName ไม่ได้: $($_.Exception.Message)"
                }
                finally {
                    if ($appKey) { $appKey.Close() }
                }
            }
        }
        catch {
            Write-Verbose "อ่าน Registry $($source.Hive) ($($source.View)) ไม่ได้: $($_.Exception.Message)"
        }
        finally {
            if ($uninstallKey) { $uninstallKey.Close() }
            if ($baseKey) { $baseKey.Close() }
        }
    }

    $apps | Sort-Object -Property Name, Version -Unique
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
    if (-not $SkipApplications) {
        try { $apps = @(Get-InstalledApplication) }
        catch { Write-ToolkitLog -Level WARN -Message "SystemInfo: อ่านรายการโปรแกรมไม่สำเร็จ - $($_.Exception.Message)" }
    }
    $network = @()
    try { $network = @(Get-NetworkConfigurationSummary) }
    catch { Write-ToolkitLog -Level WARN -Message "SystemInfo: อ่านข้อมูลเครือข่ายไม่สำเร็จ - $($_.Exception.Message)" }

    return [pscustomobject]@{
        CollectedAt  = Get-Date
        Summary      = $summary
        Disks        = @($diskInfo)
        GPUs         = @($gpuInfo)
        Network      = $network
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
