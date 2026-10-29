<#
.SYNOPSIS
    Cleanup Tool: ล้าง Temp, Recycle Bin และ Cache ของ Windows Update
.DESCRIPTION
    ทำงาน 2 ขั้นเสมอ:
    1. Preview  - คำนวณจำนวนไฟล์และขนาดที่จะลบ โดยยังไม่ลบอะไร
    2. Cleanup  - ลบหลังผู้ใช้เลือกและยืนยันแล้ว ไฟล์ที่ถูกใช้งานอยู่จะถูกข้ามโดยไม่หยุดทำงาน
    ไฟล์ที่ใหม่กว่า cleanup.minFileAgeHours (settings.json) จะไม่ถูกลบ
    เพื่อไม่ให้กระทบโปรแกรมที่กำลังใช้ไฟล์ Temp อยู่
#>

function Get-CleanupTarget {
    <#
    .SYNOPSIS
        รายการเป้าหมายที่ล้างได้
    #>
    [CmdletBinding()]
    param()

    $windir = $env:windir
    if ([string]::IsNullOrWhiteSpace($windir)) { $windir = 'C:\Windows' }

    return @(
        [pscustomobject]@{ Key = 'UserTemp'; Name = 'Temp ของผู้ใช้'; Type = 'Folder'; Path = [IO.Path]::GetTempPath().TrimEnd('\'); RequiresAdmin = $false }
        [pscustomobject]@{ Key = 'SystemTemp'; Name = 'Temp ของระบบ'; Type = 'Folder'; Path = (Join-Path $windir 'Temp'); RequiresAdmin = $true }
        [pscustomobject]@{ Key = 'RecycleBin'; Name = 'Recycle Bin'; Type = 'RecycleBin'; Path = ''; RequiresAdmin = $false }
        [pscustomobject]@{ Key = 'WindowsUpdate'; Name = 'Cache ของ Windows Update'; Type = 'Folder'; Path = (Join-Path $windir 'SoftwareDistribution\Download'); RequiresAdmin = $true }
    )
}

function Get-SafeChildItem {
    <#
    .SYNOPSIS
        ไล่หาไฟล์และโฟลเดอร์ย่อยทั้งหมด โดยไม่ตามเข้าไปใน Symbolic Link / Junction
    .NOTES
        Get-ChildItem -Recurse ของ Windows PowerShell 5.1 ตามเข้า Junction ได้ ซึ่งอาจทำให้ลบไฟล์
        นอกโฟลเดอร์เป้าหมาย จึงไล่เองด้วย Stack แล้วข้าม ReparsePoint
    #>
    param([Parameter(Mandatory)][string]$Path)

    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($item.PSIsContainer) { $stack.Push($item.FullName) }
            $item
        }
    }
}

function Get-CleanupFile {
    <#
    .SYNOPSIS
        ไฟล์ในโฟลเดอร์ที่เก่ากว่า MinAgeHours (ใช้ทั้งตอน Preview และตอนลบจริง)
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [double]$MinAgeHours = 0
    )

    $cutoff = (Get-Date).AddHours(-$MinAgeHours)
    Get-SafeChildItem -Path $Path | Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $cutoff }
}

