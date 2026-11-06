# Local example

Applies circuit-routeros-baseline to a throwaway MikroTik CHR router in [containerlab](https://containerlab.dev), with an Alpine container plugged into its `ether2` so there's something on the other end of the VLANs. You need an x86_64 Linux machine with KVM, Docker, containerlab, Conn3x, `curl` 8.3 or later, `git`, `make` and `unzip`, plus `snmpget` (the `snmp` package on Debian and Ubuntu) for the checks.

```sh
./up.sh
conn3x init
conn3x apply
conn3x plan
./check.sh
```

The second plan says `No changes.`, and `check.sh` ends with `All checks passed.` It logs in as the new `ops` user with its key and its password, reads the router's name over SNMPv3, pings the router across both VLANs from the client container, and makes sure telnet and FTP are off.

`up.sh` downloads CHR 7.25.1 from MikroTik once, checks it against the SHA-256 written in the script, and builds a local Docker image from it with vrnetlab at a pinned commit. Both stay in `~/.cache/circuit-routeros-baseline` and in Docker for the next run; the image is never pushed anywhere. It then deploys the lab with `sudo containerlab deploy`, waits for vrnetlab to finish its first-boot setup (under a minute), changes the router's `admin` password from the default to a random one, and writes the router's address and fresh random passwords to `lab.auto.tfvars`, which Conn3x reads by itself. Set `LAB_NAME` to run a second lab beside the first.

The lab router speaks plain HTTP, which is fine on a Docker network on your own machine and nowhere else. See the circuit's README for HTTPS.

`./down.sh` destroys the lab and removes the key, the passwords and the state.
