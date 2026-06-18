$root = "C:\Users\hgeec\github"
$reportPointer = Join-Path $root "graphify-batch-report-current.txt"
$report = Join-Path $root "graphify-batch-report.txt"
$out = "C:\Users\hgeec\github\graphify-batch-summary.txt"

if (Test-Path $reportPointer) {
    $pointerPath = (Get-Content -Path $reportPointer -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    if ($pointerPath) {
        $report = $pointerPath
    }
}

if (-not (Test-Path $report)) {
    "REPORT_MISSING" | Out-File -FilePath $out -Encoding utf8
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
            throw
        }
        Start-Sleep -Milliseconds 200
    }
}

if ($null -eq $bytes) {
    "REPORT_READ_FAILED" | Out-File -FilePath $out -Encoding utf8
    exit 0
}

$text = [System.Text.Encoding]::UTF8.GetString($bytes)
$text = $text -replace "`0", ""

$run = ([regex]::Matches($text, "(?m)^RUN\t")).Count
$ok = ([regex]::Matches($text, "(?m)^OK\t")).Count
$fail = ([regex]::Matches($text, "(?m)^FAIL\t")).Count
$skip = ([regex]::Matches($text, "(?m)^SKIP\t")).Count
$extractOk = ([regex]::Matches($text, "(?m)^EXTRACT_OK\t")).Count
$extractFail = ([regex]::Matches($text, "(?m)^EXTRACT_FAIL\t")).Count
$extractRetry = ([regex]::Matches($text, "(?m)^EXTRACT_RETRY\t")).Count
$clusterOk = ([regex]::Matches($text, "(?m)^CLUSTER_OK\t")).Count
$clusterFail = ([regex]::Matches($text, "(?m)^CLUSTER_FAIL\t")).Count
$quota = ([regex]::Matches($text, "(?m)^QUOTA_EXHAUSTED\t")).Count
$done = ([regex]::Matches($text, "(?m)^DONE$")).Count

"RUN=$run" | Out-File -FilePath $out -Encoding utf8
"REPORT_PATH=$report" | Out-File -FilePath $out -Append -Encoding utf8
"EXTRACT_OK=$extractOk" | Out-File -FilePath $out -Append -Encoding utf8
"EXTRACT_FAIL=$extractFail" | Out-File -FilePath $out -Append -Encoding utf8
"EXTRACT_RETRY=$extractRetry" | Out-File -FilePath $out -Append -Encoding utf8
"CLUSTER_OK=$clusterOk" | Out-File -FilePath $out -Append -Encoding utf8
"CLUSTER_FAIL=$clusterFail" | Out-File -FilePath $out -Append -Encoding utf8
"QUOTA_EXHAUSTED=$quota" | Out-File -FilePath $out -Append -Encoding utf8
"OK=$ok" | Out-File -FilePath $out -Append -Encoding utf8
"FAIL=$fail" | Out-File -FilePath $out -Append -Encoding utf8
"SKIP=$skip" | Out-File -FilePath $out -Append -Encoding utf8
"DONE=$done" | Out-File -FilePath $out -Append -Encoding utf8

$last = $text -split "`r?`n" | Where-Object { $_ -match '^(RUN|EXTRACT_OK|EXTRACT_FAIL|CLUSTER_OK|CLUSTER_FAIL|QUOTA_EXHAUSTED|OK|FAIL|SKIP|DONE)\t|^DONE$' } | Select-Object -Last 15
"LAST_EVENTS:" | Out-File -FilePath $out -Append -Encoding utf8
$last | Out-File -FilePath $out -Append -Encoding utf8
