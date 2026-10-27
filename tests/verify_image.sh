#!/bin/bash

# Exercises a single container of the built image. assets/entrypoint.sh and
# assets/notify.sh run inside it so the image's own busybox tools are what get
# tested, and every rendered config is checked with `keepalived --config-test`.

set -u

IMAGE="${IMAGE:-rmartin16/keepalived}"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
FAILURES=0

pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  sed 's/^/    /' "$LOG"
  FAILURES=$((FAILURES + 1))
}

# render <setup shell> [docker run args...]
# Runs the entrypoint with keepalived in config-test mode and prints the
# rendered config; keepalived's output goes to $LOG. The exit status is
# keepalived's.
render() {
  local setup="$1"
  shift
  docker run --rm "$@" --env ARGUMENTS="--config-test" "$IMAGE" sh -c "
    ${setup}
    sh /entrypoint.sh >&2
    rc=\$?
    cat \${CONFIG:-/etc/keepalived/keepalived.conf}
    exit \$rc
  " 2>"$LOG"
}

# every template variable is substituted
if out=$(render "" \
  --env STATE=BACKUP \
  --env ROUTER_ID=51 \
  --env PRIORITY=150 \
  --env UNICAST_PEERS="10.10.0.11 10.10.0.12 10.10.0.13" \
  --env VIRTUAL_IPS="10.10.0.100/24 10.10.0.101/24" \
  --env PASSWORD=s3cr3t \
  --env NOTIFY=/notify.sh
); then
  if diff -u "$TESTS_DIR/ka.conf.result" - <<<"$out" >"$LOG"; then
    pass "custom environment renders expected config"
  else
    fail "custom environment renders expected config"
  fi
else
  fail "custom environment passes config test"
fi

# the image's default environment yields a valid config
if out=$(render ""); then
  if grep -q '{{' <<<"$out"; then
    echo "$out" >"$LOG"
    fail "default environment leaves no placeholders"
  else
    pass "default environment renders a valid config"
  fi
else
  fail "default environment passes config test"
fi

# the container's own address is dropped from the peer list
if out=$(render 'export UNICAST_PEERS="10.10.0.11 $(hostname -i) 10.10.0.13"'); then
  peers=$(sed -n '/unicast_peer {/,/}/p' <<<"$out")
  if grep -q '10\.10\.0\.11' <<<"$peers" && grep -q '10\.10\.0\.13' <<<"$peers" \
    && [ "$(grep -c '^    [0-9]' <<<"$peers")" -eq 2 ]; then
    pass "own address excluded from unicast peers"
  else
    echo "$peers" >"$LOG"
    fail "own address excluded from unicast peers"
  fi
else
  fail "own address excluded from unicast peers"
fi

# an empty NOTIFY removes the notify directive
if out=$(render "" --env NOTIFY=""); then
  if grep -q 'notify' <<<"$out"; then
    echo "$out" >"$LOG"
    fail "empty NOTIFY removes notify directive"
  else
    pass "empty NOTIFY removes notify directive"
  fi
else
  fail "empty NOTIFY passes config test"
fi

# a user-supplied config without placeholders is left alone; it is mounted
# read-only so any attempted edit also fails the test
if out=$(render "" \
  --env STATE=BACKUP \
  --volume "$TESTS_DIR/ka.conf.result:/etc/keepalived/keepalived.conf:ro"
); then
  if diff -u "$TESTS_DIR/ka.conf.result" - <<<"$out" >"$LOG"; then
    pass "mounted config is not modified"
  else
    fail "mounted config is not modified"
  fi
else
  fail "mounted config passes config test"
fi

# notify.sh runs in the image and accepts only known VRRP states
for state in MASTER BACKUP FAULT; do
  if docker run --rm "$IMAGE" /notify.sh INSTANCE VI "$state" >"$LOG" 2>&1; then
    pass "notify.sh accepts $state"
  else
    fail "notify.sh accepts $state"
  fi
done
if ! docker run --rm "$IMAGE" /notify.sh INSTANCE VI BOGUS >"$LOG" 2>&1 \
  && grep -q 'Unknown state BOGUS' "$LOG"; then
  pass "notify.sh rejects unknown state"
else
  fail "notify.sh rejects unknown state"
fi

# keepalived reports the features it was built with; this guards against
# configure silently dropping one when a build dependency is missing
docker run --rm "$IMAGE" /usr/sbin/keepalived --version >"$LOG" 2>&1
for opt in NFTABLES REGEX JSON BFD SNMP_VRRP SNMP_CHECKER SNMP_RFCV2 SNMP_RFCV3; do
  if grep -qE "^Config options:.*\b${opt}\b" "$LOG"; then
    pass "keepalived built with $opt"
  else
    fail "keepalived built with $opt"
  fi
done

# the image starts as documented, with its default command and environment
CONTAINER="$(docker run --detach "$IMAGE")"
trap 'docker rm -f "$CONTAINER" >/dev/null; rm -f "$LOG"' EXIT
sleep 2
if [ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER")" = "true" ] \
  && docker exec "$CONTAINER" pidof keepalived >"$LOG" 2>&1; then
  pass "default container keeps keepalived running"
else
  docker logs "$CONTAINER" >"$LOG" 2>&1
  fail "default container keeps keepalived running"
fi
if docker exec "$CONTAINER" \
  /usr/sbin/keepalived --config-test -f /etc/keepalived/keepalived.conf >"$LOG" 2>&1; then
  pass "config rendered in place passes config test"
else
  fail "config rendered in place passes config test"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES test(s) failed"
  exit 1
fi
echo "All image tests passed."
