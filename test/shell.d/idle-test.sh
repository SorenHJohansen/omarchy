#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const idle = requireFromRoot('shell/plugins/services/idle/IdleModel.js')

assertEqual(idle.secondsFromConfig('42.9', 10), 42, 'idle floors configured seconds')
assertEqual(idle.secondsFromConfig('-1', 10), 10, 'idle rejects negative seconds')
assertEqual(idle.secondsFromConfig('nope', 10), 10, 'idle rejects invalid seconds')

assertDeepEqual(idle.eventParts({ data: 'a,b,c' }, 2), ['a', 'b', 'c'], 'idle parses raw event data')
assertDeepEqual(
  idle.eventParts({ parse: function(count) { return ['parsed', count] } }, 4),
  ['parsed', 4],
  'idle prefers event parser when available'
)

assertDeepEqual(
  idle.screensaverWindowsAfter({ a: true }, 'b', true),
  { windows: { a: true, b: true }, count: 2 },
  'idle adds visible screensaver windows'
)
assertDeepEqual(
  idle.screensaverWindowsAfter({ a: true, b: true }, 'a', false),
  { windows: { b: true }, count: 1 },
  'idle removes closed screensaver windows'
)
assertDeepEqual(
  idle.screensaverWindowsAfter({ a: true }, '', false),
  { windows: { a: true }, count: 1 },
  'idle leaves screensaver windows unchanged without an address'
)
JS

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

test_home="$test_tmp/home"
mkdir -p "$test_home"

HOME="$test_home" "$ROOT/bin/omarchy-toggle-idle" stay-awake >/dev/null
[[ -f $test_home/.local/state/omarchy/indicators/stay-awake ]] || fail "Stay Awake toggle persists enabled state"

HOME="$test_home" "$ROOT/bin/omarchy-toggle-idle" allow-idle >/dev/null
[[ ! -f $test_home/.local/state/omarchy/indicators/stay-awake ]] || fail "Stay Awake toggle persists disabled state"

if rg -q 'omarchy-shell' "$ROOT/bin/omarchy-toggle-idle"; then
  fail "Stay Awake toggle avoids reentrant shell IPC"
fi

service_qml="$ROOT/shell/plugins/services/idle/Service.qml"

rg -q 'IdleInhibitor' "$service_qml" || fail "Stay Awake registers a Wayland idle inhibitor"
rg -q 'enabled: *root\.stayAwake' "$service_qml" || fail "the Wayland idle inhibitor follows Stay Awake"
rg -q '"--what=idle"' "$service_qml" || fail "Stay Awake holds a logind idle inhibitor"
if rg -q -- '--what=[^"]*sleep' "$service_qml"; then
  fail "Stay Awake does not block suspend"
fi

pass "Stay Awake persists state, keeps the toggle shell-IPC-free, and publishes Wayland and logind idle inhibitors"

# Runtime coverage: with a compositor, start a real shell from this tree and
# drive the actual omarchy-toggle-idle path, then assert the systemd inhibitor
# is acquired and released. Everything is polled: the state-file watcher, the
# QML reconcile, and the systemd-inhibit process are all asynchronous.
require_compositor "idle inhibitor runtime test"

if ! command -v quickshell >/dev/null 2>&1; then
  skip "quickshell not installed; skipping idle inhibitor runtime test"
  exit 0
fi

require_command systemd-inhibit
require_command jq

runtime_tmp=$(mktemp -d)
test_root="$runtime_tmp/omarchy"
runtime_home="$runtime_tmp/home"
stub_bin="$runtime_tmp/bin"
qs_log="$runtime_tmp/quickshell.log"
mkdir -p "$test_root" "$runtime_home" "$stub_bin"
cp -a "$ROOT/shell" "$test_root/shell"
ln -s "$ROOT/config" "$test_root/config"
ln -s "$ROOT/bin" "$test_root/bin"

QS_PID=""

cleanup_runtime() {
  if [[ -n $QS_PID ]] && kill -0 "$QS_PID" 2>/dev/null; then
    kill "$QS_PID" 2>/dev/null || true
    wait "$QS_PID" 2>/dev/null || true
  fi
  rm -f "$(shell_ipc_socket "$test_root")"
  rm -rf "$runtime_tmp" "$test_tmp"
  return 0
}
trap cleanup_runtime EXIT

OMARCHY_PATH="$test_root" \
HOME="$runtime_home" \
XDG_CONFIG_HOME="$runtime_home/.config" \
XDG_CACHE_HOME="$runtime_home/.cache" \
XDG_STATE_HOME="$runtime_home/.local/state" \
PATH="$stub_bin:$ROOT/bin:$PATH" \
  quickshell -p "$test_root/shell" --no-color >"$qs_log" 2>&1 &
QS_PID=$!

shell_ipc() {
  OMARCHY_PATH="$test_root" "$ROOT/bin/omarchy-shell" "$@"
}

fail_with_shell_log() {
  sed -n '1,240p' "$qs_log" >&2
  fail "$1"
}

poll_until() {
  local description="$1" attempts=0

  shift
  until "$@"; do
    if (( ++attempts >= 100 )); then
      fail_with_shell_log "$description"
    fi
    sleep 0.1
  done
}

shell_ready() {
  kill -0 "$QS_PID" 2>/dev/null && shell_ipc -q idle status >/dev/null 2>&1
}

for _ in {1..80}; do
  shell_ready && break
  kill -0 "$QS_PID" 2>/dev/null || fail_with_shell_log "test shell exited before idle IPC was available"
  sleep 0.1
done
shell_ready || fail_with_shell_log "test shell did not expose idle IPC"

# Count only this feature's inhibitor. A shell already running in the session
# can hold one too, so assert against a baseline instead of an absolute.
inhibitor_count() {
  local count

  count=$(systemd-inhibit --list 2>/dev/null | grep -c 'omarchy-shell.*idle.*Stay awake is enabled' || true)
  printf '%s' "${count:-0}"
}

baseline=$(inhibitor_count)

inhibitor_acquired() { (( $(inhibitor_count) > baseline )); }
inhibitor_released() { (( $(inhibitor_count) <= baseline )); }

HOME="$runtime_home" "$ROOT/bin/omarchy-toggle-idle" stay-awake >/dev/null
poll_until "enabling Stay Awake acquires a systemd idle inhibitor" inhibitor_acquired
pass "enabling Stay Awake acquires a systemd idle inhibitor"

if command -v hyprctl >/dev/null 2>&1 && hyprctl layers -j >/dev/null 2>&1; then
  layer_present() {
    hyprctl layers -j 2>/dev/null |
      jq -e 'any(.. | objects | select(.namespace? == "omarchy-stay-awake"))' >/dev/null 2>&1
  }

  poll_until "the Wayland idle inhibitor surface is mapped while Stay Awake is on" layer_present
  pass "the Wayland idle inhibitor surface is mapped while Stay Awake is on"
fi

HOME="$runtime_home" "$ROOT/bin/omarchy-toggle-idle" allow-idle >/dev/null
poll_until "disabling Stay Awake releases the systemd idle inhibitor" inhibitor_released
pass "disabling Stay Awake releases the systemd idle inhibitor"
