$root = "C:\Users\hgeec\github"
$out = Join-Path $root "graphify-batch-status.txt"
$reportPointer = Join-Path $root "graphify-batch-report-current.txt"
$report = Join-Path $root "graphify-batch-report.txt"

if (Test-Path $reportPointer) {
	$pointerPath = (Get-Content -Path $reportPointer -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
	if ($pointerPath) {
		$report = $pointerPath
	}
}

$procs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*run-graphify-nonfork.ps1*" }
"COUNT=$($procs.Count)" | Out-File -FilePath $out -Encoding utf8
$procs | ForEach-Object { "PID=$($_.ProcessId)`t$($_.CommandLine)" } | Out-File -FilePath $out -Append -Encoding utf8
"REPORT_PATH=$report" | Out-File -FilePath $out -Append -Encoding utf8

if (Test-Path $report) {
	"REPORT_BYTES=$((Get-Item $report).Length)" | Out-File -FilePath $out -Append -Encoding utf8
	"LAST_EVENTS:" | Out-File -FilePath $out -Append -Encoding utf8
	Get-Content -Path $report -Tail 20 | Out-File -FilePath $out -Append -Encoding utf8
}
