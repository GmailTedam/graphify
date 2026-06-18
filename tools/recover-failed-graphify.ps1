$ErrorActionPreference = "Continue"

$root = "C:\Users\hgeec\github"
$reportPointer = Join-Path $root "graphify-batch-report-current.txt"
$batchReport = Join-Path $root "graphify-batch-report.txt"
$defaultRecoveryReport = Join-Path $root "graphify-recovery-report.txt"
$recoveryPointer = Join-Path $root "graphify-recovery-report-current.txt"
$recoveryReport = $defaultRecoveryReport
$quotaAlerts = Join-Path $root "graphify-quota-alerts.txt"
$graphifyPython = "C:\Users\hgeec\github\graphify\.venv\Scripts\python.exe"

$extractMaxConcurrency = if ($env:GRAPHIFY_EXTRACT_MAX_CONCURRENCY) { [int]$env:GRAPHIFY_EXTRACT_MAX_CONCURRENCY } else { 1 }
$extractTokenBudget = if ($env:GRAPHIFY_EXTRACT_TOKEN_BUDGET) { [int]$env:GRAPHIFY_EXTRACT_TOKEN_BUDGET } else { 30000 }
$extractApiTimeout = if ($env:GRAPHIFY_EXTRACT_API_TIMEOUT) { [int]$env:GRAPHIFY_EXTRACT_API_TIMEOUT } else { 900 }

$quotaPattern = "RESOURCE_EXHAUSTED|Quota exceeded|\berror\s*code\s*:\s*429\b|rate-?limit"

if (Test-Path $reportPointer) {
    $pointerPath = (Get-Content -Path $reportPointer -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    if ($pointerPath) {
        $batchReport = $pointerPath
    }
}

if (-not (Test-Path $batchReport)) {
    "REPORT_MISSING`t$batchReport" | Out-File -FilePath $recoveryReport -Encoding utf8
    exit 1
}

function Write-RecoveryLine {
    param([string]$Line)
    $Line = $Line -replace "`0", ""
    $attempted = 0
    while ($attempted -lt 5) {
        try {
            $Line | Out-File -FilePath $recoveryReport -Append -Encoding utf8
            return
        } catch {
            $attempted++
            Start-Sleep -Milliseconds 200
        }
    }
    throw "Unable to write to recovery report file: $recoveryReport"
}

$reportText = Get-Content -Path $batchReport -Raw -Encoding utf8
$failMatches = [regex]::Matches($reportText, "(?m)^FAIL\t(?<repo>[A-Za-z]:\\[^\t]+)\texit=(?<exit>\d+)")
$failedRepos = @()
foreach ($m in $failMatches) {
    $repo = $m.Groups["repo"].Value
    if ($repo -and -not ($failedRepos -contains $repo)) {
        $failedRepos += $repo
    }
}

if (Test-Path $defaultRecoveryReport) {
    try {
        Remove-Item $defaultRecoveryReport -Force -ErrorAction Stop
    } catch {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $recoveryReport = Join-Path $root ("graphify-recovery-report-" + $timestamp + ".txt")
    }
}

$recoveryReport | Out-File -FilePath $recoveryPointer -Encoding utf8

"RECOVERY_SOURCE_REPORT=$batchReport" | Out-File -FilePath $recoveryReport -Encoding utf8
Write-RecoveryLine "RECOVERY_REPORT_PATH=$recoveryReport"
Write-RecoveryLine "FAILED_REPOS=$($failedRepos.Count)"

if ($failedRepos.Count -eq 0) {
    Write-RecoveryLine "NO_FAILURES_FOUND"
    exit 0
}

function Invoke-GraphifyCapture {
    param(
        [string]$RepoPath,
        [string[]]$CliArgs
    )

    $output = @()
    Push-Location $RepoPath
    try {
        if (Test-Path $graphifyPython) {
            $output = (& $graphifyPython -m graphify @CliArgs 2>&1)
        } else {
            $output = (& graphify @CliArgs 2>&1)
        }
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    foreach ($line in @($output)) {
        Write-RecoveryLine "$line"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Test-QuotaExhaustion {
    param([object[]]$Output)

    if (-not $Output) {
        return $false
    }

    $text = ($Output | ForEach-Object { "$_" }) -join "`n"
    return ($text -match $quotaPattern)
}

foreach ($repo in $failedRepos) {
    Write-RecoveryLine "RECOVER_RUN`t$repo"

    $extractArgs = @(
        "extract", ".",
        "--max-concurrency", "$extractMaxConcurrency",
        "--token-budget", "$extractTokenBudget",
        "--api-timeout", "$extractApiTimeout"
    )

    $extract = Invoke-GraphifyCapture -RepoPath $repo -CliArgs $extractArgs

    if (($extract.ExitCode -ne 0) -and (Test-QuotaExhaustion -Output $extract.Output)) {
        "$((Get-Date).ToString("s"))`tRECOVERY_EXTRACT`t$repo`textract . --max-concurrency $extractMaxConcurrency --token-budget $extractTokenBudget --api-timeout $extractApiTimeout" | Out-File -FilePath $quotaAlerts -Append -Encoding utf8
        Write-RecoveryLine "RECOVERY_QUOTA_EXHAUSTED`t$repo`textract"
    }

    if ($extract.ExitCode -ne 0) {
        Write-RecoveryLine "RECOVER_FAIL`t$repo`textract-exit=$($extract.ExitCode)"
        continue
    }

    Write-RecoveryLine "RECOVER_EXTRACT_OK`t$repo"

    $cluster = Invoke-GraphifyCapture -RepoPath $repo -CliArgs @("cluster-only", ".", "--no-viz")

    if (($cluster.ExitCode -ne 0) -and (Test-QuotaExhaustion -Output $cluster.Output)) {
        "$((Get-Date).ToString("s"))`tRECOVERY_CLUSTER`t$repo`tcluster-only . --no-viz" | Out-File -FilePath $quotaAlerts -Append -Encoding utf8
        Write-RecoveryLine "RECOVERY_QUOTA_EXHAUSTED`t$repo`tcluster-only"
    }

    if ($cluster.ExitCode -ne 0) {
        Write-RecoveryLine "RECOVER_FAIL`t$repo`tcluster-exit=$($cluster.ExitCode)"
        continue
    }

    Write-RecoveryLine "RECOVER_OK`t$repo"
}

Write-RecoveryLine "RECOVERY_DONE"
