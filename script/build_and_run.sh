#!/usr/bin/env bash
set -euo pipefail

mode="${1:-run}"
app_name="AgentHaloMac"
bundle_name="AgentHalo.app"
bundle_id="local.agenthalo.mac"

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_script="$root_dir/mac/scripts/build-macos.sh"
app_bundle="$root_dir/outputs/AgentHalo-macOS/$bundle_name"
app_binary="$app_bundle/Contents/MacOS/$app_name"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

stop_running_app() {
  pkill -x "$app_name" >/dev/null 2>&1 || true
}

build_app() {
  "$build_script"
}

open_app() {
  /usr/bin/open -n "$app_bundle"
}

stop_running_app
build_app

case "$mode" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$app_binary"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$app_name\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$bundle_id\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$app_name" >/dev/null
    diag_dir="$root_dir/outputs/AgentHalo-macOS/diagnostics"
    mkdir -p "$diag_dir"
    (cd "$root_dir/mac" && swift run AgentHaloDiagnostics --snapshot "$diag_dir/snapshot.txt")
    test -s "$diag_dir/snapshot.txt"
    echo "Verified $app_name is running from $app_bundle"
    ;;
  *)
    usage
    exit 2
    ;;
esac
