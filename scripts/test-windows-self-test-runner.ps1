$ErrorActionPreference = "Stop"
$runner = Join-Path $PSScriptRoot "run-windows-self-test.ps1"
$root = Join-Path $env:TEMP ("ah-runner-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $root | Out-Null
$source = Join-Path $root "Fake.cs"
$exe = Join-Path $root "Fake.exe"
$report = Join-Path $root "report with spaces.txt"
$originalMode = $env:AGENT_HALO_SELF_TEST_FIXTURE_MODE
try {
    @'
using System;
using System.IO;
class Fake {
    static int Main(string[] args) {
        string mode = Environment.GetEnvironmentVariable("AGENT_HALO_SELF_TEST_FIXTURE_MODE");
        if (mode == "missing") return 0;
        File.WriteAllText(args[1], mode == "bad-report" ? "FAIL\nfixture" : mode == "empty" ? "" : "PASS\nfixture");
        return mode == "nonzero" ? 42 : 0;
    }
}
'@ | Set-Content -LiteralPath $source
    & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /out:$exe $source
    if ($LASTEXITCODE -ne 0) { throw "Failed to compile self-test runner fixture" }
    foreach ($mode in @("pass", "nonzero", "missing", "bad-report", "empty")) {
        $env:AGENT_HALO_SELF_TEST_FIXTURE_MODE = $mode
        # Every case starts with stale success to prove it is removed.
        Set-Content -LiteralPath $report -Value "PASS`nstale success"
        $failed = $false
        try { & $runner -FilePath $exe -OutputPath $report | Out-Null }
        catch { $failed = $true }
        if ($failed -ne ($mode -ne "pass")) { throw "Unexpected runner result for $mode" }
    }
    Write-Output "PASS Windows self-test runner: success, nonzero exit, missing/stale, FAIL and empty reports"
}
finally {
    $env:AGENT_HALO_SELF_TEST_FIXTURE_MODE = $originalMode
    Remove-Item -LiteralPath $root -Recurse -Force
}
