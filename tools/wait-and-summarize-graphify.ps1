$root = "C:\Users\hgeec\github"
$summary = Join-Path $root "graphify-final-summary.txt"

# Wait for active batch process(es)
$procs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*run-graphify-nonfork.ps1*" }
if ($procs) {
    $ids = $procs | Select-Object -ExpandProperty ProcessId
    Wait-Process -Id $ids -ErrorAction SilentlyContinue
}

$ghAvailable = [bool](Get-Command gh -ErrorAction SilentlyContinue)
$repos = Get-ChildItem -Path $root -Directory | Where-Object { Test-Path (Join-Path $_.FullName ".git") }

$targets = @()
foreach ($r in $repos) {
    $origin = git -C $r.FullName remote get-url origin 2>$null
    $slug = ""
    if ($origin -match "github\.com[:/](?<slug>[^\s]+?)(?:\.git)?$") {
        $slug = $Matches.slug
    }

    $status = "NONFORK"
    if ($ghAvailable -and $slug) {
        $forkTxt = gh repo view $slug --json isFork -q ".isFork" 2>$null
        if ($LASTEXITCODE -eq 0 -and $forkTxt -eq "true") {
            $status = "FORK"
        }
    }

    if ($status -ne "FORK") {
        $outDir = Join-Path $r.FullName "graphify-out"
        $hasOutDir = Test-Path $outDir
        $hasGraphJson = Test-Path (Join-Path $outDir "graph.json")
        $hasReport = Test-Path (Join-Path $outDir "GRAPH_REPORT.md")
        $targets += [pscustomobject]@{
            Repo = $r.Name
            Path = $r.FullName
            Slug = $slug
            HasOutDir = $hasOutDir
            HasGraphJson = $hasGraphJson
            HasReport = $hasReport
        }
    }
}

$outDirOk = ($targets | Where-Object { $_.HasOutDir }).Count
$graphJsonOk = ($targets | Where-Object { $_.HasGraphJson }).Count
$reportOk = ($targets | Where-Object { $_.HasReport }).Count
$missingReport = $targets | Where-Object { -not $_.HasReport }

"NON_FORK_TARGETS=$($targets.Count)" | Out-File -FilePath $summary -Encoding utf8
"WITH_GRAPHIFY_OUT=$outDirOk" | Out-File -FilePath $summary -Append -Encoding utf8
"WITH_GRAPH_JSON=$graphJsonOk" | Out-File -FilePath $summary -Append -Encoding utf8
"WITH_GRAPH_REPORT=$reportOk" | Out-File -FilePath $summary -Append -Encoding utf8
"MISSING_GRAPH_REPORT=$($missingReport.Count)" | Out-File -FilePath $summary -Append -Encoding utf8
"MISSING_REPORT_LIST:" | Out-File -FilePath $summary -Append -Encoding utf8
$missingReport | ForEach-Object { $_.Path } | Out-File -FilePath $summary -Append -Encoding utf8
