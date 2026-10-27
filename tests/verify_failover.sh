#!/bin/bash

# Runs two keepalived containers as VRRP peers on a private Docker network and
# verifies that the higher priority node takes the virtual IP, that the other
# node takes it over when the master stops, and that keepalived runs the notify
# script on each transition.

set -u

IMAGE="${IMAGE:-rmartin16/keepalived}"
NAME="keepalived-failover-$$"
SUBNET_PREFIX="172.30.99"
VIP="${SUBNET_PREFIX}.100"
TIMEOUT=20
FAILURES=0

cleanup() {
  docker rm -f "${NAME}-1" "${NAME}-2" >/dev/null 2>&1
  docker network rm "$NAME" >/dev/null 2>&1
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  for node in 1 2; do
    echo "    --- ${NAME}-${node} log"
    docker logs "${NAME}-${node}" 2>&1 | grep -v '^+' | tail -n 15 | sed 's/^/    /'
  done
  FAILURES=$((FAILURES + 1))
}

# start_node <node number> <priority>
# The notify script is written inside the container so it is root owned, as
# enable_script_security requires; it runs as keepalived_script and logs each
# transition (keepalived appends the priority) to /tmp/notify.log.
start_node() {
  docker run --detach \
    --name "${NAME}-$1" \
    --network "$NAME" \
    --ip "${SUBNET_PREFIX}.1$1" \
    --cap-add NET_ADMIN \
    --env PRIORITY="$2" \
    --env UNICAST_PEERS="${SUBNET_PREFIX}.11 ${SUBNET_PREFIX}.12" \
    --env VIRTUAL_IPS="${VIP}/24" \
    --env NOTIFY=/usr/local/bin/notify-log.sh \
    "$IMAGE" sh -c '
      printf "#!/bin/sh\necho \"\$@\" >> /tmp/notify.log\n" > /usr/local/bin/notify-log.sh
      exec sh /entrypoint.sh
    ' >/dev/null
}

has_vip() {
  docker exec "${NAME}-$1" ip -4 addr show eth0 2>/dev/null | grep -q "inet ${VIP}/"
}

notified() {
  docker exec "${NAME}-$1" grep -qE "^INSTANCE VI $2( |$)" /tmp/notify.log 2>/dev/null
}

# wait_for <description> <command...>
wait_for() {
  local desc="$1"
  shift
  for _ in $(seq "$TIMEOUT"); do
    if "$@"; then
      pass "$desc"
      return 0
    fi
    sleep 1
  done
  fail "$desc"
  return 1
}

docker network create --subnet "${SUBNET_PREFIX}.0/24" "$NAME" >/dev/null || exit 1
start_node 1 150
start_node 2 100

wait_for "node 1 becomes master and holds the VIP" has_vip 1
wait_for "node 1 runs notify for MASTER" notified 1 MASTER
wait_for "node 2 runs notify for BACKUP" notified 2 BACKUP
if has_vip 2; then
  fail "node 2 does not hold the VIP while backup"
else
  pass "node 2 does not hold the VIP while backup"
fi

docker stop --time 5 "${NAME}-1" >/dev/null
wait_for "node 2 takes over the VIP after node 1 stops" has_vip 2
wait_for "node 2 runs notify for MASTER" notified 2 MASTER

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES test(s) failed"
  exit 1
fi
echo "All failover tests passed."
