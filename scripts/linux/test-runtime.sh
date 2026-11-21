#!/usr/bin/env bash
set -euo pipefail

# Run after installing the package in Linux CI. Keep routes and the journal
# in private namespaces, and reap every test process when the namespace exits.
if [[ "${1:-}" != '--isolated' ]]; then
  exec unshare --mount --net --pid --fork --mount-proc bash "$0" --isolated
fi

mount -t tmpfs tmpfs /run/nekoproxy
if [[ -d /run/systemd/resolve ]]; then
  mount -t tmpfs tmpfs /run/systemd/resolve
fi
systemd-tmpfiles --create /usr/lib/tmpfiles.d/nekoproxy.conf
ip link set lo up
ip link add uplink type dummy
ip addr add 192.0.2.1/24 dev uplink
ip link set uplink up
ip route add default via 192.0.2.2 dev uplink
ip -6 addr add 2001:db8:1::1/64 dev uplink nodad
ip -6 route add default via 2001:db8:1::2 dev uplink

scratch=$(mktemp -d /run/nekoproxy/test.XXXXXX)
chown nobody:nogroup "$scratch"
chmod 0700 "$scratch"
cd "$scratch"
normal=/usr/lib/nekoproxy/nekoproxy-worker
tun=/usr/lib/nekoproxy/nekoproxy-tun-worker
tun_gid=$(getent group nekoproxy-tun | cut -d: -f3)
regular=(setpriv --reuid=nobody --regid=nogroup --clear-groups)
authorized=(setpriv --reuid=nobody --regid=nogroup --groups="$tun_gid")

wait_ready() {
  for _ in {1..100}; do
    if [[ -f "$scratch/$1.error" ]]; then
      cat "$scratch/$1.error"
      return 1
    fi
    if [[ -s "$scratch/$1" ]]; then return; fi
    sleep 0.1
  done
  echo "Timed out waiting for $1" >&2
  return 1
}

start_tun() {
  local name=$1
  "${authorized[@]}" "$tun" -supervise-tun -mode tun -config - -ready "$scratch/$name.ready" \
    < "$scratch/tun.json" > "$scratch/$name.log" 2>&1 &
  supervisor=$!
  wait_ready "$name.ready" || { cat "$scratch/$name.log"; exit 1; }
}

stop_tun() {
  python3 - "$scratch/$1.ready" <<'PY'
import json
import socket
import sys

with open(sys.argv[1]) as ready_file:
    ready = json.load(ready_file)
with socket.create_connection(("127.0.0.1", ready["port"]), timeout=8) as sock:
    with sock.makefile("rwb") as peer:
        peer.write(json.dumps({"token": ready["token"]}).encode() + b"\n")
        peer.flush()
        assert json.loads(peer.readline())["ok"]
        peer.write(b'{"id":1,"cmd":"shutdown"}\n')
        peer.flush()
        peer.readline()
PY
}

assert_tun_clean() {
  test ! -e /run/nekoproxy/tun/session.json
  if ip link show dev nekoproxy0 2>/dev/null || {
       ip rule show
       ip -6 rule show
     } | grep -E '^197(7[1-9]|8[01]):'; then
    echo 'TUN left behind interface or route rules' >&2
    exit 1
  fi
}

