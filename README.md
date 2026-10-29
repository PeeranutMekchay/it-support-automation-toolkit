# 🛠️ IT Support Automation Toolkit (PowerShell)

ชุดเครื่องมือ PowerShell สำหรับช่วยงาน IT Support ประจำวัน ได้แก่ เก็บข้อมูลเครื่อง ตรวจสุขภาพระบบ แก้ปัญหาเครือข่าย ล้างไฟล์ขยะ และติดตั้งโปรแกรมเครื่องใหม่ โดยรวมไว้ในเมนูเดียวที่ใช้งานง่าย

```
==========================================
        IT Support Automation Toolkit
==========================================
  สิทธิ์: Administrator
  เครื่อง: PC-01   ผู้ใช้: user
==========================================
  [1] System Info Report
  [2] Health Check
  [3] Network Troubleshooter
  [4] Cleanup Tool
  [5] New PC Setup
  [6] เปิดโฟลเดอร์รายงาน
  [0] ออก
==========================================
เลือกเมนู:
```

## ✨ ความสามารถ

| เมนู | เครื่องมือ | ทำอะไรได้ | ผลลัพธ์ |
|------|-----------|-----------|---------|
| 1 | 🖥️ **System Info Report** | ชื่อเครื่อง, ผู้ใช้, Domain/Workgroup, Windows Version/Build/วันที่ติดตั้ง/Uptime, CPU, RAM, Disk, GPU, Serial/รุ่น/ผู้ผลิต, IP/MAC/Gateway/DNS, รายการโปรแกรมที่ติดตั้ง | HTML + CSV |
| 2 | ❤️ **Health Check** | ดิสก์เหลือน้อยกว่า 15%, RAM ใช้เกิน 90%, Service สำคัญ, ไม่ได้ Restart เกิน 7 วัน, Windows Defender และวันที่อัปเดต, Error ล่าสุดจาก Event Log | ✅ ผ่าน / ⚠️ ควรตรวจสอบ / ❌ มีปัญหา + HTML + CSV |
| 3 | 🌐 **Network Troubleshooter** | ไล่ตรวจ 6 ขั้นตามลำดับการ Troubleshoot จริง บอกว่าปัญหาอยู่ขั้นไหนพร้อมวิธีแก้ มีตัวเลือก Flush DNS และ Release/Renew IP (ถามยืนยันก่อน) | HTML |
| 4 | 🧹 **Cleanup Tool** | ล้าง Temp ของผู้ใช้และระบบ, Recycle Bin, Cache ของ Windows Update โดยแสดง **Preview** ขนาดที่จะลบก่อน แล้วรายงานพื้นที่ที่ได้คืน | สรุปบนหน้าจอ |
| 5 | 📦 **New PC Setup** | ติดตั้งโปรแกรมจาก `config/apps.json` ผ่าน `winget` ทีละรายการ ข้ามตัวที่ติดตั้งแล้ว และตั้งค่าพื้นฐาน (แสดงนามสกุลไฟล์, Power Plan) | HTML |
| 6 | 📂 เปิดโฟลเดอร์รายงาน | เปิดโฟลเดอร์ `reports/` | — |

ทุกการทำงานถูกบันทึกลง `logs/toolkit_yyyyMMdd.log`

### ลำดับการตรวจของ Network Troubleshooter

1. การ์ดเครือข่ายเปิดอยู่และเชื่อมต่อหรือไม่
2. ได้ IP จาก DHCP หรือไม่ (ถ้าได้ `169.254.x.x` = APIPA = ติดต่อ DHCP Server ไม่ได้)
3. Ping Default Gateway ได้หรือไม่
4. Ping อินเทอร์เน็ตด้วย IP (`8.8.8.8`) ได้หรือไม่ — ถ้า Ping ไม่ได้แต่ต่อ TCP 53 ได้ จะสรุปว่า Firewall บล็อก ICMP แทนการบอกว่าเน็ตล่ม
5. แปลงชื่อโดเมนผ่าน DNS ได้หรือไม่
6. เปิดเว็บไซต์ (Port 443) ได้หรือไม่

เครื่องมือหยุดที่ขั้นแรกที่ล้มเหลว (ขั้นถัดไปจะล้มตามอยู่แล้ว) แล้วแสดงคำแนะนำของขั้นนั้น

## 🚀 เริ่มใช้งาน

ต้องใช้ Windows 10 / 11 กับ PowerShell 7 หรือ Windows PowerShell 5.1

```powershell
# 1. Clone โปรเจค
git clone https://github.com/PeeranutMekchay/it-support-automation-toolkit.git
cd it-support-automation-toolkit

# 2. อนุญาตให้รันสคริปต์ (เฉพาะ session นี้)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 3. รันเมนูหลัก (คลิกขวา PowerShell > Run as Administrator สำหรับบางเมนู)
.\Toolkit.ps1
```

