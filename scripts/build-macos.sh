#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
mac_root="$repo_root/src/macos"
output_root="$repo_root/outputs/AgentHalo-macOS"
app_dir="$output_root/AgentHalo.app"
binary="$mac_root/.build/release/AgentHaloMac"
core_resource_bundle="$mac_root/.build/release/AgentHaloMac_AgentHaloCore.bundle"
agent_icon_assets="$repo_root/src/shared/assets/agent-switch"
app_icon="$repo_root/assets/agent-halo-app-icon.icns"
shared_locales="$repo_root/src/shared/locales"
mac_locales="$mac_root/Sources/AgentHaloCore/locales"

if [ ! -f "$app_icon" ]; then
    echo "Missing app icon: $app_icon" >&2
    echo "Regenerate with: python3 scripts/generate_app_icons.py" >&2
    exit 1
fi

# Sync shared locale JSON into the AgentHaloCore target so SwiftPM bundles
# real file contents (resource declarations are scoped per-target and can't
# reach across into src/shared/, so we mirror at build time rather than
# rely on symlinks — symlinks survive into the bundle and become dangling).
mkdir -p "$mac_locales"
cp "$shared_locales/zh.json" "$mac_locales/zh.json"
cp "$shared_locales/en.json" "$mac_locales/en.json"

# Sync shared Pi extension into AgentHaloCore resources (same mirror pattern).
shared_pi_extension="$repo_root/src/shared/integrations/pi/agent-halo-status.ts"
mac_pi_dir="$mac_root/Sources/AgentHaloCore/integrations/pi"
mkdir -p "$mac_pi_dir"
cp "$shared_pi_extension" "$mac_pi_dir/agent-halo-status.ts"

shared_opencode_plugin="$repo_root/src/shared/integrations/opencode/agent-halo-status.js"
mac_opencode_dir="$mac_root/Sources/AgentHaloCore/integrations/opencode"
mkdir -p "$mac_opencode_dir"
cp "$shared_opencode_plugin" "$mac_opencode_dir/agent-halo-status.js"

cd "$mac_root"
# Rebuild hook/proxy before CoreChecks so isolation tests do not run stale
# binaries that still write legacy ~/.agent-halo/* paths.
swift build --product ClaudeCodeStatusHook
swift build --product ClaudeCodeStatusLineProxy
swift run AgentHaloCoreChecks
interaction_check_output="$(swift run AgentHaloMac --self-check)"
printf '%s\n' "$interaction_check_output"
if ! grep -Fxq 'PASS AgentHaloMac checks' <<< "$interaction_check_output"; then
    echo "Interaction self-check exited without its completion marker" >&2
    exit 1
fi
swift run AgentHaloDiagnostics --self-test "$output_root/diagnostics-self-test.txt"
swift build -c release --product AgentHaloDiagnostics
swift build -c release --product AgentHaloMac
swift build -c release --product ClaudeCodeStatusHook
swift build -c release --product ClaudeCodeStatusLineProxy

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/agent-switch"
cp "$binary" "$app_dir/Contents/MacOS/AgentHaloMac"
cp -R "$core_resource_bundle" "$app_dir/Contents/Resources/AgentHaloMac_AgentHaloCore.bundle"
cp "$mac_root/.build/release/ClaudeCodeStatusHook" "$app_dir/Contents/Resources/claude-code-status-hook"
cp "$mac_root/.build/release/ClaudeCodeStatusLineProxy" "$app_dir/Contents/Resources/claude-code-statusline-proxy"
cp "$app_icon" "$app_dir/Contents/Resources/AppIcon.icns"
cp "$agent_icon_assets"/*.svg "$app_dir/Contents/Resources/agent-switch/"
workbuddy_icon="$repo_root/docs/assets/agent-switch/workbuddy.png"
if [ -f "$workbuddy_icon" ]; then
    cp "$workbuddy_icon" "$app_dir/Contents/Resources/agent-switch/workbuddy.png"
fi

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
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>local.agenthalo.mac.v2</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Agent Halo</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.2.0</string>
  <key>CFBundleVersion</key>
  <string>4</string>
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
codesign --force --sign - "$app_dir"
bash "$repo_root/scripts/check-macos-distribution.sh" "$app_dir"

echo "Built $app_dir"
echo "Run with: open \"$app_dir\""
