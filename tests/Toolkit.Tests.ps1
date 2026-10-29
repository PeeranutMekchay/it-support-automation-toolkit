#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit test ของฟังก์ชันที่ไม่แตะระบบจริง (รันได้ทุกเครื่องโดยไม่ต้องใช้ Admin)
    รัน:  Invoke-Pester -Path .\tests -Output Detailed
#>

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    foreach ($module in 'Common', 'SystemInfo', 'HealthCheck', 'NetworkTroubleshooter', 'Cleanup', 'NewPCSetup') {
        . (Join-Path (Join-Path $root 'modules') "$module.ps1")
    }
    $script:ReportDir = Join-Path $TestDrive 'reports'
    $script:LogDir = Join-Path $TestDrive 'logs'
}

Describe 'Config files' {
    It 'settings.json เป็น JSON ที่ถูกต้องและมีค่าเกณฑ์ครบ' {
        $settings = Import-ToolkitSetting
        $settings.healthCheck.diskFreeWarnPercent | Should -Be 15
        $settings.healthCheck.memoryUsedWarnPercent | Should -Be 90
        $settings.healthCheck.uptimeWarnDays | Should -Be 7
        @($settings.healthCheck.services).Count | Should -BeGreaterThan 0
        $settings.network.internetTestIp | Should -Not -BeNullOrEmpty
        $settings.network.webTestPort | Should -Be 443
    }

    It 'apps.json อ่านได้และทุกรายการมี Id' {
        $apps = @(Read-AppList)
        $apps.Count | Should -BeGreaterThan 0
        $apps | ForEach-Object { $_.Id | Should -Not -BeNullOrEmpty }
    }
}

Describe 'Read-AppList' {
    It 'ใช้ Id เป็นชื่อเมื่อไม่มี name' {
        $path = Join-Path $TestDrive 'apps-noname.json'
        '{ "apps": [ { "id": "7zip.7zip" } ] }' | Set-Content -LiteralPath $path -Encoding UTF8
        $app = Read-AppList -Path $path
        $app.Name | Should -Be '7zip.7zip'
        $app.Id | Should -Be '7zip.7zip'
    }

    It 'แจ้ง Error เมื่อรายการไม่มี id' {
        $path = Join-Path $TestDrive 'apps-bad.json'
        '{ "apps": [ { "name": "No Id" } ] }' | Set-Content -LiteralPath $path -Encoding UTF8
        { Read-AppList -Path $path } | Should -Throw
    }

    It 'แจ้ง Error เมื่อ JSON ผิดรูปแบบ' {
        $path = Join-Path $TestDrive 'apps-broken.json'
        '{ "apps": [ ' | Set-Content -LiteralPath $path -Encoding UTF8
        { Read-AppList -Path $path } | Should -Throw
    }
}

Describe 'Common helpers' {
    It 'Format-ByteSize แปลง <Bytes> เป็น <Expected>' -TestCases @(
        @{ Bytes = 512; Expected = '512 B' }
        @{ Bytes = 1536; Expected = '1.50 KB' }
        @{ Bytes = 1610612736; Expected = '1.50 GB' }
        @{ Bytes = 1099511627776; Expected = '1.00 TB' }
    ) {
        param($Bytes, $Expected)
        Format-ByteSize -Bytes $Bytes | Should -Be $Expected
    }

    It 'Test-ConfirmAnswer ยอมรับเฉพาะคำตอบยืนยัน' {
        Test-ConfirmAnswer 'y' | Should -BeTrue
        Test-ConfirmAnswer ' YES ' | Should -BeTrue
        Test-ConfirmAnswer 'ใช่' | Should -BeTrue
        Test-ConfirmAnswer 'n' | Should -BeFalse
        Test-ConfirmAnswer '' | Should -BeFalse
        Test-ConfirmAnswer $null | Should -BeFalse
    }

    It 'Format-HtmlStatusCell ใส่ class ตามสถานะ' {
        $html = Format-HtmlStatusCell -Html "<td>$(Get-StatusLabel Fail)</td><td>$(Get-StatusLabel Pass)</td>"
        $html | Should -Match 'class="status-fail"'
        $html | Should -Match 'class="status-pass"'
    }

    It 'Export-HtmlReport สร้างไฟล์ที่มีหัวข้อและเนื้อหา' {
        $path = Join-Path $TestDrive 'report.html'
        $section = ConvertTo-HtmlSection -Heading 'ทดสอบ' -Data @([pscustomobject]@{ Name = '<script>' })
        Export-HtmlReport -Title 'Test Report' -Body $section -Path $path | Out-Null
        $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $content | Should -Match '<title>Test Report</title>'
        $content | Should -Match 'ทดสอบ'
        $content | Should -Not -Match '<td><script></td>'
    }

    It 'ConvertTo-HtmlSection แสดงข้อความเมื่อไม่มีข้อมูล' {
        ConvertTo-HtmlSection -Heading 'ว่าง' -Data @() -EmptyText 'ไม่มี' | Should -Match 'class="empty">ไม่มี<'
    }
}

