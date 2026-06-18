$root = "C:\Users\hgeec\github"
$out = Join-Path $root "graphify-recovery-status.txt"
$pointer = Join-Path $root "graphify-recovery-report-current.txt"
$report = Join-Path $root "graphify-recovery-report.txt"

if (Test-Path $pointer) {
    $p = (Get-Content -Path $pointer -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    if ($p) {
        $report = $p
    }
}

$procs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*recover-failed-graphify.ps1*" }
"COUNT=$($procs.Count)" | Out-File -FilePath $out -Encoding utf8
$procs | ForEach-Object { "PID=$($_.ProcessId)`t$($_.CommandLine)" } | Out-File -FilePath $out -Append -Encoding utf8
"REPORT_PATH=$report" | Out-File -FilePath $out -Append -Encoding utf8

if (Test-Path $report) {
    "REPORT_BYTES=$((Get-Item $report).Length)" | Out-File -FilePath $out -Append -Encoding utf8
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
            Start-Sleep -Milliseconds 200
        }
    }

    if ($bytes) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $text = $text -replace "`0", ""
        $events = $text -split "`r?`n" | Where-Object { $_ -match '^(RECOVER_RUN|RECOVER_EXTRACT_OK|RECOVER_OK|RECOVER_FAIL|RECOVERY_QUOTA_EXHAUSTED|RECOVERY_DONE)\t|^RECOVERY_DONE$' } | Select-Object -Last 15
        "LAST_EVENTS:" | Out-File -FilePath $out -Append -Encoding utf8
        $events | Out-File -FilePath $out -Append -Encoding utf8
    }
}

$alerts = Join-Path $root "graphify-quota-alerts.txt"
if (Test-Path $alerts) {
    "ALERTS_FILE=$alerts" | Out-File -FilePath $out -Append -Encoding utf8
    $lastAlerts = Get-Content -Path $alerts -Tail 10
    "ALERTS_TAIL:" | Out-File -FilePath $out -Append -Encoding utf8
    $lastAlerts | Out-File -FilePath $out -Append -Encoding utf8
} else {
    "ALERTS_FILE_MISSING" | Out-File -FilePath $out -Append -Encoding utf8
}
