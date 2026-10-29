<#
.SYNOPSIS
    Network Troubleshooter: ไล่ตรวจเครือข่ายตามลำดับขั้นการ Troubleshoot จริง
.DESCRIPTION
    1. การ์ดเครือข่ายเปิดอยู่และเชื่อมต่อหรือไม่
    2. ได้ IP จาก DHCP หรือไม่ (169.254.x.x = APIPA = ติดต่อ DHCP ไม่ได้)
    3. Ping Default Gateway ได้หรือไม่
    4. Ping อินเทอร์เน็ตด้วย IP ได้หรือไม่
    5. แปลงชื่อโดเมนผ่าน DNS ได้หรือไม่
    6. เปิดเว็บไซต์ (Port 443) ได้หรือไม่
    หยุดที่ขั้นแรกที่ล้มเหลว เพราะขั้นถัดไปจะล้มตามอยู่แล้ว แล้วแนะนำวิธีแก้ของขั้นนั้น
#>

$script:NetworkStepNames = @{
    1 = 'การ์ดเครือข่าย (Network Adapter)'
    2 = 'IP Address (DHCP)'
    3 = 'Ping Default Gateway'
    4 = 'Ping อินเทอร์เน็ตด้วย IP'
    5 = 'DNS (แปลงชื่อโดเมน)'
    6 = 'เชื่อมต่อเว็บไซต์ (HTTPS)'
}

function Test-ApipaAddress {
    <#
    .SYNOPSIS
        True ถ้าเป็น IP แบบ APIPA (169.254.x.x) ซึ่ง Windows ตั้งเองเมื่อขอ IP จาก DHCP ไม่ได้
    #>
    param([AllowNull()][AllowEmptyString()][string]$IPAddress)

    if ([string]::IsNullOrWhiteSpace($IPAddress)) { return $false }
    return ($IPAddress.Trim() -match '^169\.254\.\d{1,3}\.\d{1,3}$')
}

function Get-NetworkStepAdvice {
    <#
    .SYNOPSIS
        คำแนะนำการแก้ไขตามขั้นที่ล้มเหลว
    #>
    param([Parameter(Mandatory)][ValidateRange(1, 6)][int]$Step)

    switch ($Step) {
        1 { return 'ตรวจสาย LAN / เปิด Wi-Fi / ปิดโหมดเครื่องบิน, Enable การ์ดใน ncpa.cpl, ตรวจไดรเวอร์ใน Device Manager' }
        2 { return 'ได้ IP 169.254.x.x หรือไม่มี IP แปลว่าติดต่อ DHCP ไม่ได้: ลอง Release/Renew IP, ตรวจสาย/Switch/Access Point และ DHCP Server' }
        3 { return 'ติดต่อ Router ไม่ได้: ตรวจสาย/สัญญาณ Wi-Fi, Restart Router หรือ Switch, ตรวจว่าอยู่ VLAN / SSID ที่ถูกต้อง' }
        4 { return 'ออกอินเทอร์เน็ตไม่ได้: ตรวจ Router / ISP, Firewall ขาออก หรือสอบถามทีม Network ว่ามีเหตุขัดข้องหรือไม่' }
        5 { return 'DNS มีปัญหา: ลอง Flush DNS, ตรวจ DNS Server ในการ์ดเครือข่าย หรือทดลองใช้ DNS 8.8.8.8 / 1.1.1.1 ชั่วคราว' }
        6 { return 'เปิดเว็บไม่ได้แต่ DNS ปกติ: ตรวจ Proxy (inetcpl.cpl), Firewall/Antivirus, วันเวลาเครื่อง (มีผลกับ HTTPS) หรือเว็บปลายทางล่ม' }
    }
}

