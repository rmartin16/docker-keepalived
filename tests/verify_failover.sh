#!/bin/bash

# Runs two keepalived containers as VRRP peers on a private Docker network and
# verifies that the first node takes the virtual IP, that the second node stays
# backup until the master stops and then takes it over, and that keepalived
# runs the notify script on each transition.

set -u

IMAGE="${IMAGE:-rmartin16/keepalived}"
NAME="keepalived-failover-$$"
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
  docker run --pull never --detach \
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

# A random /24 so the network does not collide with others on the host or with
# a concurrent run; try another if Docker reports an overlap.
for _ in $(seq 10); do
  SUBNET_PREFIX="10.$((RANDOM % 256)).$((RANDOM % 256))"
  docker network create --subnet "${SUBNET_PREFIX}.0/24" "$NAME" >/dev/null 2>&1 && break
  SUBNET_PREFIX=""
done
if [ -z "$SUBNET_PREFIX" ]; then
  echo "FAIL: could not create a Docker network for the test"
  exit 1
fi
VIP="${SUBNET_PREFIX}.100"

# nopreempt with both nodes in BACKUP means whichever node's master-down timer
# expires first wins the first election, so node 2 starts only once node 1 is
# master.
start_node 1 150 || { echo "FAIL: could not start node 1"; exit 1; }

wait_for "node 1 becomes master and holds the VIP" has_vip 1 || exit 1
wait_for "node 1 runs notify for MASTER" notified 1 MASTER
start_node 2 100 || { echo "FAIL: could not start node 2"; exit 1; }
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
