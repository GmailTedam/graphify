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
$recoveryBackend = if ($env:GRAPHIFY_RECOVERY_BACKEND) { $env:GRAPHIFY_RECOVERY_BACKEND } else { "openai" }
$extractBackend = if ($env:GRAPHIFY_EXTRACT_BACKEND) { $env:GRAPHIFY_EXTRACT_BACKEND } else { $recoveryBackend }
$labelBackend = if ($env:GRAPHIFY_LABEL_BACKEND) { $env:GRAPHIFY_LABEL_BACKEND } else { $extractBackend }
$extractModel = if ($env:GRAPHIFY_EXTRACT_MODEL) { $env:GRAPHIFY_EXTRACT_MODEL } else { "" }
$labelModel = if ($env:GRAPHIFY_LABEL_MODEL) { $env:GRAPHIFY_LABEL_MODEL } else { $extractModel }
$retryRecovered = $env:GRAPHIFY_RECOVERY_RETRY_OK -match "^(1|true|yes)$"

$quotaPattern = "RESOURCE_EXHAUSTED|Quota exceeded|\berror\s*code\s*:\s*429\b|rate-?limit"

function Add-BackendArgs {
    param(
        [string[]]$CliArgs,
        [string]$Backend,
        [string]$Model
    )

    $out = @($CliArgs)
    if ($Backend -and ($Backend.Trim().ToLowerInvariant() -ne "auto")) {
        $out += @("--backend", $Backend.Trim())
    }
    if ($Model -and ($Model.Trim().Length -gt 0)) {
        $out += @("--model", $Model.Trim())
    }
    return $out
}

function Format-GraphifyCommand {
    param([string[]]$CliArgs)

    return ($CliArgs -join " ")
}

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

$previousRecoveryText = ""
if (Test-Path $recoveryPointer) {
    $previousRecoveryPath = (Get-Content -Path $recoveryPointer -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    if ($previousRecoveryPath -and (Test-Path $previousRecoveryPath)) {
        $previousRecoveryText = (Get-Content -Path $previousRecoveryPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue) -replace "`0", ""
    }
}
if (-not $previousRecoveryText -and (Test-Path $defaultRecoveryReport)) {
    $previousRecoveryText = (Get-Content -Path $defaultRecoveryReport -Raw -Encoding utf8 -ErrorAction SilentlyContinue) -replace "`0", ""
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

$alreadyRecovered = @()
if (-not $retryRecovered -and $previousRecoveryText) {
    $okMatches = [regex]::Matches($previousRecoveryText, "(?m)^(?:RECOVER_OK|RESUME_SKIP_OK)\t(?<repo>[A-Za-z]:\\[^\t\r\n]+)")
    foreach ($m in $okMatches) {
        $repo = $m.Groups["repo"].Value
        if ($repo -and -not ($alreadyRecovered -contains $repo)) {
            $alreadyRecovered += $repo
        }
    }
    if ($alreadyRecovered.Count -gt 0) {
        $failedRepos = @($failedRepos | Where-Object { -not ($alreadyRecovered -contains $_) })
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
Write-RecoveryLine "PREVIOUS_RECOVERED_OK=$($alreadyRecovered.Count)"
Write-RecoveryLine "RECOVERY_BACKEND=$recoveryBackend"
Write-RecoveryLine "EXTRACT_BACKEND=$extractBackend"
Write-RecoveryLine "LABEL_BACKEND=$labelBackend"
if ($extractModel) {
    Write-RecoveryLine "EXTRACT_MODEL=$extractModel"
}
if ($labelModel) {
    Write-RecoveryLine "LABEL_MODEL=$labelModel"
}

if ($failedRepos.Count -eq 0) {
    Write-RecoveryLine "NO_FAILURES_FOUND"
    exit 0
}

foreach ($repo in $alreadyRecovered) {
    Write-RecoveryLine "RESUME_SKIP_OK`t$repo"
}

function Invoke-GraphifyCapture {
    param(
        [string]$RepoPath,
        [string[]]$CliArgs
    )

    $output = @()
    Push-Location $RepoPath
    try {
        Write-RecoveryLine "RECOVER_CMD`t$RepoPath`t$(Format-GraphifyCommand -CliArgs $CliArgs)"
        if (Test-Path $graphifyPython) {
            & $graphifyPython -m graphify @CliArgs 2>&1 | ForEach-Object {
                $line = "$_"
                $output += $line
                Write-RecoveryLine $line
            }
        } else {
            & graphify @CliArgs 2>&1 | ForEach-Object {
                $line = "$_"
                $output += $line
                Write-RecoveryLine $line
            }
        }
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
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
    $extractArgs = Add-BackendArgs -CliArgs $extractArgs -Backend $extractBackend -Model $extractModel

    $extract = Invoke-GraphifyCapture -RepoPath $repo -CliArgs $extractArgs

    if (($extract.ExitCode -ne 0) -and (Test-QuotaExhaustion -Output $extract.Output)) {
        "$((Get-Date).ToString("s"))`tRECOVERY_EXTRACT`t$repo`t$(Format-GraphifyCommand -CliArgs $extractArgs)" | Out-File -FilePath $quotaAlerts -Append -Encoding utf8
        Write-RecoveryLine "RECOVERY_QUOTA_EXHAUSTED`t$repo`textract"
    }

    if ($extract.ExitCode -ne 0) {
        Write-RecoveryLine "RECOVER_FAIL`t$repo`textract-exit=$($extract.ExitCode)"
        continue
    }

    Write-RecoveryLine "RECOVER_EXTRACT_OK`t$repo"

    $clusterArgs = Add-BackendArgs -CliArgs @("cluster-only", ".", "--no-viz") -Backend $labelBackend -Model $labelModel
    $cluster = Invoke-GraphifyCapture -RepoPath $repo -CliArgs $clusterArgs

    if (($cluster.ExitCode -ne 0) -and (Test-QuotaExhaustion -Output $cluster.Output)) {
        "$((Get-Date).ToString("s"))`tRECOVERY_CLUSTER`t$repo`t$(Format-GraphifyCommand -CliArgs $clusterArgs)" | Out-File -FilePath $quotaAlerts -Append -Encoding utf8
        Write-RecoveryLine "RECOVERY_QUOTA_EXHAUSTED`t$repo`tcluster-only"
    }

    if ($cluster.ExitCode -ne 0) {
        Write-RecoveryLine "RECOVER_FAIL`t$repo`tcluster-exit=$($cluster.ExitCode)"
        continue
    }

    Write-RecoveryLine "RECOVER_OK`t$repo"
}

Write-RecoveryLine "RECOVERY_DONE"