function New-NetworkStepResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'สร้าง Object ในหน่วยความจำเท่านั้น ไม่ได้เปลี่ยนแปลงระบบ')]
    param(
        [Parameter(Mandatory)][int]$Step,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Warn', 'Fail', 'Skip')][string]$Status,
        [string]$Detail = ''
    )

    $advice = ''
    if ($Status -eq 'Fail') { $advice = Get-NetworkStepAdvice -Step $Step }
    return [pscustomobject]@{
        Step   = $Step
        Name   = $script:NetworkStepNames[$Step]
        Status = $Status
        Detail = $Detail
        Advice = $advice
    }
}

function Test-PingHost {
    <#
    .SYNOPSIS
        Ping แล้วคืน True/False (ใช้ได้ทั้ง PowerShell 5.1 และ 7)
    #>
    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$Count = 2
    )

    try {
        return [bool](Test-Connection -ComputerName $Target -Count $Count -Quiet -ErrorAction Stop)
    }
    catch {
        return $false
    }
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][int]$Port
    )

    try {
        return [bool](Test-NetConnection -ComputerName $Target -Port $Port -InformationLevel Quiet `
                -WarningAction SilentlyContinue -ErrorAction Stop)
    }
    catch {
        return $false
    }
}

# ---------- แต่ละขั้น (รับ $Context ร่วมกันเพื่อส่งข้อมูลไปขั้นถัดไป) ----------

function Test-NetStepAdapter {
    param([Parameter(Mandatory)][hashtable]$Context)

    $configs = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' })
    if ($configs.Count -eq 0) {
        $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { '{0} = {1}' -f $_.Name, $_.Status })
        $list = 'ไม่พบการ์ดเครือข่ายแบบ Physical'
        if ($adapters.Count -gt 0) { $list = $adapters -join ', ' }
        return New-NetworkStepResult -Step 1 -Status Fail -Detail "ไม่มีการ์ดที่เชื่อมต่ออยู่ ($list)"
    }

    # เลือกการ์ดที่มี Default Gateway ก่อน (คือการ์ดที่ใช้ออกเน็ตจริง)
    $selected = $configs | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
    if (-not $selected) { $selected = $configs[0] }
    $Context.Config = $selected

    return New-NetworkStepResult -Step 1 -Status Pass -Detail ('{0} - {1} ({2})' -f $selected.InterfaceAlias,
        $selected.InterfaceDescription, $selected.NetAdapter.LinkSpeed)
}

function Test-NetStepIPAddress {
    param([Parameter(Mandatory)][hashtable]$Context)

    $ips = @($Context.Config.IPv4Address | ForEach-Object { $_.IPAddress } | Where-Object { $_ })
    if ($ips.Count -eq 0) {
        return New-NetworkStepResult -Step 2 -Status Fail -Detail "การ์ด $($Context.Config.InterfaceAlias) ไม่มี IPv4 Address"
    }

    $ip = $ips[0]
    $Context.IPAddress = $ip
    if (Test-ApipaAddress -IPAddress $ip) {
        return New-NetworkStepResult -Step 2 -Status Fail -Detail "ได้ IP $ip (APIPA) = ขอ IP จาก DHCP Server ไม่สำเร็จ"
    }

    $mode = 'ไม่ทราบ'
    $ipInterface = Get-NetIPInterface -InterfaceIndex $Context.Config.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ipInterface) {
        if ($ipInterface.Dhcp -eq 'Enabled') { $mode = 'ได้จาก DHCP' } else { $mode = 'ตั้งแบบ Static' }
    }
    return New-NetworkStepResult -Step 2 -Status Pass -Detail "$ip ($mode)"
}

function Test-NetStepGateway {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [int]$Count = 2
    )

    $gateway = @($Context.Config.IPv4DefaultGateway | ForEach-Object { $_.NextHop } | Where-Object { $_ }) | Select-Object -First 1
    if (-not $gateway) {
        return New-NetworkStepResult -Step 3 -Status Fail -Detail 'ไม่มี Default Gateway (ตรวจการตั้งค่า IP หรือ DHCP)'
    }
    if (Test-PingHost -Target $gateway -Count $Count) {
        return New-NetworkStepResult -Step 3 -Status Pass -Detail "Ping $gateway สำเร็จ"
    }
    return New-NetworkStepResult -Step 3 -Status Fail -Detail "Ping $gateway ไม่ตอบสนอง"
}

function Test-NetStepInternet {
    param(
        [Parameter(Mandatory)][string]$TestIp,
        [int]$Count = 2
    )

    if (Test-PingHost -Target $TestIp -Count $Count) {
        return New-NetworkStepResult -Step 4 -Status Pass -Detail "Ping $TestIp สำเร็จ"
    }
    # บางองค์กรบล็อก ICMP ขาออก จึงลองเชื่อมต่อ TCP 53 ก่อนสรุปว่าออกเน็ตไม่ได้
    if (Test-TcpPort -Target $TestIp -Port 53) {
        return New-NetworkStepResult -Step 4 -Status Warn -Detail "Ping $TestIp ไม่ได้ แต่เชื่อมต่อ TCP 53 ได้ (Firewall น่าจะบล็อก ICMP)"
    }
    return New-NetworkStepResult -Step 4 -Status Fail -Detail "Ping $TestIp ไม่ได้ และเชื่อมต่อ TCP 53 ไม่ได้"
}

function Test-NetStepNameResolution {
    param([Parameter(Mandatory)][string]$Name)

    try {
        $records = @(Resolve-DnsName -Name $Name -Type A -DnsOnly -QuickTimeout -ErrorAction Stop |
            Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress })
    }
    catch {
        return New-NetworkStepResult -Step 5 -Status Fail -Detail "แปลงชื่อ $Name ไม่ได้: $($_.Exception.Message)"
    }
    if ($records.Count -eq 0) {
        return New-NetworkStepResult -Step 5 -Status Fail -Detail "DNS ไม่คืน IP ของ $Name"
    }
    return New-NetworkStepResult -Step 5 -Status Pass -Detail ('{0} -> {1}' -f $Name, (($records | Select-Object -First 3).IPAddress -join ', '))
}

function Test-NetStepWeb {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [int]$Port = 443
    )

    if (Test-TcpPort -Target $HostName -Port $Port) {
        return New-NetworkStepResult -Step 6 -Status Pass -Detail "เชื่อมต่อ ${HostName}:$Port สำเร็จ"
    }
    return New-NetworkStepResult -Step 6 -Status Fail -Detail "เชื่อมต่อ ${HostName}:$Port ไม่ได้"
}

function Invoke-NetworkDiagnosis {
    <#
    .SYNOPSIS
        รันการตรวจทั้ง 6 ขั้นตามลำดับ หยุดที่ขั้นแรกที่ล้มเหลว (ขั้นที่เหลือ = Skip)
    #>
    [CmdletBinding()]
    param([switch]$Quiet)

    $net = (Get-ToolkitSetting).network
    $context = @{}
    $results = New-Object System.Collections.Generic.List[object]
    $failed = $false

    foreach ($step in 1..6) {
        if ($failed) {
            $results.Add((New-NetworkStepResult -Step $step -Status Skip -Detail 'ข้าม เพราะขั้นก่อนหน้าล้มเหลว'))
            continue
        }
        if (-not $Quiet) {
            Write-Host ('  ขั้นที่ {0}: {1} ...' -f $step, $script:NetworkStepNames[$step]) -ForegroundColor DarkGray
        }

        try {
            switch ($step) {
                1 { $result = Test-NetStepAdapter -Context $context }
                2 { $result = Test-NetStepIPAddress -Context $context }
                3 { $result = Test-NetStepGateway -Context $context -Count $net.pingCount }
                4 { $result = Test-NetStepInternet -TestIp $net.internetTestIp -Count $net.pingCount }
                5 { $result = Test-NetStepNameResolution -Name $net.dnsTestName }
                6 { $result = Test-NetStepWeb -HostName $net.webTestHost -Port $net.webTestPort }
            }
        }
        catch {
            $result = New-NetworkStepResult -Step $step -Status Fail -Detail "ตรวจไม่สำเร็จ: $($_.Exception.Message)"
        }

        $results.Add($result)
        if (-not $Quiet) { Write-StatusLine -Status $result.Status -Message $result.Detail }
        if ($result.Status -eq 'Fail') { $failed = $true }
    }

    Write-ToolkitLog -Message ('Network: ' + (($results | ForEach-Object { '{0}={1}' -f $_.Step, $_.Status }) -join ' '))
    return $results.ToArray()
}

function Get-NetworkDiagnosisSummary {
    <#
    .SYNOPSIS
        สรุปว่าปัญหาอยู่ที่ขั้นไหน
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results)

    $firstFail = $Results | Where-Object { $_.Status -eq 'Fail' } | Select-Object -First 1
    if ($firstFail) {
        return [pscustomobject]@{
            Status  = 'Fail'
            Step    = $firstFail.Step
            Message = 'ปัญหาอยู่ที่ขั้นที่ {0}: {1}' -f $firstFail.Step, $firstFail.Name
            Advice  = $firstFail.Advice
        }
    }
    if ($Results | Where-Object { $_.Status -eq 'Warn' }) {
        return [pscustomobject]@{ Status = 'Warn'; Step = 0; Message = 'ใช้งานได้ แต่มีบางขั้นที่ควรตรวจสอบ'; Advice = '' }
    }
    return [pscustomobject]@{ Status = 'Pass'; Step = 0; Message = 'เครือข่ายปกติทุกขั้น'; Advice = '' }
}

function Export-NetworkReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results)

    $htmlPath = Get-ReportFilePath -Name 'Network' -Extension 'html'
    $summary = Get-NetworkDiagnosisSummary -Results $Results
    $rows = $Results | Select-Object Step, Name, @{ Name = 'Status'; Expression = { Get-StatusLabel $_.Status } }, Detail, Advice

    $bannerText = $summary.Message
    if ($summary.Advice) { $bannerText = "$bannerText — $($summary.Advice)" }

    $body = @(
        ConvertTo-HtmlBanner -Status $summary.Status -Text $bannerText
        ConvertTo-HtmlSection -Heading 'ผลการตรวจทีละขั้น' -Data @($rows)
        ConvertTo-HtmlSection -Heading 'การตั้งค่าเครือข่าย' -Data @(Get-NetworkConfigurationSummary) -EmptyText 'ไม่พบการ์ดที่เชื่อมต่ออยู่'
    )
    return (Export-HtmlReport -Title 'Network Troubleshooter Report' -Body $body -Path $htmlPath)
}

# ---------- การแก้ไขเบื้องต้น (ต้องยืนยันก่อนทุกครั้ง) ----------

function Clear-ToolkitDnsCache {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($PSCmdlet.ShouldProcess('DNS Client Cache', 'Flush')) {
        $output = & ipconfig.exe /flushdns 2>&1
        $ok = ($LASTEXITCODE -eq 0)
        Write-ToolkitLog -Level $(if ($ok) { 'INFO' } else { 'ERROR' }) -Message "Network: ipconfig /flushdns exit=$LASTEXITCODE"
        return [pscustomobject]@{ Success = $ok; Output = ($output -join "`n") }
    }
}

