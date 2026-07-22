#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
output_root="$repo_root/outputs/AgentHalo-macOS"
app_dir="$output_root/AgentHalo.app"
dmg_staging="$output_root/dmg-staging"
dmg_output="$repo_root/outputs/AgentHalo-macOS-1.0.0.dmg"

# 检查 .app 是否存在
if [ ! -d "$app_dir" ]; then
    echo "Error: AgentHalo.app not found at $app_dir"
    echo "Please run scripts/build-macos.sh first"
    exit 1
fi

# 清理旧的 staging 目录和 DMG 文件
rm -rf "$dmg_staging"
rm -f "$dmg_output"

# 创建 staging 目录
mkdir -p "$dmg_staging"

# 复制 .app 到 staging 目录
echo "Copying AgentHalo.app to staging directory..."
cp -R "$app_dir" "$dmg_staging/"

# 创建 Applications 目录的符号链接,方便用户拖拽安装
echo "Creating Applications symlink..."
ln -s /Applications "$dmg_staging/Applications"

# 创建 DMG 文件
echo "Creating DMG..."
hdiutil create -volname "AgentHalo" \
    -srcfolder "$dmg_staging" \
    -ov -format UDZO \
    "$dmg_output"

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
