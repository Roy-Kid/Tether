#!/usr/bin/env bash
# Isolated loopback OpenSSH fixture. Trust only its generated fingerprint.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v tmux >/dev/null
fixture=$(mktemp -d "${TMPDIR:-/tmp}/tether-native-test.XXXXXX")
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$fixture/client"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
cat > "$fixture/sshd_config" <<CONFIG
Port $port
ListenAddress 127.0.0.1
HostKey $fixture/host
PidFile $fixture/pid
AuthorizedKeysFile $fixture/client.pub
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes yes
AllowUsers $(id -un)
SetEnv PATH=$(dirname "$(command -v tmux)"):/usr/bin:/bin:/usr/sbin:/sbin
CONFIG
/usr/sbin/sshd -D -e -f "$fixture/sshd_config" > "$fixture/log" 2>&1 &
server_pid=$!
python3 - "$port" <<'PY'
import socket,sys,time
for _ in range(100):
    try:
        with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=.1): break
    except OSError: time.sleep(.05)
else: raise SystemExit('Temporary sshd did not start')
PY
export TETHER_TEST_SSH_HOST=127.0.0.1
export TETHER_TEST_SSH_PORT="$port"
export TETHER_TEST_SSH_USER="$(id -un)"
export TETHER_TEST_SSH_KEY="$fixture/client"
export TETHER_TEST_SSH_FINGERPRINT="$(ssh-keygen -lf "$fixture/host.pub" | awk '{print $2}')"
swift test --package-path swift
