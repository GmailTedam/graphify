$root = "C:\Users\hgeec\github"
$pointer = Join-Path $root "graphify-recovery-report-current.txt"
$report = Join-Path $root "graphify-recovery-report.txt"
$out = Join-Path $root "graphify-recovery-summary.txt"

if (Test-Path $pointer) {
    $p = (Get-Content -Path $pointer -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    if ($p) {
        $report = $p
    }
}

if (-not (Test-Path $report)) {
    "RECOVERY_REPORT_MISSING" | Out-File -FilePath $out -Encoding utf8
    exit 0
}

$bytes = $null
for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
        $fs = [System.IO.File]::Open($report, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $buffer = New-Object byte[] $fs.Length
            [void]$fs.Read($buffer, 0, $buffer.Length)
            $bytes = $buffer
        } finally {
            $fs.Dispose()
        }
        break
    } catch {
        if ($attempt -eq 5) {
            "RECOVERY_REPORT_READ_FAILED" | Out-File -FilePath $out -Encoding utf8
            exit 0
        }
        Start-Sleep -Milliseconds 200
    }
}

if ($null -eq $bytes) {
    "RECOVERY_REPORT_READ_FAILED" | Out-File -FilePath $out -Encoding utf8
    exit 0
}

$text = [System.Text.Encoding]::UTF8.GetString($bytes)
$text = $text -replace "`0", ""

$run = ([regex]::Matches($text, "(?m)^RECOVER_RUN\t")).Count
$ok = ([regex]::Matches($text, "(?m)^RECOVER_OK\t")).Count
$extractOk = ([regex]::Matches($text, "(?m)^RECOVER_EXTRACT_OK\t")).Count
$fail = ([regex]::Matches($text, "(?m)^RECOVER_FAIL\t")).Count
$quota = ([regex]::Matches($text, "(?m)^RECOVERY_QUOTA_EXHAUSTED\t")).Count
$done = ([regex]::Matches($text, "(?m)^RECOVERY_DONE$")).Count

"REPORT_PATH=$report" | Out-File -FilePath $out -Encoding utf8
"RECOVER_RUN=$run" | Out-File -FilePath $out -Append -Encoding utf8
"RECOVER_EXTRACT_OK=$extractOk" | Out-File -FilePath $out -Append -Encoding utf8
"RECOVER_OK=$ok" | Out-File -FilePath $out -Append -Encoding utf8
"RECOVER_FAIL=$fail" | Out-File -FilePath $out -Append -Encoding utf8
"RECOVERY_QUOTA_EXHAUSTED=$quota" | Out-File -FilePath $out -Append -Encoding utf8
"RECOVERY_DONE=$done" | Out-File -FilePath $out -Append -Encoding utf8

$last = $text -split "`r?`n" | Where-Object { $_ -match '^(RECOVER_RUN|RECOVER_EXTRACT_OK|RECOVER_OK|RECOVER_FAIL|RECOVERY_QUOTA_EXHAUSTED|RECOVERY_DONE)\t|^RECOVERY_DONE$' } | Select-Object -Last 20
"LAST_EVENTS:" | Out-File -FilePath $out -Append -Encoding utf8
$last | Out-File -FilePath $out -Append -Encoding utf8
