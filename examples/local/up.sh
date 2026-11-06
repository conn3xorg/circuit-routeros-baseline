#!/usr/bin/env sh
# Starts a throwaway MikroTik CHR router in containerlab, with an Alpine
# client container wired to its ether2, and writes lab.auto.tfvars with the
# router's address and fresh lab passwords. Needs Docker, containerlab, KVM,
# git, make, unzip and curl, and runs containerlab with sudo unless you're
# root. The CHR image is downloaded from MikroTik and built locally with
# vrnetlab; it's never pushed anywhere.
set -eu
cd "$(dirname "$0")"
lab=${LAB_NAME:-routeros}
# One CHR release, checked against the SHA-256 recorded here when it was
# first downloaded, so moving to a newer one is a reviewed change.
chr=7.25.1
sha256=992eeb8ea7a44573a81783873821f7b34ab09a8505ce10245150ab053b60b9f6
vrnetlab=0b0e3a179b96245907101cad64eb5be690a9bde6
client=alpine:3.24.4@sha256:93b41ef40b1677fce8fcc64ff4af09daddfacf5040afde618bc46c1e2d1cc7d4
image=vrnetlab/mikrotik_routeros:$chr
cache=${XDG_CACHE_HOME:-$HOME/.cache}/circuit-routeros-baseline
sudo=sudo
[ "$(id -u)" -ne 0 ] || sudo=

if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  echo "No access to /dev/kvm. Add yourself to the kvm group, or run this where KVM is available." >&2
  exit 1
fi

if ! docker image inspect "$image" >/dev/null 2>&1; then
  mkdir -p "$cache"
  zip=chr-$chr.vmdk.zip
  if ! (cd "$cache" && echo "$sha256  $zip" | sha256sum -c --status - 2>/dev/null); then
    curl -fsSL -o "$cache/$zip" "https://download.mikrotik.com/routeros/$chr/$zip"
    (cd "$cache" && echo "$sha256  $zip" | sha256sum -c --quiet -) || { rm -f "$cache/$zip"; exit 1; }
  fi
  [ -d "$cache/vrnetlab" ] || git clone -q https://github.com/srl-labs/vrnetlab "$cache/vrnetlab"
  git -C "$cache/vrnetlab" checkout -q "$vrnetlab"
  (cd "$cache/vrnetlab/mikrotik/routeros" && rm -f ./*.vmdk && unzip -oq "$cache/$zip" && make docker-image >/dev/null && rm -f ./*.vmdk)
fi

cat > lab.clab.yml <<YML
name: $lab
topology:
  nodes:
    r1:
      kind: mikrotik_ros
      image: $image
    c1:
      kind: linux
      image: $client
  links:
    - endpoints: ["r1:eth1", "c1:eth1"]
YML
$sudo containerlab deploy -t lab.clab.yml --reconfigure >/dev/null
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "clab-$lab-r1")

# vrnetlab finishes its own setup over the serial console, which sets
# admin's password to admin, a few seconds after the REST API first
# answers. Wait for it, or it undoes the password change below.
for _ in $(seq 1 120); do
  docker logs "clab-$lab-r1" 2>&1 | grep -q 'Startup complete' && break
  sleep 3
done
curl -sf -o /dev/null -u admin:admin "http://$ip/rest/system/resource" || {
  echo "The router didn't finish starting, or its REST API didn't answer on http://$ip. See: docker logs clab-$lab-r1" >&2
  exit 1
}

[ -f id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C circuit-routeros-baseline -f id_ed25519
pw() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
admin=$(pw)
# The new admin password goes on stdin, not the command line. Right after
# setup the router can answer 400 to this and still make the change, so
# each try checks whether the new password works yet.
login() { printf 'user = "admin:%s"\n' "$1" | curl -sf -o /dev/null -K - "http://$ip/rest/system/identity"; }
for i in $(seq 1 20); do
  login "$admin" && break
  [ "$i" -lt 20 ] || { echo "Couldn't set the admin password." >&2; exit 1; }
  printf '{"numbers":"admin","password":"%s"}' "$admin" |
    curl -s -u admin:admin -H 'Content-Type: application/json' --data-binary @- "http://$ip/rest/user/set" >&2 || true
  sleep 3
done
ssh-keyscan -T 5 "$ip" 2>/dev/null > known_hosts

umask 077
cat > lab.auto.tfvars <<VARS
host               = "$ip"
admin_password     = "$admin"
ops_password       = "$(pw)"
snmp_auth_password = "$(pw)"
snmp_priv_password = "$(pw)"
VARS
echo "Ready: CHR $chr at http://$ip. Now run: conn3x init && conn3x apply"
