#!/bin/bash

# The panel's only way into the doubletake daemon and its systemd unit.
# Every command prints a JSON answer on stdout.
#
#   ctl.sh state         whether the daemon is enabled, its status, and the discovered
#                        receivers, each marked paired or not
#   ctl.sh enable        start the daemon, now and at every login
#   ctl.sh disable       stop the daemon, now and at every login
#   ctl.sh connect IP    start mirroring to IP (the daemon pairs first if it has to)
#   ctl.sh code IP       answer IP's PIN or password prompt with the value on stdin
#   ctl.sh stop          stop every stream

set -euo pipefail

UNIT=doubletake.service

usage() {
  echo "usage: ctl.sh state | enable | disable | connect IP | code IP | stop" >&2
  exit 2
}

doubletake_ctl() {
  local bin=${DOUBLETAKE_CTL:-}
  [[ -n $bin ]] || bin=$(command -v doubletake-ctl || true)
  [[ -n $bin ]] || bin=$HOME/.local/bin/doubletake-ctl
  timeout 10 "$bin" "$@"
}

# The daemon does not report pairing, but it keeps one entry per receiver
# device id in its credential file, and only a completed pairing writes a
# pairing_id there (a remembered screen-share token alone does not).
credentials() {
  local file=${XDG_CONFIG_HOME:-$HOME/.config}/doubletake/credentials.json
  if [[ -r $file ]] && jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
    cat "$file"
  else
    echo '{}'
  fi
}

# Asks for a direction rather than a toggle, so a second click that lands
# before systemd is done cannot undo the first.
set_service() {
  local error
  if error=$(systemctl --user "$1" --now "$UNIT" 2>&1 >/dev/null); then
    echo '{"ok":true}'
  else
    jq -cn --arg error "$error" '{ok: false, error: $error}'
    return 1
  fi
}

state() {
  local status devices
  # Off means off: not even the daemon's socket gets probed.
  if ! systemctl --user is-enabled --quiet "$UNIT" 2>/dev/null; then
    echo '{"enabled":false,"daemon":false}'
    return
  fi
  if ! status=$(doubletake_ctl status 2>/dev/null); then
    echo '{"enabled":true,"daemon":false}'
    return
  fi
  devices=$(doubletake_ctl devices 2>/dev/null) || devices='{}'
  jq -cn --argjson status "$status" --argjson devices "$devices" --argjson creds "$(credentials)" '
    ($creds | with_entries(.key |= ascii_upcase)) as $paired
    | {
        enabled: true,
        daemon: true,
        status: $status,
        devices: [($devices.devices // [])[] | . + {
          paired: ((.device_id // "") as $id | $id != "" and ($paired[$id | ascii_upcase].pairing_id // "") != "")
        }]
      }'
}

require_target() {
  [[ -n ${1:-} ]] || usage
}

case "${1:-}" in
state)
  state
  ;;
enable | disable)
  set_service "$1"
  ;;
connect)
  require_target "${2:-}"
  doubletake_ctl connect "$2"
  ;;
code)
  require_target "${2:-}"
  IFS= read -r code || true
  [[ -n $code ]] || {
    echo "ctl.sh: no code on stdin" >&2
    exit 2
  }
  # doubletake-ctl only takes the code as an argument, so it is visible in
  # the process list for the moment this call takes.
  doubletake_ctl connect "$2" "$code"
  ;;
stop)
  doubletake_ctl disconnect
  ;;
*)
  usage
  ;;
esac
