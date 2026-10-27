#!/bin/bash

# Exercises a single container of the built image. assets/entrypoint.sh and
# assets/notify.sh run inside it so the image's own busybox tools are what get
# tested, and every rendered config is checked with `keepalived --config-test`.

set -u

IMAGE="${IMAGE:-rmartin16/keepalived}"
# set to run an image built for another architecture, e.g. linux/arm64
PLATFORM="${PLATFORM:-}"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
FAILURES=0

run_image() {
  docker run --pull never ${PLATFORM:+--platform "$PLATFORM"} "$@"
}

pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  sed 's/^/    /' "$LOG"
  FAILURES=$((FAILURES + 1))
}

# config_test <config>, defined inside the container: validates a config with
# keepalived's own config test. keepalived 2.2.7's config test kills itself
# with SIGTERM whenever a notify script is configured, although the daemon runs
# notify scripts fine (see tests/verify_failover.sh), so on that version the
# notify directive is left out of the test.
VERSION_OUTPUT="$(run_image --rm "$IMAGE" /usr/sbin/keepalived --version 2>&1)"
KEEPALIVED_VERSION="$(sed -n 's/^Keepalived v\([0-9.]*\).*/\1/p' <<<"$VERSION_OUTPUT")"
if [ "$KEEPALIVED_VERSION" = "2.2.7" ]; then
  CONFIG_TEST_FN='config_test() {
    grep -v notify "$1" >/tmp/config-test.conf &&
      /usr/sbin/keepalived --config-test -f /tmp/config-test.conf
  }'
else
  CONFIG_TEST_FN='config_test() { /usr/sbin/keepalived --config-test -f "$1"; }'
fi

# render <setup shell> [docker run args...]
# Runs the entrypoint, prints the rendered config and then validates it with
# config_test, whose output goes to $LOG (as does the entrypoint's, if it
# fails). The exit status is the entrypoint's if it fails, otherwise the config
# test's.
render() {
  local setup="$1"
  shift
  run_image --rm "$@" "$IMAGE" sh -c "
    ${CONFIG_TEST_FN}
    ${setup}
    ARGUMENTS=--version sh /entrypoint.sh >/tmp/entrypoint.log 2>&1 ||
      { rc=\$?; cat /tmp/entrypoint.log >&2; exit \$rc; }
    config=\${CONFIG:-/etc/keepalived/keepalived.conf}
    cat \"\$config\"
    config_test \"\$config\" >&2
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
if out=$(render '
  own=$(hostname -i)
  [ -n "$own" ] || { echo "hostname -i returned no address" >&2; exit 1; }
  export UNICAST_PEERS="10.10.0.11 $own 10.10.0.13"
'); then
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
  if run_image --rm "$IMAGE" /notify.sh INSTANCE VI "$state" >"$LOG" 2>&1; then
    pass "notify.sh accepts $state"
  else
    fail "notify.sh accepts $state"
  fi
done
if ! run_image --rm "$IMAGE" /notify.sh INSTANCE VI BOGUS >"$LOG" 2>&1 \
  && grep -q 'Unknown state BOGUS' "$LOG"; then
  pass "notify.sh rejects unknown state"
else
  fail "notify.sh rejects unknown state"
fi

# enable_script_security refuses scripts that a non-root user could change, so
# the files the image ships must be owned by root
if out=$(run_image --rm "$IMAGE" stat -c '%U:%G %a %n' \
  /entrypoint.sh /notify.sh /etc/keepalived/keepalived.conf /usr/sbin/keepalived \
  2>&1); then
  echo "$out" >"$LOG"
  if [ "$(grep -vc '^root:root ' <<<"$out")" -eq 0 ] \
    && grep -q '^root:root 755 /usr/sbin/keepalived$' <<<"$out"; then
    pass "image files are owned by root"
  else
    fail "image files are owned by root"
  fi
else
  echo "$out" >"$LOG"
  fail "image files are owned by root"
fi

# keepalived reports the features it was built with; this guards against
# configure silently dropping one when a build dependency is missing
echo "$VERSION_OUTPUT" >"$LOG"
for opt in NFTABLES REGEX JSON BFD SNMP_VRRP SNMP_CHECKER SNMP_RFCV2 SNMP_RFCV3; do
  if grep -qE "^Config options:.*\b${opt}\b" "$LOG"; then
    pass "keepalived built with $opt"
  else
    fail "keepalived built with $opt"
  fi
done

# the image starts as documented, with its default command and environment;
# with no peers answering it becomes master and adds the default VIP. Under
# QEMU user-mode emulation keepalived cannot set the socket options VRRP needs
# (IP_MULTICAST_ALL, IP_FREEBIND) and enters FAULT instead, so there the test
# only checks that keepalived starts and stays up.
case "$(uname -m):$(docker image inspect --format '{{.Architecture}}' "$IMAGE")" in
  x86_64:amd64 | x86_64:386 | aarch64:arm64 | aarch64:arm) EMULATED="" ;;
  *) EMULATED=1 ;;
esac
CONTAINER="$(run_image --detach --cap-add NET_ADMIN "$IMAGE")"
trap 'docker rm -f "$CONTAINER" >/dev/null; rm -f "$LOG"' EXIT
# emulated architectures start slowly, so wait for keepalived to enter its
# first state before checking that it stays up
for _ in $(seq 30); do
  docker logs "$CONTAINER" 2>&1 | grep -qE 'Entering (MASTER|BACKUP|FAULT) STATE' && break
  sleep 1
done
sleep 2
docker logs "$CONTAINER" >"$LOG" 2>&1
if [ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER")" = "true" ] \
  && docker exec "$CONTAINER" pidof keepalived >/dev/null 2>&1; then
  pass "default container keeps keepalived running"
else
  fail "default container keeps keepalived running"
fi
if [ -n "$EMULATED" ]; then
  echo "SKIP: default container becomes master and holds the default VIP (emulated)"
else
  # with no peers it becomes master about 3 advert intervals after BACKUP
  for _ in $(seq 10); do
    grep -q 'Entering MASTER STATE' "$LOG" && break
    sleep 1
    docker logs "$CONTAINER" >"$LOG" 2>&1
  done
  if grep -q 'Entering MASTER STATE' "$LOG"; then
    pass "default container becomes master"
  else
    fail "default container becomes master"
  fi
  if docker exec "$CONTAINER" ip -4 addr show eth0 2>"$LOG" \
    | grep -q 'inet 192\.168\.2\.100/24'; then
    pass "default container holds the default VIP"
  else
    docker exec "$CONTAINER" ip -4 addr show eth0 >>"$LOG" 2>&1
    fail "default container holds the default VIP"
  fi
fi
if docker exec "$CONTAINER" sh -c "
  ${CONFIG_TEST_FN}
  config_test /etc/keepalived/keepalived.conf
" >"$LOG" 2>&1; then
  pass "config rendered in place passes config test"
else
  fail "config rendered in place passes config test"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES test(s) failed"
  exit 1
fi
echo "All image tests passed."
