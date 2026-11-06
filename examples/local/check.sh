#!/usr/bin/env bash
# Uses what the circuit set up on the lab router, from outside it: logs in
# as the new user with its key and its password, reads the router's name over
# SNMPv3, sends traffic across both VLANs from the client container, and
# makes sure the services it turned off are off. Needs snmpget (the snmp
# package on Debian and Ubuntu).
set -euo pipefail
cd "$(dirname "$0")"
val() { sed -n "s/^$1 *= \"\(.*\)\"$/\1/p" lab.auto.tfvars; }
ip=$(val host)
client=clab-${LAB_NAME:-routeros}-c1
# `! cmd` doesn't stop a set -e script, so a check that must fail goes through this.
refused() { if "$@" >/dev/null 2>&1; then echo "This worked and shouldn't have: $*" >&2; exit 1; fi; }

echo "ops logs in over SSH with its key"
name=$(ssh -q -o BatchMode=yes -o UserKnownHostsFile=known_hosts -i id_ed25519 "ops@$ip" ':put [/system identity get name]' | tr -d '\r')
[ "$name" = lab-router ] || { echo "Got identity '$name', wanted lab-router." >&2; exit 1; }

echo "ops's password works on the REST API, and a wrong one doesn't"
rest() { printf 'user = "%s"\n' "$1" | curl -sf -o /dev/null -K - "http://$ip/rest/system/identity"; }
rest "ops:$(val ops_password)"
refused rest "ops:not-the-password"

echo "SNMPv3 with authentication and encryption reads the router's name"
v3() { snmpget -v3 -l authPriv -u monitor -a SHA -A "$1" -x AES -X "$2" -t 3 -r 1 -Oqv "$ip" 1.3.6.1.2.1.1.5.0; }
v3 "$(val snmp_auth_password)" "$(val snmp_priv_password)" | grep -qx '"\?lab-router"\?'
refused v3 wrong-password "$(val snmp_priv_password)"
echo "The default community, public, no longer answers"
refused snmpget -v2c -c public -t 2 -r 0 "$ip" 1.3.6.1.2.1.1.5.0

echo "The client reaches the router's address on each VLAN, tagged on ether2"
for v in 20 30; do
  docker exec "$client" sh -c "ip link show eth1.$v >/dev/null 2>&1 || {
    ip link add link eth1 name eth1.$v type vlan id $v && ip addr add 10.$v.0.2/24 dev eth1.$v && ip link set eth1.$v up; }"
  docker exec "$client" ping -c 3 -W 2 "10.$v.0.1" >/dev/null
done

echo "Telnet and FTP are off"
for port in 23 21; do
  refused timeout 5 bash -c "exec 3<>/dev/tcp/$ip/$port"
done
echo "All checks passed."
