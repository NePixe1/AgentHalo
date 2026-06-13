#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
mac_root="$repo_root/mac"
output_root="$repo_root/outputs/AgentHalo-macOS"
app_dir="$output_root/AgentHalo.app"
binary="$mac_root/.build/release/AgentHaloMac"

cd "$mac_root"
swift run AgentHaloCoreChecks
swift run AgentHaloDiagnostics --self-test "$output_root/diagnostics-self-test.txt"
swift build -c release --product AgentHaloDiagnostics
swift build -c release --product AgentHaloMac

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary" "$app_dir/Contents/MacOS/AgentHaloMac"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>AgentHaloMac</string>
  <key>CFBundleIdentifier</key>
  <string>local.agenthalo.mac</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Agent Halo</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.11.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

chmod +x "$app_dir/Contents/MacOS/AgentHaloMac"

echo "Built $app_dir"
echo "Run with: open \"$app_dir\""
