#!/usr/bin/env bash
set -euo pipefail

target="${1:-}"
if [ -z "$target" ] || { [ ! -d "$target" ] && [ ! -f "$target" ]; }; then
    echo "usage: $0 /path/to/AgentHalo.app-or.dmg" >&2
    exit 2
fi

mounted_device=""
quarantine_root=""

cleanup() {
    if [ -n "$mounted_device" ]; then
        hdiutil detach "$mounted_device" -quiet >/dev/null 2>&1 || true
    fi
    if [ -n "$quarantine_root" ]; then
        rm -rf "$quarantine_root"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail() {
    echo "Distribution check failed: $*" >&2
    exit 1
}

check_app() {
    app_dir="$1"
    app_dir="$(cd "$app_dir" && pwd -P)"
    contents_dir="$app_dir/Contents"
    resources_dir="$contents_dir/Resources"
    resource_bundle="$resources_dir/AgentHaloMac_AgentHaloCore.bundle"

    [ -d "$contents_dir" ] || fail "missing Contents directory"

    unexpected_root_entry="$(
        find "$app_dir" -mindepth 1 -maxdepth 1 ! -name Contents -print -quit
    )"
    if [ -n "$unexpected_root_entry" ]; then
        fail "unexpected app-bundle root entry: $unexpected_root_entry"
    fi

    [ -d "$resource_bundle" ] || fail "missing packaged Swift resource bundle: $resource_bundle"
    [ -f "$resource_bundle/locales/en.json" ] || fail "missing packaged English locale"
    [ -f "$resource_bundle/locales/zh.json" ] || fail "missing packaged Chinese locale"
    [ -f "$resource_bundle/integrations/pi/agent-halo-status.ts" ] \
        || fail "missing packaged Pi extension"
    [ -x "$contents_dir/MacOS/AgentHaloMac" ] || fail "missing app executable"
    [ -x "$resources_dir/claude-code-status-hook" ] || fail "missing Claude status hook"
    [ -x "$resources_dir/claude-code-statusline-proxy" ] || fail "missing Claude statusline proxy"

    codesign --verify --deep --strict --verbose=4 "$app_dir"

    quarantine_root="$(mktemp -d /tmp/agenthalo-distribution-check.XXXXXX)"
    quarantine_app="$quarantine_root/AgentHalo.app"
    ditto "$app_dir" "$quarantine_app"
    xattr -w com.apple.quarantine '0083;00000000;AgentHaloDistributionCheck;' "$quarantine_app"
    codesign --verify --deep --strict --verbose=4 "$quarantine_app"

    set +e
    gatekeeper_output="$(spctl --assess --type execute --verbose=4 "$quarantine_app" 2>&1)"
    gatekeeper_status=$?
    set -e
    if printf '%s\n' "$gatekeeper_output" | grep -Eqi \
        'code has no resources|invalid signature|sealed resource|unsealed contents|bundle format'; then
        printf '%s\n' "$gatekeeper_output" >&2
        fail "Gatekeeper found a malformed app signature"
    fi
    if [ "$gatekeeper_status" -ne 0 ]; then
        echo "Gatekeeper requires manual approval for this ad-hoc build"
    fi

    rm -rf "$quarantine_root"
    quarantine_root=""
}

check_dmg() {
    dmg_path="$1"
    hdiutil verify "$dmg_path" >/dev/null
    mount_output="$(hdiutil attach -readonly -noverify -noautoopen -nobrowse "$dmg_path")"
    mounted_device="$(printf '%s\n' "$mount_output" | awk '/^\/dev\/disk/ {print $1; exit}')"
    mounted_volume="$(printf '%s\n' "$mount_output" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
    if [ -z "$mounted_device" ] || [ -z "$mounted_volume" ]; then
        fail "failed to mount DMG"
    fi
    check_app "$mounted_volume/AgentHalo.app"
    hdiutil detach "$mounted_device" >/dev/null
    mounted_device=""
}

case "$target" in
    *.app)
        check_app "$target"
        ;;
    *.dmg)
        check_dmg "$target"
        ;;
    *)
        echo "usage: $0 /path/to/AgentHalo.app-or.dmg" >&2
        exit 2
        ;;
esac

trap - EXIT INT TERM HUP
echo "PASS macOS distribution checks"
