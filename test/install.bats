setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../bin/install"
  export HOME="$BATS_TEST_TMPDIR/home"
  export FAKE_DT_DIR="$BATS_TEST_TMPDIR/state"
  export FAKE_SYSTEMCTL_ARGS="$BATS_TEST_TMPDIR/systemctl-args"
  export FAKE_OMARCHY_ARGS="$BATS_TEST_TMPDIR/omarchy-args"
  unset XDG_CONFIG_HOME FAKE_SYSTEMCTL_FAIL
  UNIT="$HOME/.config/systemd/user/doubletake.service"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$HOME" "$FAKE_DT_DIR" "$STUBS"
  : >"$FAKE_SYSTEMCTL_ARGS"
  : >"$FAKE_OMARCHY_ARGS"

  stub omarchy-plugin-validate 'exit 0'
  stub omarchy-shell 'exit 0'
  stub omarchy-plugin-list "echo '[{\"id\":\"renuo.doubletake\",\"enabled\":true}]'"
  stub omarchy 'echo "$*" >>"$FAKE_OMARCHY_ARGS"; [[ $* == "pkg aur add doubletake" ]] && touch "$FAKE_DT_DIR/packaged"; exit 0'
  stub pacman '[[ $* == "-Q doubletake" && -f $FAKE_DT_DIR/packaged ]]'
  stub doubletake 'exit 0'
  PATH="$STUBS:$BATS_TEST_DIRNAME/fakebin:$PATH"
}

stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

packaged() {
  touch "$FAKE_DT_DIR/packaged"
}

hand_built_binary() {
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/bash\n' >"$HOME/.local/bin/doubletake"
  chmod +x "$HOME/.local/bin/doubletake"
}

unit_written_by_earlier_install() {
  mkdir -p "$(dirname "$UNIT")"
  cat >"$UNIT" <<'UNIT'
[Unit]
Description=doubletake AirPlay mirroring daemon

[Service]
ExecStart=/home/someone/.local/bin/doubletake -daemonize
UNIT
}

@test "install leaves the daemon's unit to the doubletake package" {
  packaged
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$UNIT" ]
  [ -f "$HOME/.config/omarchy/plugins/renuo.doubletake/manifest.json" ]
}

@test "install gets doubletake from the AUR even when a hand-built binary is around" {
  hand_built_binary
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'pkg aur add doubletake' "$FAKE_OMARCHY_ARGS"
}

@test "install does not reinstall a packaged doubletake" {
  packaged
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'pkg aur add' "$FAKE_OMARCHY_ARGS"
}

@test "install removes the unit an earlier install wrote and keeps the daemon enabled" {
  packaged
  unit_written_by_earlier_install
  touch "$FAKE_DT_DIR/enabled"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$UNIT" ]
  grep -qx -- '--user enable doubletake.service' "$FAKE_SYSTEMCTL_ARGS"
  [ -f "$FAKE_DT_DIR/enabled" ]
}

@test "install removes the unit an earlier install wrote and leaves a disabled daemon off" {
  packaged
  unit_written_by_earlier_install
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$UNIT" ]
  [ ! -f "$FAKE_DT_DIR/enabled" ]
}

@test "install keeps a doubletake unit it did not write" {
  packaged
  mkdir -p "$(dirname "$UNIT")"
  printf '[Unit]\nDescription=my own doubletake\n' >"$UNIT"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'my own doubletake' "$UNIT"
}

@test "install fails when the AUR install does not produce the package" {
  stub omarchy 'exit 0'
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"doubletake is not installed"* ]]
}