ถ้าเปิดแบบผู้ใช้ทั่วไป เมนูจะมีตัวเลือก `[9]` สำหรับเปิด Toolkit ใหม่ด้วยสิทธิ์ Administrator

### 🔐 เมนูที่ต้องใช้สิทธิ์ Admin

| เมนู | ผู้ใช้ทั่วไป | ต้องใช้ Admin |
|------|-------------|---------------|
| 1. System Info Report | ✅ ใช้ได้ทั้งหมด | — |
| 2. Health Check | ✅ ใช้ได้เกือบทั้งหมด | อ่าน Event Log / สถานะ Defender ได้ครบขึ้นในบางเครื่อง |
| 3. Network Troubleshooter | ✅ การตรวจทั้ง 6 ขั้น, Flush DNS | Release / Renew IP |
| 4. Cleanup Tool | ✅ Temp ของผู้ใช้, Recycle Bin | Temp ของระบบ, Cache ของ Windows Update |
| 5. New PC Setup | ⚠️ บางโปรแกรมจะขึ้น UAC | แนะนำให้รันแบบ Admin |

### ⏱️ รันแบบไม่มีเมนู (เช่น ตั้งเวลาด้วย Task Scheduler)

```powershell
.\Toolkit.ps1 -Run SystemInfo
.\Toolkit.ps1 -Run HealthCheck   # Exit Code: 0 = ผ่าน, 1 = ควรตรวจสอบ, 2 = มีปัญหา
.\Toolkit.ps1 -Run Network
```

ตัวอย่างตั้งเวลา Health Check ทุกวัน 08:00 (รันใน PowerShell แบบ Admin):

```powershell
$script = (Resolve-Path .\Toolkit.ps1).Path
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Run HealthCheck"
$trigger = New-ScheduledTaskTrigger -Daily -At 8am
Register-ScheduledTask -TaskName 'IT Toolkit Health Check' -Action $action -Trigger $trigger -RunLevel Highest
```

## ⚙️ การตั้งค่า

แก้ได้โดยไม่ต้องแก้โค้ด

**`config/apps.json`** — รายการโปรแกรมของ New PC Setup (ดู ID ได้ด้วย `winget search <ชื่อโปรแกรม>`)

```json
{
  "apps": [
    { "name": "Google Chrome", "id": "Google.Chrome" },
    { "name": "7-Zip", "id": "7zip.7zip" },
    { "name": "Adobe Acrobat Reader", "id": "Adobe.Acrobat.Reader.64-bit" }
  ]
}
```

ใส่ `"source": "msstore"` เพิ่มได้ถ้าเป็นแอปจาก Microsoft Store

**`config/settings.json`** — ค่าเกณฑ์และตัวเลือกต่าง ๆ

| ค่า | ค่าเริ่มต้น | ความหมาย |
|-----|-----------|----------|
| `healthCheck.diskFreeWarnPercent` / `diskFreeCriticalPercent` | 15 / 5 | % พื้นที่ดิสก์ที่เหลือ ต่ำกว่านี้ = ควรตรวจสอบ / มีปัญหา |
| `healthCheck.memoryUsedWarnPercent` / `memoryUsedCriticalPercent` | 90 / 97 | % RAM ที่ใช้ |
| `healthCheck.uptimeWarnDays` / `uptimeCriticalDays` | 7 / 30 | จำนวนวันที่ไม่ได้ Restart |
| `healthCheck.defenderSignatureMaxAgeDays` | 3 | อายุ Signature ของ Defender |
| `healthCheck.eventLogHours` / `eventLogMaxEvents` | 24 / 20 | ช่วงเวลาและจำนวน Error ที่ดึงจาก Event Log |
| `healthCheck.services` | Spooler, Dnscache, Dhcp, EventLog, wuauserv, BITS | Service ที่ตรวจ (`mustBeRunning: false` = Service ที่เปิดเมื่อมีงาน หยุดอยู่ถือว่าปกติ แต่ห้าม Disabled) |
| `network.*` | 8.8.8.8, www.google.com:443 | ปลายทางที่ใช้ทดสอบ |
| `cleanup.minFileAgeHours` | 24 | ไม่ลบไฟล์ที่ใหม่กว่านี้ เพื่อไม่กระทบโปรแกรมที่กำลังใช้ไฟล์ Temp |
| `newPcSetup.showFileExtensions` | true | แสดงนามสกุลไฟล์ใน File Explorer |
| `newPcSetup.powerPlan` | Balanced | `Balanced`, `HighPerformance`, `PowerSaver` หรือ `""` เพื่อไม่เปลี่ยน |

