$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$output = Join-Path $root "outputs\AgentHalo"
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if (-not (Test-Path -LiteralPath $csc)) {
    throw "The Windows C# compiler was not found at $csc"
}

New-Item -ItemType Directory -Force -Path $output | Out-Null

$sqliteVersion = "3530200"
$sqliteExe = Join-Path $root "tools\sqlite3.exe"
if (-not (Test-Path -LiteralPath $sqliteExe)) {
    $tools = Split-Path -Parent $sqliteExe
    $zip = Join-Path $env:TEMP "sqlite-tools-win-x64-$sqliteVersion.zip"
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    Invoke-WebRequest "https://sqlite.org/2026/sqlite-tools-win-x64-$sqliteVersion.zip" `
        -OutFile $zip
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

$iconPath = Join-Path $root "AgentHalo.ico"
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
    /out:$exe /win32manifest:"$root\app.manifest" /win32icon:$iconPath `
    $referenceArgs "$root\windows\GeneratedHaloSpec.cs" "$root\Program.cs"

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

$archive = Join-Path (Split-Path -Parent $output) "AgentHalo-Windows-v0.12.0.zip"
Remove-Item -LiteralPath $archive -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $output "*") -DestinationPath $archive `
    -CompressionLevel Optimal

Write-Host "Built $exe"
Write-Host "Packaged $archive"
