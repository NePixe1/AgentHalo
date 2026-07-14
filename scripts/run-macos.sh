#!/usr/bin/env bash
set -euo pipefail

mode="${1:-run}"
app_name="AgentHaloMac"
bundle_name="AgentHalo.app"
bundle_id="local.agenthalo.mac"

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_script="$root_dir/scripts/build-macos.sh"
app_bundle="$root_dir/outputs/AgentHalo-macOS/$bundle_name"
app_binary="$app_bundle/Contents/MacOS/$app_name"
core_resource_bundle="$app_bundle/AgentHaloMac_AgentHaloCore.bundle"
shared_locales="$root_dir/src/shared/locales"
verify_pid=""
verify_temp_dir=""

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

stop_running_app() {
  pkill -x "$app_name" >/dev/null 2>&1 || true
}

build_app() {
  bash "$build_script"
}

open_app() {
  /usr/bin/open -n "$app_bundle"
}

verify_packaged_locales() {
  for language in en zh; do
    packaged_locale="$core_resource_bundle/locales/$language.json"
    if [[ ! -r "$packaged_locale" ]]; then
      echo "Missing packaged locale: $packaged_locale" >&2
      return 1
    fi
    if ! cmp -s "$shared_locales/$language.json" "$packaged_locale"; then
      echo "Packaged locale differs from shared source: $packaged_locale" >&2
      return 1
    fi
  done
}

stop_verify_process() {
  [[ -n "$verify_pid" ]] || return 0
  if kill -0 "$verify_pid" 2>/dev/null; then
    kill -TERM "$verify_pid" 2>/dev/null || true
    for _ in {1..100}; do
      kill -0 "$verify_pid" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "$verify_pid" 2>/dev/null; then
      kill -KILL "$verify_pid" 2>/dev/null || true
    fi
  fi
  wait "$verify_pid" 2>/dev/null || true
}

cleanup_verify() {
  status=$?
  trap - EXIT INT TERM HUP
  stopped_pid="$verify_pid"
  stop_verify_process 2>/dev/null
  if [[ -n "$stopped_pid" ]] && kill -0 "$stopped_pid" 2>/dev/null; then
    echo "Failed to stop isolated packaged PID: $stopped_pid" >&2
    status=1
  fi
  if [[ -n "$verify_temp_dir" ]]; then
    rm -rf "$verify_temp_dir"
  fi
  if [[ -n "$stopped_pid" ]]; then
    echo "Cleaned isolated packaged PID $stopped_pid and temporary verification data"
  fi
  exit "$status"
}

if [[ "$mode" == "--verify" || "$mode" == "verify" ]]; then
  build_app
else
  stop_running_app
  build_app
fi

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
    verify_packaged_locales
    verify_temp_dir="$(mktemp -d /tmp/agenthalo-verify.XXXXXX)"
    trap cleanup_verify EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    verify_home="$verify_temp_dir/home"
    verify_codex_home="$verify_temp_dir/codex"
    verify_claude_config="$verify_temp_dir/claude"
    verify_tmp="$verify_temp_dir/tmp"
    verify_diagnostics="$verify_temp_dir/diagnostics"
    mkdir -p "$verify_home" "$verify_codex_home" "$verify_claude_config" \
      "$verify_tmp" "$verify_diagnostics"

    real_home="${HOME:-}"
    sandbox_profile="(version 1)
