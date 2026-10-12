param([string]$OpenCode = "$env:APPDATA\npm\node_modules\opencode-ai\bin\opencode.exe")
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path $repo 'outputs\opencode-live-workspace'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$assembly = [Reflection.Assembly]::LoadFile((Join-Path $repo 'outputs\AgentHalo\AgentHalo.exe'))
$flags = [Reflection.BindingFlags]'NonPublic,Public,Static,Instance'
$configurator = $assembly.GetType('CodexHalo.OpenCodePluginConfigurator')
$installed = $configurator.GetMethod('Configure', $flags).Invoke($null, [object[]]@($null))
if (-not $installed) { throw 'Plugin installation failed' }
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()
$base = "http://127.0.0.1:$port"
$query = '?directory=' + [Uri]::EscapeDataString($work)
$server = $null
$session = $null
try {
    $server = Start-Process -FilePath $OpenCode -ArgumentList @('serve', '--hostname', '127.0.0.1', '--port', "$port") -WorkingDirectory $work -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $repo 'outputs\opencode-live.stdout.log') -RedirectStandardError (Join-Path $repo 'outputs\opencode-live.stderr.log')
    $healthy = $false
    for ($i = 0; $i -lt 40; $i++) {
        try { $null = Invoke-RestMethod "$base/global/health" -TimeoutSec 1; $healthy = $true; break } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $healthy) { throw 'Local OpenCode server did not become healthy' }
    $session = Invoke-RestMethod "$base/session$query" -Method Post -ContentType 'application/json' -Body '{"title":"Agent Halo local integration test"}' -TimeoutSec 30
    $snapshot = $null
    for ($i = 0; $i -lt 40; $i++) {
        $files = Get-ChildItem "$env:USERPROFILE\.agent-halo\cache\opencode" -Filter "$($server.Id)-*.json" -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $candidate = Get-Content $file.FullName -Raw | ConvertFrom-Json
            if ($candidate.sessions.id -contains $session.id) { $snapshot = $candidate; break }
        }
        if ($snapshot) { break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $snapshot) { throw 'Real OpenCode did not publish the new session to the plugin snapshot' }
    $type = $assembly.GetType('CodexHalo.OpenCodeMonitor')
    $monitor = [Activator]::CreateInstance($type, $flags, $null, [object[]]@($null), $null)
    for ($i = 0; $i -lt 8; $i++) {
        $aggregate = $type.GetMethod('Aggregate', $flags).Invoke($monitor, [object[]]@($false))
        if ($aggregate.Label -eq 'STANDBY') { break }
        Start-Sleep -Milliseconds 250
    }
    if ($aggregate.Label -ne 'STANDBY') { throw "Monitor returned $($aggregate.Label), expected STANDBY" }
    $null = Invoke-RestMethod "$base/session/$($session.id)$query" -Method Delete -TimeoutSec 10
    $session = $null
    Stop-Process -Id $server.Id
    $server.WaitForExit(5000) | Out-Null
    $expected = if (Get-Process opencode -ErrorAction SilentlyContinue) { 'CONNECTING' } else { 'OFFLINE' }
    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Milliseconds 250
        $aggregate = $type.GetMethod('Aggregate', $flags).Invoke($monitor, [object[]]@($false))
        if ($aggregate.Label -eq $expected) { break }
    }
    if ($aggregate.Label -ne $expected) { throw 'Exited plugin instance still supplies an active state' }
    Write-Output "PASS: actual OpenCode plugin loading, session.created, snapshot ingestion, STANDBY and process-exit $expected. No model request was sent."
} finally {
    if ($session) { try { $null = Invoke-RestMethod "$base/session/$($session.id)$query" -Method Delete -TimeoutSec 3 } catch {} }
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id }
}
