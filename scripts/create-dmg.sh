#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
output_root="$repo_root/outputs/AgentHalo-macOS"
app_dir="$output_root/AgentHalo.app"
app_icon="$repo_root/assets/agent-halo-app-icon.icns"
dmg_staging="$output_root/dmg-staging"
dmg_rw="$output_root/AgentHalo-rw.dmg"
dmg_output="$repo_root/outputs/AgentHalo-macOS-1.0.0.dmg"

# 检查 .app 是否存在
if [ ! -d "$app_dir" ]; then
    echo "Error: AgentHalo.app not found at $app_dir"
    echo "Please run scripts/build-macos.sh first"
    exit 1
fi

if [ ! -f "$app_icon" ]; then
    echo "Error: app icon not found at $app_icon" >&2
    echo "Regenerate with: python3 scripts/generate_app_icons.py" >&2
    exit 1
fi

# 清理旧的 staging 目录和 DMG 文件
rm -rf "$dmg_staging"
rm -f "$dmg_output" "$dmg_rw"

# 创建 staging 目录
mkdir -p "$dmg_staging"

# 复制 .app 到 staging 目录
echo "Copying AgentHalo.app to staging directory..."
cp -R "$app_dir" "$dmg_staging/"

# 创建 Applications 目录的符号链接,方便用户拖拽安装
echo "Creating Applications symlink..."
ln -s /Applications "$dmg_staging/Applications"

# 创建可写 DMG，写入卷图标后再压缩
echo "Creating DMG..."
if [ -d /Volumes/AgentHalo ]; then
    hdiutil detach /Volumes/AgentHalo >/dev/null || true
fi

hdiutil create -volname "AgentHalo" \
    -srcfolder "$dmg_staging" \
    -ov -format UDRW \
    "$dmg_rw"

device=""
cleanup_rw() {
    if [ -n "$device" ]; then
        hdiutil detach "$device" -quiet >/dev/null 2>&1 || true
    fi
    rm -f "$dmg_rw"
}
trap cleanup_rw EXIT

mount_output="$(hdiutil attach -readwrite -noverify -noautoopen "$dmg_rw")"
volume="$(printf '%s\n' "$mount_output" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
device="$(printf '%s\n' "$mount_output" | awk '/^\/dev\/disk/ {print $1; exit}')"
if [ -z "$volume" ] || [ ! -d "$volume" ]; then
    echo "Error: failed to mount $dmg_rw" >&2
    printf '%s\n' "$mount_output" >&2
    exit 1
fi

cp "$app_icon" "$volume/.VolumeIcon.icns"
SetFile -c icnC "$volume/.VolumeIcon.icns"
SetFile -a C "$volume"

hdiutil detach "$device" >/dev/null
device=""
hdiutil convert "$dmg_rw" -format UDZO -imagekey zlib-level=9 -o "$dmg_output"
trap - EXIT
rm -f "$dmg_rw"

# 清理 staging 目录
rm -rf "$dmg_staging"

echo ""
echo "✅ DMG created successfully!"
echo "📦 Location: $dmg_output"
echo ""
echo "File size:"
ls -lh "$dmg_output" | awk '{print $5, $9}'
echo ""
echo "To create a GitHub release:"
echo "  1. Create a new tag: git tag v1.0.0 && git push origin v1.0.0"
echo "  2. Use GitHub CLI: gh release create v1.0.0 \"$dmg_output\" --title \"AgentHalo v1.0.0\" --notes-file docs/RELEASE_NOTES_1.0.0.md"
echo "  Or upload manually at: https://github.com/YOUR_USERNAME/AgentHalo/releases/new"