function Test-CleanupPathSafe {
    <#
    .SYNOPSIS
        กันพลาด: ไม่ยอมล้างโฟลเดอร์ระดับ Root, Windows, System32, Program Files หรือโฟลเดอร์ผู้ใช้ทั้งก้อน
    #>
    param([AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
    catch { return $false }

    if ($full.Length -le 3) { return $false }                 # เช่น C:\
    $system32 = $null
    if ($env:windir) { $system32 = Join-Path $env:windir 'System32' }
    $blocked = @($env:windir, $env:SystemRoot, $system32,
        $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:USERPROFILE, $env:SystemDrive) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') }
    foreach ($b in $blocked) {
        if ($full -ieq $b) { return $false }
    }
    return $true
}

function Get-CurrentUserSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-RecycleBinFile {
    <#
    .SYNOPSIS
        ไฟล์ใน Recycle Bin ของผู้ใช้ปัจจุบันทุกไดรฟ์ (X:\$Recycle.Bin\<SID>)
    #>
    $sid = Get-CurrentUserSid
    $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)
    foreach ($d in $drives) {
        $bin = Join-Path "$($d.DeviceID)\" "`$Recycle.Bin\$sid"
        if (Test-Path -LiteralPath $bin) {
            Get-SafeChildItem -Path $bin | Where-Object { -not $_.PSIsContainer -and $_.Name -ne 'desktop.ini' }
        }
    }
}

function Get-CleanupPreview {
    <#
    .SYNOPSIS
        คำนวณขนาดที่จะได้คืนของแต่ละเป้าหมาย (ยังไม่ลบอะไร)
    #>
    [CmdletBinding()]
    param(
        [object[]]$Targets = (Get-CleanupTarget),
        [double]$MinAgeHours = 24,
        [bool]$IsAdmin = (Test-IsAdministrator)
    )

    foreach ($t in $Targets) {
        $files = @()
        $note = ''
        $available = $true

        if ($t.RequiresAdmin -and -not $IsAdmin) {
            $available = $false
            $note = 'ต้องใช้สิทธิ์ Admin'
        }
        elseif ($t.Type -eq 'RecycleBin') {
            $files = @(Get-RecycleBinFile)
        }
        elseif (-not (Test-Path -LiteralPath $t.Path)) {
            $available = $false
            $note = 'ไม่พบโฟลเดอร์'
        }
        elseif (-not (Test-CleanupPathSafe -Path $t.Path)) {
            $available = $false
            $note = 'Path ไม่ปลอดภัย ไม่อนุญาตให้ล้าง'
        }
        else {
            $files = @(Get-CleanupFile -Path $t.Path -MinAgeHours $MinAgeHours)
        }

        $bytes = 0
        if ($files.Count -gt 0) { $bytes = [double]($files | Measure-Object -Property Length -Sum).Sum }

        [pscustomobject]@{
            Key           = $t.Key
            Name          = $t.Name
            Type          = $t.Type
            Path          = $t.Path
            RequiresAdmin = $t.RequiresAdmin
            Available     = $available
            FileCount     = $files.Count
            Bytes         = $bytes
            Size          = Format-ByteSize -Bytes $bytes
            Note          = $note
        }
    }
}

function ConvertFrom-SelectionInput {
    <#
    .SYNOPSIS
        แปลงคำตอบ เช่น "1,3" หรือ "A" เป็นรายการเลขที่เลือก (ไม่ซ้ำ, อยู่ในช่วง 1..Max)
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$InputText,
        [Parameter(Mandatory)][int]$Max
    )

    if ([string]::IsNullOrWhiteSpace($InputText)) { return @() }
    if ($InputText.Trim() -match '^(a|all|ทั้งหมด)$') { return @(1..$Max) }

    $selected = foreach ($part in ($InputText -split '[,\s]+')) {
        $n = 0
        if ([int]::TryParse($part, [ref]$n) -and $n -ge 1 -and $n -le $Max) { $n }
    }
    return @($selected | Sort-Object -Unique)
}

function Remove-CleanupFile {
    <#
    .SYNOPSIS
        ลบไฟล์ทีละไฟล์ ไฟล์ที่ลบไม่ได้ (ถูกใช้งานอยู่ / ไม่มีสิทธิ์) จะถูกนับว่าข้าม
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([AllowEmptyCollection()][object[]]$Files = @())

    $freed = [double]0
    $deleted = 0
    $skipped = 0
    foreach ($f in $Files) {
        if (-not $PSCmdlet.ShouldProcess($f.FullName, 'Delete')) { continue }
        try {
            $size = [double]$f.Length
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $freed += $size
            $deleted++
        }
        catch {
            $skipped++
        }
    }
    return [pscustomobject]@{ Deleted = $deleted; Skipped = $skipped; FreedBytes = $freed }
}

function Remove-EmptyCleanupDirectory {
    <#
    .SYNOPSIS
        ลบโฟลเดอร์ย่อยที่ว่างแล้ว (ลึกสุดก่อน) โดยไม่ลบโฟลเดอร์เป้าหมายเอง
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [double]$MinAgeHours = 0
    )

    $cutoff = (Get-Date).AddHours(-$MinAgeHours)
    $dirs = @(Get-SafeChildItem -Path $Path | Where-Object { $_.PSIsContainer -and $_.LastWriteTime -lt $cutoff } |
        Sort-Object -Property { $_.FullName.Length } -Descending)
    foreach ($d in $dirs) {
        $hasChild = Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $hasChild -and $PSCmdlet.ShouldProcess($d.FullName, 'Remove empty folder')) {
            Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-CleanupTarget {
    <#
    .SYNOPSIS
        ล้างเป้าหมาย 1 รายการ แล้วคืนผล (จำนวนไฟล์ที่ลบ / ข้าม / พื้นที่ที่ได้คืน)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Target,
        [double]$MinAgeHours = 24
    )

    if (-not $PSCmdlet.ShouldProcess($Target.Name, 'Cleanup')) { return }

    if ($Target.Type -eq 'RecycleBin') {
        $files = @(Get-RecycleBinFile)
        $bytes = [double]0
        if ($files.Count -gt 0) { $bytes = [double]($files | Measure-Object -Property Length -Sum).Sum }
        if (Get-Command -Name Clear-RecycleBin -ErrorAction SilentlyContinue) {
            try {
                Clear-RecycleBin -Force -ErrorAction Stop
                return [pscustomobject]@{ Name = $Target.Name; Deleted = $files.Count; Skipped = 0; FreedBytes = $bytes }
            }
            catch {
                Write-ToolkitLog -Level WARN -Message "Cleanup: Clear-RecycleBin ไม่สำเร็จ ลบไฟล์เองแทน - $($_.Exception.Message)"
            }
        }
        $r = Remove-CleanupFile -Files $files -Confirm:$false
        return [pscustomobject]@{ Name = $Target.Name; Deleted = $r.Deleted; Skipped = $r.Skipped; FreedBytes = $r.FreedBytes }
    }

    if (-not (Test-CleanupPathSafe -Path $Target.Path)) {
        throw "Path ไม่ปลอดภัย ไม่อนุญาตให้ล้าง: $($Target.Path)"
    }

    # Cache ของ Windows Update ต้องหยุด Service ก่อน ไม่เช่นนั้นไฟล์จะถูกล็อก แล้วเปิดกลับเหมือนเดิม
    $stoppedServices = @()
    if ($Target.Key -eq 'WindowsUpdate') {
        foreach ($name in 'wuauserv', 'bits') {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Stop-Service -Name $name -Force -ErrorAction Stop
                $stoppedServices += $name
            }
        }
    }

    try {
        $files = @(Get-CleanupFile -Path $Target.Path -MinAgeHours $MinAgeHours)
        $r = Remove-CleanupFile -Files $files -Confirm:$false
        Remove-EmptyCleanupDirectory -Path $Target.Path -MinAgeHours $MinAgeHours -Confirm:$false
    }
    finally {
        foreach ($name in $stoppedServices) {
            Start-Service -Name $name -ErrorAction SilentlyContinue
        }
    }
    return [pscustomobject]@{ Name = $Target.Name; Deleted = $r.Deleted; Skipped = $r.Skipped; FreedBytes = $r.FreedBytes }
}

function Get-SystemDriveFreeSpace {
    $drive = $env:SystemDrive
    if (-not $drive) { $drive = 'C:' }
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$drive'" -ErrorAction SilentlyContinue
    if ($disk) { return [double]$disk.FreeSpace }
    return $null
}

function Invoke-CleanupTool {
    <#
    .SYNOPSIS
        เมนู [4] Preview -> เลือก -> ยืนยัน -> ล้าง -> สรุปพื้นที่ที่ได้คืน
    #>
    [CmdletBinding()]
    param()

    Write-SectionHeader -Title 'Cleanup Tool'
    $minAge = [double](Get-ToolkitSetting).cleanup.minFileAgeHours
    $isAdmin = Test-IsAdministrator
    if (-not $isAdmin) {
        Write-StatusLine -Status Warn -Message 'ไม่ได้รันแบบ Admin: ล้างได้เฉพาะ Temp ของผู้ใช้และ Recycle Bin'
    }

    Write-StatusLine -Status Info -Message "กำลังคำนวณขนาด (Preview) ไม่รวมไฟล์ที่ใหม่กว่า $minAge ชั่วโมง..."
    $preview = @(Get-CleanupPreview -MinAgeHours $minAge -IsAdmin $isAdmin)

    Write-Host ''
    $i = 0
    foreach ($p in $preview) {
        $i++
        $line = '  [{0}] {1,-28} {2,8} ไฟล์ {3,12}' -f $i, $p.Name, $p.FileCount, $p.Size
        if ($p.Available) { Write-Host $line }
        else { Write-Host ('{0}   ({1})' -f $line, $p.Note) -ForegroundColor DarkGray }
    }
    $total = ($preview | Where-Object Available | Measure-Object -Property Bytes -Sum).Sum
    Write-Host ''
    Write-StatusLine -Status Info -Message "รวมที่ล้างได้: $(Format-ByteSize ([double]$total))"
    Write-ToolkitLog -Message ('Cleanup Preview: ' + (($preview | ForEach-Object { '{0}={1}' -f $_.Key, $_.Bytes }) -join ' '))

    $answer = Read-Host '  เลือกรายการที่จะล้าง (เช่น 1,3 หรือ A = ทั้งหมด, Enter = ยกเลิก)'
    $selected = @(ConvertFrom-SelectionInput -InputText $answer -Max $preview.Count |
        ForEach-Object { $preview[$_ - 1] } | Where-Object { $_.Available })
    if ($selected.Count -eq 0) {
        Write-StatusLine -Status Info -Message 'ยกเลิก ไม่มีการลบไฟล์'
        return
    }

    $selectedBytes = [double]($selected | Measure-Object -Property Bytes -Sum).Sum
    $names = ($selected | ForEach-Object { $_.Name }) -join ', '
    if (-not (Confirm-ToolkitAction -Message "  ยืนยันลบ $names (ประมาณ $(Format-ByteSize $selectedBytes))?")) {
        Write-StatusLine -Status Info -Message 'ยกเลิก ไม่มีการลบไฟล์'
        return
    }

    $freeBefore = Get-SystemDriveFreeSpace
    $targets = Get-CleanupTarget
    $results = foreach ($s in $selected) {
        $target = $targets | Where-Object Key -eq $s.Key
        Write-StatusLine -Status Info -Message "กำลังล้าง $($s.Name)..."
        try {
            $r = Invoke-CleanupTarget -Target $target -MinAgeHours $minAge -Confirm:$false
            Write-StatusLine -Status Pass -Message ('{0}: ลบ {1} ไฟล์, ข้าม {2} ไฟล์ (ถูกใช้งานอยู่), ได้คืน {3}' -f
                $r.Name, $r.Deleted, $r.Skipped, (Format-ByteSize $r.FreedBytes))
            Write-ToolkitLog -Message "Cleanup: $($s.Key) deleted=$($r.Deleted) skipped=$($r.Skipped) freed=$($r.FreedBytes)"
            $r
        }
        catch {
            Write-StatusLine -Status Fail -Message "$($s.Name): $($_.Exception.Message)"
            Write-ToolkitLog -Level ERROR -Message "Cleanup: $($s.Key) ล้มเหลว - $($_.Exception.Message)"
        }
    }

    $freed = [double](@($results) | Measure-Object -Property FreedBytes -Sum).Sum
    Write-Host ''
    Write-StatusLine -Status Pass -Message "ได้พื้นที่คืนทั้งหมด $(Format-ByteSize $freed)"
    $freeAfter = Get-SystemDriveFreeSpace
    if ($null -ne $freeBefore -and $null -ne $freeAfter) {
        Write-StatusLine -Status Info -Message ('พื้นที่ว่างไดรฟ์ {0}: {1} -> {2}' -f $env:SystemDrive, (Format-ByteSize $freeBefore), (Format-ByteSize $freeAfter))
    }
}
