setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../ctl.sh"
  export DOUBLETAKE_CTL="$BATS_TEST_DIRNAME/fakebin/doubletake-ctl"
  export FAKE_DT_DIR="$BATS_TEST_TMPDIR/replies"
  export FAKE_DT_ARGS="$BATS_TEST_TMPDIR/args"
  export FAKE_SYSTEMCTL_ARGS="$BATS_TEST_TMPDIR/systemctl-args"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
  PATH="$BATS_TEST_DIRNAME/fakebin:$PATH"
  unset FAKE_SYSTEMCTL_FAIL
  mkdir -p "$FAKE_DT_DIR" "$XDG_CONFIG_HOME/doubletake"
  : >"$FAKE_DT_ARGS"
  : >"$FAKE_SYSTEMCTL_ARGS"
  touch "$FAKE_DT_DIR/enabled"
}

reply() {
  cat >"$FAKE_DT_DIR/$1.json"
}

credentials() {
  cat >"$XDG_CONFIG_HOME/doubletake/credentials.json"
}

idle_daemon() {
  echo '{"ok":true,"state":"idle","streams":[]}' | reply status
  echo '{"ok":true,"state":"idle","devices":[
    {"name":"Living Room","ip":"192.0.2.10","port":7000,"device_id":"AA:BB:CC:DD:EE:01"},
    {"name":"Office","ip":"192.0.2.11","port":7000,"device_id":"aa:bb:cc:dd:ee:02"},
    {"name":"Kitchen","ip":"192.0.2.12","port":7000,"device_id":"AA:BB:CC:DD:EE:03"},
    {"name":"Garage","ip":"192.0.2.13","port":7000}
  ]}' | reply devices
}

paired() {
  jq -c '[.devices[] | {(.name): .paired}] | add' <<<"$output"
}

@test "state reports a disabled daemon without asking it anything" {
  rm "$FAKE_DT_DIR/enabled"
  idle_daemon
  run bash "$SCRIPT" state
  [ "$status" -eq 0 ]
  [ "$output" = '{"enabled":false,"daemon":false}' ]
  [ ! -s "$FAKE_DT_ARGS" ]
}

@test "state reports an enabled daemon that does not answer" {
  run bash "$SCRIPT" state
  [ "$status" -eq 0 ]
  [ "$output" = '{"enabled":true,"daemon":false}' ]
}

@test "state marks receivers with a saved pairing as paired, matching device ids case-insensitively" {
  idle_daemon
  credentials <<'JSON'
{
  "AA:BB:CC:DD:EE:01": {"pairing_id": "p1", "ed25519_public": "x", "ed25519_seed": "y"},
  "AA:BB:CC:DD:EE:02": {"pairing_id": "p2"},
  "AA:BB:CC:DD:EE:03": {"restore_token": "only-a-screen-share-token"}
}
JSON
  run bash "$SCRIPT" state
  [ "$status" -eq 0 ]
  [ "$(jq -r .enabled <<<"$output")" = true ]
  [ "$(jq -r .daemon <<<"$output")" = true ]
  [ "$(jq -r .status.state <<<"$output")" = idle ]
  [ "$(paired)" = '{"Living Room":true,"Office":true,"Kitchen":false,"Garage":false}' ]
}

@test "state treats a missing credential file as nothing paired" {
  idle_daemon
  run bash "$SCRIPT" state
  [ "$status" -eq 0 ]
  [ "$(paired)" = '{"Living Room":false,"Office":false,"Kitchen":false,"Garage":false}' ]
}

@test "state treats an unreadable credential file as nothing paired" {
  idle_daemon
  echo 'not json' | credentials
  run bash "$SCRIPT" state
  [ "$status" -eq 0 ]
  [ "$(paired)" = '{"Living Room":false,"Office":false,"Kitchen":false,"Garage":false}' ]
}

@test "state keeps the status when the device list fails" {
  echo '{"ok":true,"state":"streaming","streams":[{"device":"Office","device_ip":"192.0.2.11","state":"streaming"}]}' | reply status
  run bash "$SCRIPT" state
  [ "$status" -eq 0 ]
  [ "$(jq -c .devices <<<"$output")" = '[]' ]
  [ "$(jq -r '.status.streams[0].state' <<<"$output")" = streaming ]
}

@test "connect starts mirroring to the receiver" {
  echo '{"ok":true,"state":"connecting","device":"192.0.2.10"}' | reply connect
  run bash "$SCRIPT" connect 192.0.2.10
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_DT_ARGS")" = "connect 192.0.2.10" ]
}

@test "connect passes on the daemon's refusal" {
  echo '{"ok":false,"state":"streaming","error":"already connected or connecting to 192.0.2.10"}' | reply connect
  run bash "$SCRIPT" connect 192.0.2.10
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = "already connected or connecting to 192.0.2.10" ]
}

@test "connect needs a target" {
  run bash "$SCRIPT" connect
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_DT_ARGS" ]
}

@test "code answers the receiver's prompt with the code from stdin" {
  echo '{"ok":true,"state":"connecting"}' | reply connect
  run bash "$SCRIPT" code 192.0.2.10 <<<"1234"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_DT_ARGS")" = "connect 192.0.2.10 1234" ]
}

@test "code keeps spaces inside a password" {
  echo '{"ok":true,"state":"connecting"}' | reply connect
  run bash "$SCRIPT" code 192.0.2.10 <<<" open sesame "
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_DT_ARGS")" = "connect 192.0.2.10  open sesame " ]
}

@test "code refuses an empty code" {
  run bash "$SCRIPT" code 192.0.2.10 </dev/null
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_DT_ARGS" ]
}

@test "code needs a target" {
  run bash "$SCRIPT" code <<<"1234"
  [ "$status" -eq 2 ]
}

@test "stop disconnects every stream" {
  echo '{"ok":true,"state":"idle"}' | reply disconnect
  run bash "$SCRIPT" stop
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_DT_ARGS")" = "disconnect" ]
}

@test "enable starts the daemon now and with every login" {
  rm "$FAKE_DT_DIR/enabled"
  run bash "$SCRIPT" enable
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  [ "$(cat "$FAKE_SYSTEMCTL_ARGS")" = "--user enable --now doubletake.service" ]
}

@test "disable stops the daemon now and keeps it off" {
  run bash "$SCRIPT" disable
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  [ "$(cat "$FAKE_SYSTEMCTL_ARGS")" = "--user disable --now doubletake.service" ]
}

@test "enable reports why systemd refused" {
  export FAKE_SYSTEMCTL_FAIL="Unit doubletake.service not found."
  run bash "$SCRIPT" enable
  [ "$status" -eq 1 ]
  [ "$(jq -r .ok <<<"$output")" = false ]
  [ "$(jq -r .error <<<"$output")" = "Unit doubletake.service not found." ]
}

@test "an unknown command prints usage" {
  run bash "$SCRIPT" mirror
  [ "$status" -eq 2 ]
  [[ "$output" == usage:* ]]
}
