#!/usr/bin/env sh
# Stops the lab and removes everything up.sh and Conn3x created here. The
# CHR download and the locally built image stay for the next run.
set -eu
cd "$(dirname "$0")"
sudo=sudo
[ "$(id -u)" -ne 0 ] || sudo=
[ ! -f lab.clab.yml ] || $sudo containerlab destroy -t lab.clab.yml --cleanup >/dev/null 2>&1 || true
rm -rf lab.clab.yml lab.auto.tfvars id_ed25519 id_ed25519.pub known_hosts .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup
echo "Removed."