function Reset-ToolkitIPAddress {
    <#
    .SYNOPSIS
        ipconfig /release แล้ว /renew (ต้องใช้สิทธิ์ Admin เน็ตจะหลุดชั่วคราว)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($PSCmdlet.ShouldProcess('IPv4 ทุกการ์ด', 'Release / Renew')) {
        $release = & ipconfig.exe /release 2>&1
        $releaseCode = $LASTEXITCODE
        $renew = & ipconfig.exe /renew 2>&1
        $renewCode = $LASTEXITCODE
        $ok = ($renewCode -eq 0)
        Write-ToolkitLog -Level $(if ($ok) { 'INFO' } else { 'ERROR' }) -Message "Network: ipconfig /release exit=$releaseCode, /renew exit=$renewCode"
        return [pscustomobject]@{ Success = $ok; Output = (@($release) + @($renew)) -join "`n" }
    }
}

function Invoke-NetworkTroubleshooter {
    <#
    .SYNOPSIS
        เมนู [3] ตรวจเครือข่าย แสดงขั้นที่มีปัญหา และเสนอวิธีแก้เบื้องต้น
    #>
    [CmdletBinding()]
    param([switch]$NoInteractive)

    Write-SectionHeader -Title 'Network Troubleshooter'
    $results = Invoke-NetworkDiagnosis
    $summary = Get-NetworkDiagnosisSummary -Results $results

    Write-Host ''
    Write-StatusLine -Status $summary.Status -Message $summary.Message
    if ($summary.Advice) { Write-Host "         -> $($summary.Advice)" -ForegroundColor DarkYellow }

    $report = Export-NetworkReport -Results $results
    Write-StatusLine -Status Info -Message "รายงาน HTML: $report"

    if ($NoInteractive) { return $results }

    $isAdmin = Test-IsAdministrator
    while ($true) {
        Write-Host ''
        Write-Host '  ตัวเลือกแก้ไขเบื้องต้น' -ForegroundColor White
        Write-Host '  [1] Flush DNS (ipconfig /flushdns)'
        $adminNote = ''
        if (-not $isAdmin) { $adminNote = ' (ต้องใช้ Admin)' }
        Write-Host "  [2] Release / Renew IP$adminNote"
        Write-Host '  [3] ตรวจใหม่อีกครั้ง'
        Write-Host '  [0] กลับเมนูหลัก'
        $choice = Read-Host '  เลือก'

        switch ($choice) {
            '1' {
                if (Confirm-ToolkitAction -Message '  ยืนยันล้าง DNS Cache?') {
                    $r = Clear-ToolkitDnsCache -Confirm:$false
                    if ($r.Success) { Write-StatusLine -Status Pass -Message 'ล้าง DNS Cache แล้ว' }
                    else { Write-StatusLine -Status Fail -Message "ไม่สำเร็จ: $($r.Output)" }
                }
            }
            '2' {
                if (-not $isAdmin) {
                    Write-StatusLine -Status Warn -Message 'ต้องรัน Toolkit ด้วยสิทธิ์ Administrator ก่อน'
                    continue
                }
                if (Confirm-ToolkitAction -Message '  เน็ตจะหลุดชั่วคราว (รวมถึง Remote Session) ยืนยัน Release / Renew IP?') {
                    Write-StatusLine -Status Info -Message 'กำลัง Release / Renew IP...'
                    $r = Reset-ToolkitIPAddress -Confirm:$false
                    if ($r.Success) { Write-StatusLine -Status Pass -Message 'Renew IP สำเร็จ ลองตรวจใหม่ด้วยตัวเลือก [3]' }
                    else { Write-StatusLine -Status Fail -Message "Renew ไม่สำเร็จ: $($r.Output)" }
                }
            }
            '3' {
                $results = Invoke-NetworkDiagnosis
                $summary = Get-NetworkDiagnosisSummary -Results $results
                Write-StatusLine -Status $summary.Status -Message $summary.Message
                if ($summary.Advice) { Write-Host "         -> $($summary.Advice)" -ForegroundColor DarkYellow }
                $report = Export-NetworkReport -Results $results
                Write-StatusLine -Status Info -Message "รายงาน HTML: $report"
            }
            '0' { return $results }
            default { Write-StatusLine -Status Warn -Message 'กรุณาเลือก 0-3' }
        }
    }
}