cat > "$scratch/normal.json" <<'EOF'
{"inbounds":[{"type":"mixed","tag":"local","listen":"127.0.0.1","listen_port":20880}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
EOF
cat > "$scratch/tun.json" <<'EOF'
{
  "inbounds": [{
    "type": "tun", "tag": "tun-in", "interface_name": "nekoproxy0",
    "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
    "auto_route": true, "strict_route": true, "auto_redirect": false,
    "stack": "mixed", "dns_mode": "hijack",
    "iproute2_table_index": 20771, "iproute2_rule_index": 19771
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "dns": {
    "servers": [{
      "type": "hosts", "tag": "answers",
      "predefined": {"fixture.test": ["192.0.2.99", "2001:db8::99"]}
    }],
    "final": "answers"
  },
  "route": {
    "final": "direct",
    "auto_detect_interface": true,
    "rules": [
      {"port": [53], "action": "hijack-dns"},
      {
        "ip_cidr": ["198.51.100.2/32", "2001:db8:2::2/128"],
        "action": "route-options", "override_address": "127.0.0.1", "override_port": 18080
      }
    ]
  }
}
EOF
printf 'NekoProxy\n' > "$scratch/index.html"
python3 -m http.server --bind 127.0.0.1 --directory "$scratch" 18080 > "$scratch/http.log" 2>&1 &
"${regular[@]}" "$normal" -mode normal -config - -ready "$scratch/normal.ready" \
  < "$scratch/normal.json" > "$scratch/normal.log" 2>&1 &
worker=$!
wait_ready normal.ready
test "$(stat -c %a "$scratch/normal.ready")" = 600
common_curl=(--fail --silent --show-error --noproxy '' --retry 3 --retry-connrefused --max-time 3)
curl --fail --silent --noproxy '*' --retry 3 --retry-connrefused --max-time 3 http://127.0.0.1:18080 >/dev/null
test "$(curl "${common_curl[@]}" -x http://127.0.0.1:20880 http://127.0.0.1:18080)" = NekoProxy
test "$(curl "${common_curl[@]}" --socks5-hostname 127.0.0.1:20880 http://127.0.0.1:18080)" = NekoProxy
if "${regular[@]}" "$normal" -mode normal -config - -ready "$scratch/port.ready" < "$scratch/normal.json"; then
  echo 'Expected a port conflict' >&2
  exit 1
fi
grep -q 'address already in use' "$scratch/port.ready.error"
kill -TERM "$worker"
wait "$worker"

if "${regular[@]}" "$tun" -supervise-tun -mode tun -config - -ready "$scratch/denied.ready" < "$scratch/tun.json"; then
  echo 'Unauthorized user started TUN' >&2
  exit 1
fi
ip rule add pref 19771 to 203.0.113.0/24 table main
if "${authorized[@]}" "$tun" -supervise-tun -mode tun -config - -ready "$scratch/occupied.ready" < "$scratch/tun.json"; then
  echo 'Expected a policy-rule conflict' >&2
  exit 1
fi
test -s "$scratch/occupied.ready.error"
ip rule show | grep -q '19771:.*203.0.113.0/24'
ip rule del pref 19771 to 203.0.113.0/24 table main

start_tun tun
ip addr show dev nekoproxy0 | grep -q '172.19.0.1/30'
ip -6 addr show dev nekoproxy0 | grep -q 'fdfe:dcba:9876::1/126'
ip route get 192.0.2.99 | grep -q 'dev uplink'
test "$(curl --fail --silent --show-error --noproxy '*' --max-time 3 http://198.51.100.2:18080)" = NekoProxy
test "$(curl --fail --silent --show-error --noproxy '*' --max-time 3 'http://[2001:db8:2::2]:18080')" = NekoProxy
python3 - <<'PY'
import socket
import struct

for family, resolver, record_type, address in [
    (socket.AF_INET, "172.19.0.2", 1, "192.0.2.99"),
    (socket.AF_INET6, "fdfe:dcba:9876::2", 28, "2001:db8::99"),
]:
    query = struct.pack("!6H", 0x137a, 0x100, 1, 0, 0, 0)
    query += b"\x07fixture\x04test\x00" + struct.pack("!HH", record_type, 1)
    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.settimeout(3)
        sock.connect((resolver, 53))
        sock.send(query)
        response = sock.recv(1024)
    assert response[:2] == b"\x13\x7a"
    assert response.endswith(socket.inet_pton(family, address)), response.hex()
PY
core=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$scratch/tun.ready")
test "$core" != "$supervisor"
grep -q '^CapEff:[[:space:]]*0000000000001000$' "/proc/$core/status"
kill -KILL "$core"
if wait "$supervisor"; then
  echo 'Supervisor did not report the worker crash' >&2
  exit 1
fi
assert_tun_clean

# Insert a rule only after TUN is ready. The normal control-channel shutdown
# must bypass the core's range-wide delete and leave the other owner's rule.
start_tun live-conflict
ip rule add pref 19771 to 203.0.113.0/24 table main
stop_tun live-conflict
if wait "$supervisor"; then
  echo 'Supervisor did not report the shutdown conflict' >&2
  exit 1
fi
test -s "$scratch/live-conflict.ready.error"
ip rule show | grep -q '19771:.*203.0.113.0/24'
if ip rule show | grep -Eq '^1977[2-9]:'; then
  echo 'Supervisor kept rules in uncontested slots' >&2
  exit 1
fi
ip rule del pref 19771 to 203.0.113.0/24 table main
start_tun recovered
stop_tun recovered
wait "$supervisor"
assert_tun_clean

start_tun orphaned
kill -KILL "$supervisor"
if wait "$supervisor"; then
  echo 'Expected the supervisor to be killed' >&2
  exit 1
fi
for _ in {1..100}; do
  if flock -n /run/nekoproxy/tun.lock true; then break; fi
  sleep 0.1
done
flock -n /run/nekoproxy/tun.lock true
test -s /run/nekoproxy/tun/session.json
start_tun recovered-orphan
stop_tun recovered-orphan
wait "$supervisor"
assert_tun_clean

echo 'HTTP/SOCKS5, IPv4/IPv6 TUN and DNS, permissions, conflicts and recovery passed.'
