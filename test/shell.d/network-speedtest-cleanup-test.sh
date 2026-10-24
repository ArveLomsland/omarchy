#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

workdir=$(mktemp -d)
cleanup_test() {
  for pid in ${worker_pids:-}; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  if [[ -n ${test_pid:-} ]]; then
    kill -KILL "$test_pid" 2>/dev/null || true
    wait "$test_pid" 2>/dev/null || true
  fi
  rm -rf "$workdir"
}
trap cleanup_test EXIT
mkdir -p "$workdir/bin"
iface=$(basename "$(readlink -f /sys/class/net/* | head -1)")
[[ -n $iface ]] || fail "a network interface is available for the test"
cat >"$workdir/bin/ip" <<EOF
#!/bin/bash
echo '1.1.1.1 dev $iface'
EOF
cat >"$workdir/bin/omarchy-cmd-present" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"$workdir/bin/jq" <<'EOF'
#!/bin/bash
echo 'https://speedtest.invalid/test'
EOF
cat >"$workdir/bin/curl" <<'EOF'
#!/bin/bash
if [[ $* == *'api.fast.com'* ]]; then
  echo '{}'
else
  echo "$BASHPID" >>"$WORKER_LOG"
  exec sleep 60
fi
EOF
cat >"$workdir/bin/dd" <<'EOF'
#!/bin/bash
echo "$BASHPID" >>"$WORKER_LOG"
exec sleep 60
EOF
chmod +x "$workdir/bin/"*
export WORKER_LOG="$workdir/workers"

for direction in down up; do
  for signal in TERM INT; do
    : >"$WORKER_LOG"
    PATH="$workdir/bin:$PATH" env --default-signal=INT "$ROOT/bin/omarchy-network-speedtest" "$direction" >"$workdir/output" 2>&1 &
    test_pid=$!
    for _ in {1..100}; do
      [[ -s $WORKER_LOG ]] && break
      sleep 0.05
    done
    [[ -s $WORKER_LOG ]] || fail "workers started before $signal ($direction)"
    worker_pids=$(cat "$WORKER_LOG")
    kill -s "$signal" "$test_pid" || fail "$signal reaches speedtest ($direction)"
    exited=false
    for _ in {1..50}; do
      if ! kill -0 "$test_pid" 2>/dev/null; then
        exited=true
        break
      fi
      state=$(ps -o stat= -p "$test_pid" 2>/dev/null || true)
      if [[ $state == Z* || -z $state ]]; then
        exited=true
        break
      fi
      sleep 0.1
    done
    if [[ $exited != true ]]; then
      fail "$signal exits speedtest within 5 seconds ($direction)" "pid $test_pid is still alive"
    fi
    wait "$test_pid" 2>/dev/null || true
    test_pid=
    for pid in $worker_pids; do
      for _ in {1..50}; do
        state=$(ps -o stat= -p "$pid" 2>/dev/null || true)
        [[ -z $state || $state == Z* ]] && break
        sleep 0.05
      done
      state=$(ps -o stat= -p "$pid" 2>/dev/null || true)
      [[ -z $state || $state == Z* ]] || fail "$signal leaves no live worker ($direction)" "pid $pid state $state"
    done
  done
done

pass "SIGTERM and SIGINT clean up speedtest curl/dd workers for down and up"
