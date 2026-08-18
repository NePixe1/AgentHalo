$ErrorActionPreference = "Stop"

$scripts = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scripts
$windows = Join-Path $root "src\windows"
$output = Join-Path $root "outputs\AgentHalo"
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

# Sync shared locale JSON into the Windows target so the build copies real
# file contents rather than relying on cross-platform symlink semantics.
$sharedLocales = Join-Path $root "src\shared\locales"
$windowsLocales = Join-Path $windows "locales"
New-Item -ItemType Directory -Force -Path $windowsLocales | Out-Null
Copy-Item -LiteralPath (Join-Path $sharedLocales "zh.json") -Destination (Join-Path $windowsLocales "zh.json") -Force
Copy-Item -LiteralPath (Join-Path $sharedLocales "en.json") -Destination (Join-Path $windowsLocales "en.json") -Force

if (-not (Test-Path -LiteralPath $csc)) {
    throw "The Windows C# compiler was not found at $csc"
}

New-Item -ItemType Directory -Force -Path $output | Out-Null

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

$iconPath = Join-Path $root "assets\agent-halo-app-icon.ico"
if (-not (Test-Path -LiteralPath $iconPath)) {
    throw "Missing app icon: $iconPath`nRegenerate with: python3 scripts/generate_app_icons.py"
}

$referenceArgs = $references | ForEach-Object { "/reference:$_" }
$resourceArgs = @(
    "/resource:$(Join-Path $windowsLocales "zh.json"),CodexHalo.locales.zh.json",
    "/resource:$(Join-Path $windowsLocales "en.json"),CodexHalo.locales.en.json",
    "/resource:$(Join-Path $root "src\shared\integrations\pi\agent-halo-status.ts"),AgentHalo.PiStatusExtension"
)
$exe = Join-Path $output "AgentHalo.exe"
$sources = Get-ChildItem -LiteralPath $windows -Filter *.cs |
    Sort-Object Name |
    ForEach-Object { $_.FullName }

& $csc /nologo /target:exe /platform:anycpu /optimize+ /main:CodexHalo.Program `
    /out:$exe /win32manifest:"$windows\app.manifest" /win32icon:$iconPath `
    $referenceArgs $resourceArgs $sources

if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed with exit code $LASTEXITCODE"
}

Copy-Item -LiteralPath "$root\README.md" -Destination "$output\README.md" -Force
$packageAssets = Join-Path $output "assets"
New-Item -ItemType Directory -Force -Path $packageAssets | Out-Null
Copy-Item -LiteralPath (Join-Path $root "assets\agent-halo-app-icon.png") -Destination (Join-Path $packageAssets "agent-halo-app-icon.png") -Force
Copy-Item -LiteralPath (Join-Path $root "assets\agent-halo-readme-banner.png") -Destination (Join-Path $packageAssets "agent-halo-readme-banner.png") -Force
Remove-Item -LiteralPath "$output\locales" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $output "AgentHalo.pdb") -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $output "sqlite3.exe") -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $output "AgentHaloHook.exe") -ErrorAction SilentlyContinue

$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
$hashLine = "$hash  AgentHalo.exe"
Set-Content -LiteralPath (Join-Path $output "SHA256.txt") -Value $hashLine `
    -Encoding ascii -NoNewline

$archive = Join-Path (Split-Path -Parent $output) "AgentHalo-Windows-v1.0.0.zip"
Remove-Item -LiteralPath $archive -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $output "*") -DestinationPath $archive `
    -CompressionLevel Optimal

Write-Host "Built $exe"
Write-Host "Packaged $archive"
