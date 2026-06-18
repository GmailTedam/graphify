$ErrorActionPreference = "Continue"

$root = "C:\Users\hgeec\github"
$defaultReport = Join-Path $root "graphify-batch-report.txt"
$reportPointer = Join-Path $root "graphify-batch-report-current.txt"
$report = $defaultReport
$quotaAlerts = Join-Path $root "graphify-quota-alerts.txt"
$graphifyPython = "C:\Users\hgeec\github\graphify\.venv\Scripts\python.exe"
$extractMaxConcurrency = if ($env:GRAPHIFY_EXTRACT_MAX_CONCURRENCY) { [int]$env:GRAPHIFY_EXTRACT_MAX_CONCURRENCY } else { 1 }
$extractTokenBudget = if ($env:GRAPHIFY_EXTRACT_TOKEN_BUDGET) { [int]$env:GRAPHIFY_EXTRACT_TOKEN_BUDGET } else { 30000 }
$extractApiTimeout = if ($env:GRAPHIFY_EXTRACT_API_TIMEOUT) { [int]$env:GRAPHIFY_EXTRACT_API_TIMEOUT } else { 900 }

$quotaPattern = "RESOURCE_EXHAUSTED|Quota exceeded|\berror\s*code\s*:\s*429\b|rate-?limit"

function Invoke-Graphify {
    param([string[]]$CliArgs)
    if (Test-Path $graphifyPython) {
        & $graphifyPython -m graphify @CliArgs
    } else {
        & graphify @CliArgs
    }
}

function Invoke-GraphifyCapture {
    param([string[]]$CliArgs)

    $output = @()
    if (Test-Path $graphifyPython) {
        $output = (& $graphifyPython -m graphify @CliArgs 2>&1 | Tee-Object -FilePath $report -Append)
    } else {
        $output = (& graphify @CliArgs 2>&1 | Tee-Object -FilePath $report -Append)
    }

    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
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

function Write-QuotaAlert {
    param(
        [string]$RepoPath,
        [string]$Phase,
        [string]$Command
    )

    $stamp = (Get-Date).ToString("s")
    $line = "$stamp`t$Phase`t$RepoPath`t$Command"
    $line | Out-File -FilePath $quotaAlerts -Append -Encoding utf8
    Write-ReportLine "QUOTA_EXHAUSTED`t$Phase`t$RepoPath`t$Command"
}

function Invoke-GraphifyExtract {
    param([string]$RepoPath)

    $baseArgs = @(
        "extract", ".",
        "--max-concurrency", "$extractMaxConcurrency",
        "--token-budget", "$extractTokenBudget",
        "--api-timeout", "$extractApiTimeout"
    )

    $first = Invoke-GraphifyCapture -CliArgs $baseArgs
    $exitCode = $first.ExitCode
    $hadQuota = Test-QuotaExhaustion -Output $first.Output

    if ($exitCode -eq 0) {
        return [pscustomobject]@{ ExitCode = 0; HadQuota = $hadQuota }
    }

    Write-ReportLine "EXTRACT_RETRY`t$($PWD.Path)`tfirst-exit=$exitCode"
    Start-Sleep -Seconds 3
    $retry = Invoke-GraphifyCapture -CliArgs ($baseArgs + @("--max-concurrency", "1"))
    $hadQuota = $hadQuota -or (Test-QuotaExhaustion -Output $retry.Output)

    if ($hadQuota -and $retry.ExitCode -ne 0) {
        $cmdText = "extract . --max-concurrency $extractMaxConcurrency --token-budget $extractTokenBudget --api-timeout $extractApiTimeout"
        Write-QuotaAlert -RepoPath $RepoPath -Phase "extract" -Command $cmdText
    }

    return [pscustomobject]@{ ExitCode = $retry.ExitCode; HadQuota = $hadQuota }
}

function Write-ReportLine {
    param([string]$Line)
    $attempted = 0
    while ($attempted -lt 5) {
        try {
            $Line | Out-File -FilePath $report -Append -Encoding utf8
            return
        } catch {
            $attempted++
            Start-Sleep -Milliseconds 200
        }
    }
    throw "Unable to write to report file: $report"
}

if (Test-Path $defaultReport) {
    try {
        Remove-Item $defaultReport -Force -ErrorAction Stop
    } catch {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $report = Join-Path $root ("graphify-batch-report-" + $timestamp + ".txt")
    }
}

$report | Out-File -FilePath $reportPointer -Encoding utf8

$ghAvailable = [bool](Get-Command gh -ErrorAction SilentlyContinue)
"GH_AVAILABLE=$ghAvailable" | Out-File -FilePath $report -Encoding utf8
Write-ReportLine "REPORT_PATH`t$report"
"$((Get-Date).ToString("s"))`tRUN_START`t$report" | Out-File -FilePath $quotaAlerts -Append -Encoding utf8

$repos = Get-ChildItem -Path $root -Directory | Where-Object { Test-Path (Join-Path $_.FullName ".git") }

foreach ($r in $repos) {
    $origin = git -C $r.FullName remote get-url origin 2>$null
    $slug = ""

    if ($origin -match "github\.com[:/](?<slug>[^\s]+?)(?:\.git)?$") {
        $slug = $Matches.slug
    }

    $status = "NONFORK"
    if ($ghAvailable -and $slug) {
        $forkTxt = gh repo view $slug --json isFork -q ".isFork" 2>$null
        if ($LASTEXITCODE -eq 0 -and $forkTxt) {
            if ($forkTxt -eq "true") {
                $status = "FORK"
            }
        } else {
            $status = "UNKNOWN"
        }
    } elseif (-not $slug) {
        $status = "UNKNOWN"
    }

    if ($status -eq "FORK") {
        Write-ReportLine "SKIP`t$($r.FullName)`t$status`t$slug"
        continue
    }

    Write-ReportLine "RUN`t$($r.FullName)`t$status`t$slug"

    Push-Location $r.FullName
    $extractResult = Invoke-GraphifyExtract -RepoPath $r.FullName
    $extractExit = $extractResult.ExitCode

    if ($extractExit -ne 0) {
        Write-ReportLine "EXTRACT_FAIL`t$($r.FullName)`texit=$extractExit"
        Write-ReportLine "FAIL`t$($r.FullName)`texit=$extractExit"
    } else {
        Write-ReportLine "EXTRACT_OK`t$($r.FullName)"
        $clusterCmd = @("cluster-only", ".", "--no-viz")
        $clusterResult = Invoke-GraphifyCapture -CliArgs $clusterCmd
        $clusterExit = $clusterResult.ExitCode
        if (($clusterExit -ne 0) -and (Test-QuotaExhaustion -Output $clusterResult.Output)) {
            Write-QuotaAlert -RepoPath $r.FullName -Phase "cluster-only" -Command "cluster-only . --no-viz"
        }
        if ($clusterExit -eq 0) {
            Write-ReportLine "CLUSTER_OK`t$($r.FullName)"
            Write-ReportLine "OK`t$($r.FullName)"
        } else {
            Write-ReportLine "CLUSTER_FAIL`t$($r.FullName)`texit=$clusterExit"
            Write-ReportLine "FAIL`t$($r.FullName)`texit=$clusterExit"
        }
    }

    Pop-Location
}

Write-ReportLine "DONE"