(allow default)
(deny network*)
(deny process-exec (literal \"/usr/bin/security\"))
(deny file-read* (subpath \"$real_home/.codex\"))
(deny file-read* (subpath \"$real_home/.config/codex\"))
(deny file-read* (subpath \"$real_home/.claude\"))
(deny file-read* (subpath \"$real_home/.agent-halo\"))
(deny file-read* (subpath \"$real_home/Library/Keychains\"))
(deny file-read* (subpath \"$real_home/Library/Application Support/AgentHalo\"))
(deny file-write* (subpath \"$real_home\"))"

    /usr/bin/env -i \
      HOME="$verify_home" \
      CFFIXED_USER_HOME="$verify_home" \
      CODEX_HOME="$verify_codex_home" \
      CLAUDE_CONFIG_DIR="$verify_claude_config" \
      XDG_CONFIG_HOME="$verify_temp_dir/xdg" \
      TMPDIR="$verify_tmp" \
      USER="agenthalo-verify" \
      LOGNAME="agenthalo-verify" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      LANG="en_US.UTF-8" \
      ANTHROPIC_BASE_URL="http://127.0.0.1.invalid" \
      /usr/bin/sandbox-exec -p "$sandbox_profile" "$app_binary" \
      >"$verify_diagnostics/app.log" 2>&1 &
    verify_pid=$!

    verified_command=""
    for _ in {1..100}; do
      if ! kill -0 "$verify_pid" 2>/dev/null; then
        echo "Isolated packaged app exited before readiness" >&2
        sed -n '1,120p' "$verify_diagnostics/app.log" >&2
        false
      fi
      verified_command="$(ps -ww -p "$verify_pid" -o command= 2>/dev/null || true)"
      if [[ "$verified_command" == "$app_binary" || "$verified_command" == "$app_binary "* ]]; then
        break
      fi
      sleep 0.05
    done
    if [[ "$verified_command" != "$app_binary" && "$verified_command" != "$app_binary "* ]]; then
      echo "Isolated PID $verify_pid is not the packaged binary: $verified_command" >&2
      false
    fi

    opened_executable="$(/usr/sbin/lsof -a -p "$verify_pid" -d txt -Fn 2>/dev/null \
      | sed -n 's/^n//p' | head -n 1)"
    if [[ "$opened_executable" != "$app_binary" ]]; then
      echo "Isolated PID $verify_pid executable mismatch: $opened_executable" >&2
      false
    fi

    readiness_lock="$verify_home/Library/Application Support/AgentHalo/instance.lock"
    for _ in {1..100}; do
      if ! kill -0 "$verify_pid" 2>/dev/null; then
        echo "Isolated packaged app exited during readiness" >&2
        sed -n '1,120p' "$verify_diagnostics/app.log" >&2
        false
      fi
      [[ -f "$readiness_lock" ]] && break
      sleep 0.05
    done
    test -f "$readiness_lock"

    if [[ "${AGENTHALO_VERIFY_FORCE_READINESS_FAILURE:-0}" == "1" ]]; then
      echo "Forced isolated readiness failure" >&2
      false
    fi

    diagnostics_binary="$root_dir/src/macos/.build/debug/AgentHaloDiagnostics"
    /usr/bin/env -i \
      HOME="$verify_home" \
      CFFIXED_USER_HOME="$verify_home" \
      CODEX_HOME="$verify_codex_home" \
      CLAUDE_CONFIG_DIR="$verify_claude_config" \
      XDG_CONFIG_HOME="$verify_temp_dir/xdg" \
      TMPDIR="$verify_tmp" \
      USER="agenthalo-verify" \
      LOGNAME="agenthalo-verify" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      LANG="en_US.UTF-8" \
      /usr/bin/sandbox-exec -p "$sandbox_profile" \
      "$diagnostics_binary" --snapshot "$verify_diagnostics/snapshot.txt"
    test -s "$verify_diagnostics/snapshot.txt"
    /usr/bin/grep -q '^Sessions: 0$' "$verify_diagnostics/snapshot.txt"
    sleep 1
    kill -0 "$verify_pid"

    echo "Isolation: empty inherited environment, temporary home/config, network and Keychain denied"
    echo "Verified isolated packaged PID $verify_pid: $verified_command"
    echo "Readiness: isolated instance lock + nonempty zero-session diagnostics"
    ;;
  *)
    usage
    exit 2
    ;;
esac