## 📁 โครงสร้างโฟลเดอร์

```
it-support-automation-toolkit/
├── Toolkit.ps1                  # เมนูหลัก
├── modules/
│   ├── Common.ps1               # Log, Settings, ตรวจสิทธิ์ Admin, รายงาน HTML/CSV
│   ├── SystemInfo.ps1
│   ├── HealthCheck.ps1
│   ├── NetworkTroubleshooter.ps1
│   ├── Cleanup.ps1
│   └── NewPCSetup.ps1
├── config/
│   ├── apps.json                # รายการโปรแกรมที่จะติดตั้ง
│   └── settings.json            # ค่าเกณฑ์ต่าง ๆ
├── templates/
│   └── report.css               # สไตล์ของรายงาน HTML (ฝังลงในไฟล์รายงาน)
├── reports/                     # รายงานที่สร้าง (ไม่ commit)
├── logs/                        # Log การทำงาน (ไม่ commit)
├── tests/
│   └── Toolkit.Tests.ps1        # Pester tests
├── PSScriptAnalyzerSettings.psd1
├── .github/workflows/ci.yml     # รัน PSScriptAnalyzer + Pester บน Windows
├── .gitignore
└── README.md
```

## 🛡️ ความปลอดภัยในการออกแบบ

- คำสั่งที่ลบไฟล์หรือเปลี่ยนการตั้งค่าเครือข่าย **ถามยืนยันก่อนทุกครั้ง** (ค่าเริ่มต้นคือ "ไม่")
- Cleanup Tool แสดง Preview ก่อนลบ, ข้ามไฟล์ที่ถูกใช้งานอยู่โดยไม่หยุดทำงาน, ไม่ตามเข้า Symbolic Link / Junction และไม่ยอมล้างโฟลเดอร์ระดับ Root, Windows, Program Files หรือโฟลเดอร์ผู้ใช้ทั้งก้อน
- ล้าง Cache ของ Windows Update โดยหยุด Service `wuauserv` / `bits` ก่อน แล้วเปิดกลับให้เหมือนเดิม
- รายการโปรแกรมอ่านจาก Registry แทน `Win32_Product` ซึ่งช้าและสั่งให้ Windows Installer ตรวจซ่อมโปรแกรม MSI ทุกตัว
- ไฟล์รายงานและ Log อยู่ใน `.gitignore` เพราะมีข้อมูลเครื่องจริง (Serial Number, MAC Address, ชื่อผู้ใช้)
- ไม่มีรหัสผ่านหรือ Webhook URL ในโค้ด

> ⚠️ แนะนำให้ทดสอบ Cleanup Tool และ New PC Setup บน Virtual Machine ก่อนใช้กับเครื่องจริง

## 🧪 ตรวจคุณภาพโค้ดและทดสอบ

```powershell
Install-Module PSScriptAnalyzer, Pester -Scope CurrentUser -Force -SkipPublisherCheck

# ตรวจโค้ด
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1

# Unit tests
Invoke-Pester -Path .\tests -Output Detailed
```

GitHub Actions รันทั้งสองอย่างบน Windows ทั้ง PowerShell 7 และ Windows PowerShell 5.1 ทุกครั้งที่ push

> ไฟล์ `.ps1` บันทึกเป็น **UTF-8 with BOM** เพื่อให้ Windows PowerShell 5.1 อ่านข้อความภาษาไทยได้ถูกต้อง หากแก้ไขด้วย Editor อื่นนอกจาก VS Code (ซึ่งตั้งค่าไว้ใน `.vscode/settings.json` แล้ว) ให้ตรวจ Encoding ก่อนบันทึก

## 🧰 เทคโนโลยีที่ใช้

| ส่วน | เทคโนโลยี |
|------|-----------|
| ภาษา | PowerShell 7 (รองรับ Windows PowerShell 5.1) |
| ดึงข้อมูลระบบ | CIM / WMI (`Get-CimInstance`), `Get-NetIPConfiguration`, `Get-WinEvent`, `Get-MpComputerStatus` |
| ติดตั้งโปรแกรม | winget |
| รายงาน | HTML + CSS, CSV |
| ตรวจคุณภาพโค้ด | PSScriptAnalyzer |
| ทดสอบ | Pester 5 |
| CI | GitHub Actions |

## 🗺️ แผนต่อยอด

- [ ] GUI ด้วย Windows Forms
- [ ] Remote Mode: รัน System Info / Health Check กับหลายเครื่องผ่าน `Invoke-Command`
- [ ] Backup Tool: บีบอัดโฟลเดอร์สำคัญเป็น ZIP พร้อมวันที่ และลบไฟล์เก่าอัตโนมัติ
- [ ] ส่งรายงานไปยัง Discord / Teams Webhook
