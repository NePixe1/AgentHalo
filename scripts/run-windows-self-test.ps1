param(
    [string]$FilePath = "./outputs/AgentHalo/AgentHalo.exe",
    [string]$OutputPath = "./outputs/windows-self-test.txt"
)
$ErrorActionPreference = "Stop"
$executable = (Resolve-Path -LiteralPath $FilePath).Path
$report = [System.IO.Path]::GetFullPath($OutputPath)
# Never let a previous successful run stand in for a missing current report.
if (Test-Path -LiteralPath $report) { Remove-Item -LiteralPath $report -Force }
$process = Start-Process -FilePath $executable `
    -ArgumentList @("--self-test", "`"$report`"") -Wait -PassThru
$lines = @()
if (Test-Path -LiteralPath $report -PathType Leaf) {
    $lines = @(Get-Content -LiteralPath $report)
    $lines | Write-Output
}
if ($process.ExitCode -ne 0) {
    throw "Windows self-test failed with exit code $($process.ExitCode)"
}
if ($lines.Count -eq 0 -or $lines[0].Trim() -ne "PASS") {
    throw "Windows self-test did not produce a fresh PASS report: $report"
}
