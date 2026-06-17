$ErrorActionPreference = "Stop"

$scripts = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scripts
$windows = Join-Path $root "src\windows"
$output = Join-Path $root "outputs\AgentHalo"
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if (-not (Test-Path -LiteralPath $csc)) {
    throw "The Windows C# compiler was not found at $csc"
}

New-Item -ItemType Directory -Force -Path $output | Out-Null

$sqliteVersion = "3530200"
$cacheRoot = Join-Path $env:LOCALAPPDATA "AgentHalo\build-cache"
$sqliteExe = Join-Path $cacheRoot "sqlite3-$sqliteVersion.exe"
if (-not (Test-Path -LiteralPath $sqliteExe)) {
    $zip = Join-Path $env:TEMP "sqlite-tools-win-x64-$sqliteVersion.zip"
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $sqliteUrls = @(
        "https://sqlite.org/2026/sqlite-tools-win-x64-$sqliteVersion.zip",
        "https://www.sqlite.org/2026/sqlite-tools-win-x64-$sqliteVersion.zip"
    )
    $downloaded = $false
    $lastError = $null
    foreach ($url in $sqliteUrls) {
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing `
                    -TimeoutSec 60
                $downloaded = $true
                break
            } catch {
                $lastError = $_
                Write-Host ("sqlite download attempt {0} from {1} failed: {2}" `
                    -f $attempt, $url, $_.Exception.Message)
                Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2, $attempt)))
            }
        }
        if ($downloaded) { break }
    }
    if (-not $downloaded) {
        throw "Failed to download sqlite tools after retries: $lastError"
    }
    $extract = Join-Path $env:TEMP "agenthalo-sqlite-$sqliteVersion"
    Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $zip -DestinationPath $extract
    Copy-Item -LiteralPath (Get-ChildItem $extract -Recurse -Filter sqlite3.exe |
        Select-Object -First 1).FullName -Destination $sqliteExe
}

$framework = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$wpf = Join-Path $framework "WPF"
$references = @(
    (Join-Path $framework "System.dll"),
    (Join-Path $framework "System.Core.dll"),
    (Join-Path $framework "System.Drawing.dll"),
    (Join-Path $framework "System.Windows.Forms.dll"),
    (Join-Path $framework "System.Web.Extensions.dll"),
    (Join-Path $framework "Microsoft.CSharp.dll"),
    (Join-Path $wpf "WindowsBase.dll"),
    (Join-Path $wpf "PresentationCore.dll"),
    (Join-Path $wpf "PresentationFramework.dll"),
    (Join-Path $framework "System.Xaml.dll")
)

$iconPath = Join-Path $env:TEMP "AgentHalo-build.ico"
Add-Type -AssemblyName System.Drawing
$bitmap = New-Object System.Drawing.Bitmap 64, 64
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([System.Drawing.Color]::Transparent)
$glow = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(80, 43, 200, 255)), 11
$ring = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 43, 200, 255)), 6
$glow.StartCap = $glow.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$ring.StartCap = $ring.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
foreach ($pen in @($glow, $ring)) {
    $graphics.DrawArc($pen, 10, 10, 44, 44, -52, 140)
    $graphics.DrawArc($pen, 10, 10, 44, 44, 106, 194)
}
$handle = $bitmap.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($handle)
$stream = [System.IO.File]::Create($iconPath)
$icon.Save($stream)
$stream.Dispose()
$icon.Dispose()
$glow.Dispose()
$ring.Dispose()
$graphics.Dispose()
$bitmap.Dispose()

$referenceArgs = $references | ForEach-Object { "/reference:$_" }
$exe = Join-Path $output "AgentHalo.exe"

& $csc /nologo /target:winexe /platform:anycpu /optimize+ `
    /out:$exe /win32manifest:"$windows\app.manifest" /win32icon:$iconPath `
    $referenceArgs "$windows\GeneratedHaloSpec.cs" "$windows\Program.cs"

if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed with exit code $LASTEXITCODE"
}

Copy-Item -LiteralPath "$root\README.md" -Destination "$output\README.md" -Force
Copy-Item -LiteralPath $sqliteExe -Destination "$output\sqlite3.exe" -Force
Remove-Item -LiteralPath (Join-Path $output "AgentHalo.pdb") -ErrorAction SilentlyContinue

$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
$hashLine = "$hash  AgentHalo.exe"
Set-Content -LiteralPath (Join-Path $output "SHA256.txt") -Value $hashLine `
    -Encoding ascii -NoNewline

$archive = Join-Path (Split-Path -Parent $output) "AgentHalo-Windows-v0.13.0.zip"
Remove-Item -LiteralPath $archive -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $output "*") -DestinationPath $archive `
    -CompressionLevel Optimal

Write-Host "Built $exe"
Write-Host "Packaged $archive"
