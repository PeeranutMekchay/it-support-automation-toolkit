@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # เป็นเครื่องมือแบบเมนูบน Console ที่ตั้งใจแสดงผลเป็นสีให้ผู้ใช้เห็น
        'PSAvoidUsingWriteHost'
    )
}