Describe 'SystemInfo helpers' {
    It 'Format-Uptime' {
        Format-Uptime -Uptime (New-TimeSpan -Days 3 -Hours 4 -Minutes 5) | Should -Be '3 วัน 4 ชั่วโมง 5 นาที'
    }

    It 'ConvertFrom-InstallDate' {
        ConvertFrom-InstallDate '20240131' | Should -Be '2024-01-31'
        ConvertFrom-InstallDate 'not-a-date' | Should -Be ''
        ConvertFrom-InstallDate '' | Should -Be ''
    }
}

Describe 'HealthCheck evaluation' {
    It 'Disk: เหลือ <Free>% = <Expected>' -TestCases @(
        @{ Free = 50; Expected = 'Pass' }
        @{ Free = 15; Expected = 'Pass' }
        @{ Free = 14.9; Expected = 'Warn' }
        @{ Free = 4; Expected = 'Fail' }
    ) {
        param($Free, $Expected)
        Get-DiskHealthStatus -FreePercent $Free -WarnPercent 15 -CriticalPercent 5 | Should -Be $Expected
    }

    It 'Memory: ใช้ <Used>% = <Expected>' -TestCases @(
        @{ Used = 50; Expected = 'Pass' }
        @{ Used = 90; Expected = 'Pass' }
        @{ Used = 91; Expected = 'Warn' }
        @{ Used = 98; Expected = 'Fail' }
    ) {
        param($Used, $Expected)
        Get-MemoryHealthStatus -UsedPercent $Used -WarnPercent 90 -CriticalPercent 97 | Should -Be $Expected
    }

    It 'Uptime: <Days> วัน = <Expected>' -TestCases @(
        @{ Days = 1; Expected = 'Pass' }
        @{ Days = 8; Expected = 'Warn' }
        @{ Days = 45; Expected = 'Fail' }
    ) {
        param($Days, $Expected)
        Get-UptimeHealthStatus -Days $Days -WarnDays 7 -CriticalDays 30 | Should -Be $Expected
    }

    It 'Service ที่ต้องทำงานตลอดแต่หยุดอยู่ = Fail' {
        (Get-ServiceHealthStatus -Status 'Stopped' -StartType 'Automatic' -MustBeRunning $true).Status | Should -Be 'Fail'
    }

    It 'Service แบบเปิดเมื่อมีงาน (Windows Update) หยุดอยู่ = Pass' {
        (Get-ServiceHealthStatus -Status 'Stopped' -StartType 'Manual' -MustBeRunning $false).Status | Should -Be 'Pass'
    }

    It 'Service ที่ถูก Disabled = Fail เสมอ' {
        (Get-ServiceHealthStatus -Status 'Stopped' -StartType 'Disabled' -MustBeRunning $false).Status | Should -Be 'Fail'
    }

    It 'ไม่พบ Service = Warn' {
        (Get-ServiceHealthStatus -Status $null -StartType $null).Status | Should -Be 'Warn'
    }

    It 'Defender: Signature เก่ากว่ากำหนด = Warn' {
        $now = Get-Date '2025-01-10'
        (Get-DefenderHealthStatus -AntivirusEnabled $true -RealTimeProtectionEnabled $true `
            -SignatureLastUpdated (Get-Date '2025-01-01') -MaxAgeDays 3 -Now $now).Status | Should -Be 'Warn'
        (Get-DefenderHealthStatus -AntivirusEnabled $true -RealTimeProtectionEnabled $true `
            -SignatureLastUpdated (Get-Date '2025-01-09') -MaxAgeDays 3 -Now $now).Status | Should -Be 'Pass'
    }

    It 'Defender: Real-time Protection ปิด = Fail' {
        (Get-DefenderHealthStatus -AntivirusEnabled $true -RealTimeProtectionEnabled $false `
            -SignatureLastUpdated (Get-Date)).Status | Should -Be 'Fail'
    }

    It 'สถานะรวมเลือกผลที่แย่ที่สุด' {
        $pass = New-HealthResult -Category 'A' -Item 'a' -Status Pass
        $warn = New-HealthResult -Category 'B' -Item 'b' -Status Warn
        $fail = New-HealthResult -Category 'C' -Item 'c' -Status Fail
        Get-HealthOverallStatus -Results @($pass) | Should -Be 'Pass'
        Get-HealthOverallStatus -Results @($pass, $warn) | Should -Be 'Warn'
        Get-HealthOverallStatus -Results @($pass, $warn, $fail) | Should -Be 'Fail'
    }
}

Describe 'Network Troubleshooter' {
    It 'Test-ApipaAddress: <IP> = <Expected>' -TestCases @(
        @{ IP = '169.254.12.34'; Expected = $true }
        @{ IP = '192.168.1.10'; Expected = $false }
        @{ IP = '10.169.254.1'; Expected = $false }
        @{ IP = ''; Expected = $false }
    ) {
        param($IP, $Expected)
        Test-ApipaAddress -IPAddress $IP | Should -Be $Expected
    }

    It 'มีคำแนะนำครบทุกขั้น' {
        foreach ($step in 1..6) { Get-NetworkStepAdvice -Step $step | Should -Not -BeNullOrEmpty }
    }

    Context 'Invoke-NetworkDiagnosis' {
        BeforeEach {
            Mock Get-ToolkitSetting {
                [pscustomobject]@{
                    network = [pscustomobject]@{
                        internetTestIp = '8.8.8.8'; dnsTestName = 'example.com'
                        webTestHost = 'example.com'; webTestPort = 443; pingCount = 1
                    }
                }
            }
            Mock Write-ToolkitLog { }
            Mock Test-NetStepAdapter { New-NetworkStepResult -Step 1 -Status Pass -Detail 'Ethernet' }
            Mock Test-NetStepGateway { New-NetworkStepResult -Step 3 -Status Pass }
            Mock Test-NetStepInternet { New-NetworkStepResult -Step 4 -Status Pass }
            Mock Test-NetStepNameResolution { New-NetworkStepResult -Step 5 -Status Pass }
            Mock Test-NetStepWeb { New-NetworkStepResult -Step 6 -Status Pass }
        }

        It 'หยุดที่ขั้นที่ล้มเหลวและข้ามขั้นที่เหลือ' {
            Mock Test-NetStepIPAddress { New-NetworkStepResult -Step 2 -Status Fail -Detail '169.254.1.1' }

            $results = Invoke-NetworkDiagnosis -Quiet
            $results.Count | Should -Be 6
            $results[0].Status | Should -Be 'Pass'
            $results[1].Status | Should -Be 'Fail'
            ($results | Select-Object -Skip 2 | ForEach-Object Status) | Should -Be @('Skip', 'Skip', 'Skip', 'Skip')
            Should -Invoke Test-NetStepGateway -Times 0 -Exactly

            $summary = Get-NetworkDiagnosisSummary -Results $results
            $summary.Step | Should -Be 2
            $summary.Advice | Should -Not -BeNullOrEmpty
        }

        It 'ทุกขั้นผ่าน = เครือข่ายปกติ' {
            Mock Test-NetStepIPAddress { New-NetworkStepResult -Step 2 -Status Pass }

            $results = Invoke-NetworkDiagnosis -Quiet
            ($results | Where-Object Status -eq 'Pass').Count | Should -Be 6
            (Get-NetworkDiagnosisSummary -Results $results).Status | Should -Be 'Pass'
        }

        It 'ขั้นที่โยน Exception ถูกนับเป็น Fail' {
            Mock Test-NetStepIPAddress { throw 'boom' }

            $results = Invoke-NetworkDiagnosis -Quiet
            $results[1].Status | Should -Be 'Fail'
            $results[1].Detail | Should -Match 'boom'
        }
    }
}

Describe 'Cleanup Tool' {
    BeforeEach {
        $script:cleanRoot = Join-Path $TestDrive ('clean_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:cleanRoot 'sub') -Force | Out-Null
        $old = Join-Path $script:cleanRoot 'old.tmp'
        $oldSub = Join-Path (Join-Path $script:cleanRoot 'sub') 'old2.tmp'
        $new = Join-Path $script:cleanRoot 'new.tmp'
        'old' | Set-Content -LiteralPath $old
        'old2' | Set-Content -LiteralPath $oldSub
        'new' | Set-Content -LiteralPath $new
        (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-3)
        (Get-Item -LiteralPath $oldSub).LastWriteTime = (Get-Date).AddDays(-3)
    }

    It 'Preview นับเฉพาะไฟล์ที่เก่ากว่ากำหนด' {
        $files = @(Get-CleanupFile -Path $script:cleanRoot -MinAgeHours 24)
        $files.Count | Should -Be 2
        $files.Name | Should -Not -Contain 'new.tmp'
    }

    It 'Remove-CleanupFile ลบไฟล์และรายงานพื้นที่ที่ได้คืน' {
        $files = @(Get-CleanupFile -Path $script:cleanRoot -MinAgeHours 24)
        $expected = ($files | Measure-Object -Property Length -Sum).Sum
        $result = Remove-CleanupFile -Files $files -Confirm:$false
        $result.Deleted | Should -Be 2
        $result.Skipped | Should -Be 0
        $result.FreedBytes | Should -Be $expected
        Test-Path -LiteralPath (Join-Path $script:cleanRoot 'new.tmp') | Should -BeTrue
    }

    It 'ไฟล์ที่ลบไม่ได้ถูกนับว่าข้ามโดยไม่หยุดทำงาน' {
        $ghost = [pscustomobject]@{ FullName = (Join-Path $script:cleanRoot 'missing.tmp'); Length = 10 }
        $result = Remove-CleanupFile -Files @($ghost) -Confirm:$false
        $result.Skipped | Should -Be 1
        $result.FreedBytes | Should -Be 0
    }

    It '-WhatIf ไม่ลบไฟล์จริง' {
        $files = @(Get-CleanupFile -Path $script:cleanRoot -MinAgeHours 24)
        Remove-CleanupFile -Files $files -WhatIf | Out-Null
        @(Get-CleanupFile -Path $script:cleanRoot -MinAgeHours 24).Count | Should -Be 2
    }

    It 'ไม่อนุญาตให้ล้าง Root ของไดรฟ์' {
        Test-CleanupPathSafe -Path ([IO.Path]::GetPathRoot($TestDrive)) | Should -BeFalse
        Test-CleanupPathSafe -Path '' | Should -BeFalse
        Test-CleanupPathSafe -Path $script:cleanRoot | Should -BeTrue
    }

    It 'ConvertFrom-SelectionInput: "<Text>"' -TestCases @(
        @{ Text = '1,3'; Expected = @(1, 3) }
        @{ Text = '3 1 1'; Expected = @(1, 3) }
        @{ Text = 'A'; Expected = @(1, 2, 3, 4) }
        @{ Text = '9,x,2'; Expected = @(2) }
    ) {
        param($Text, $Expected)
        ConvertFrom-SelectionInput -InputText $Text -Max 4 | Should -Be $Expected
    }

    It 'ConvertFrom-SelectionInput: ว่าง = ยกเลิก' {
        @(ConvertFrom-SelectionInput -InputText '' -Max 4).Count | Should -Be 0
    }
}

Describe 'New PC Setup' {
    It 'แปลง Exit Code ของ winget: <Code> = <Expected>' -TestCases @(
        @{ Code = 0; Expected = 'Installed' }
        @{ Code = -1978335189; Expected = 'Skipped' }
        @{ Code = -1978335135; Expected = 'Skipped' }
        @{ Code = -1978335212; Expected = 'Failed' }
        @{ Code = 1603; Expected = 'Failed' }
    ) {
        param($Code, $Expected)
        (Get-WingetResultText -ExitCode $Code).Result | Should -Be $Expected
    }

    It 'Install-AppList ข้ามโปรแกรมที่ติดตั้งแล้ว' {
        Mock Write-ToolkitLog { }
        Mock Test-WingetPackageInstalled { $Id -eq '7zip.7zip' }
        Mock Install-WingetPackage { [pscustomobject]@{ ExitCode = 0; Result = 'Installed'; Detail = 'ติดตั้งสำเร็จ'; Output = '' } }

        $apps = @(
            [pscustomobject]@{ Name = '7-Zip'; Id = '7zip.7zip'; Source = '' }
            [pscustomobject]@{ Name = 'Chrome'; Id = 'Google.Chrome'; Source = '' }
        )
        $results = @(Install-AppList -Apps $apps -Confirm:$false 6>$null)
        $results.Count | Should -Be 2
        ($results | Where-Object Id -eq '7zip.7zip').Result | Should -Be 'Skipped'
        ($results | Where-Object Id -eq 'Google.Chrome').Result | Should -Be 'Installed'
        Should -Invoke Install-WingetPackage -Times 1 -Exactly
    }
}
