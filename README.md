# circuit-routeros-baseline

[![Conn3x grade](https://conn3x.org/circuits/routeros-baseline/grade.svg)](https://conn3x.org/circuits/routeros-baseline/grade)

A Conn3x circuit that gives a MikroTik RouterOS 7 router the settings you'd otherwise click through in WinBox after every reset: its name, NTP and DNS, your own admin users with SSH keys, telnet and the other plain-text services switched off, VLANs on a VLAN-filtering bridge, and SNMPv3 with the default `public` community turned off.

It talks to the router's REST API through the [terraform-routeros/routeros](https://registry.opentofu.org/providers/terraform-routeros/routeros) provider. Nothing is installed on the router, and the passwords you give it never land in state.

## Usage

```hcl
terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

variable "admin_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "ops_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "snmp_auth_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "snmp_priv_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

provider "routeros" {
  hosturl  = "https://192.0.2.1"
  username = "admin"
  password = var.admin_password
}

module "router" {
  source = "github.com/conn3xorg/circuit-routeros-baseline?ref=v0.1.0"

  rest_url      = "https://192.0.2.1"
  rest_password = var.admin_password

  identity    = "core-router"
  ntp_servers = ["time.cloudflare.com"]
  dns_servers = ["1.1.1.1", "9.9.9.9"]

  users = {
    ops = { ssh_keys = [file("~/.ssh/id_ed25519.pub")] }
  }
  user_passwords = { ops = var.ops_password }

  vlans = {
    iot   = { id = 20, address = "10.20.0.1/24" }
    guest = { id = 30, address = "10.30.0.1/24" }
  }
  trunk_ports  = ["ether2"]
  access_ports = { ether3 = "iot" }

  snmp = {
    user      = "monitor"
    addresses = ["192.0.2.0/24"]
  }
  snmp_passwords = {
    authentication = var.snmp_auth_password
    encryption     = var.snmp_priv_password
  }
}
```

Set the four passwords as `TF_VAR_admin_password` and friends, then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`, and `conn3x drift` tells you when someone has changed the router by hand since.

The same address goes in two places, the provider's `hosturl` and the circuit's `rest_url`, and so does the admin password. The provider does most of the work. The circuit makes a few calls of its own, for the reason in [Passwords stay out of state](#passwords-stay-out-of-state).

### Before the first apply

- **Use HTTPS on a real router.** Plain `http://` sends the admin password in the clear on every call. Give the `www-ssl` service a certificate first (`/certificate` on the router), then use `https://`. If the certificate is signed by your own CA, point `rest_ca_certificate` at it, and the provider's `ca_certificate` too.
- **Keep the port you're on off the bridge.** VLAN filtering drops untagged traffic that isn't in a port's PVID, so putting your management port into `trunk_ports` or `access_ports` cuts you off halfway through the apply. The lab in [examples/local](examples/local) manages the router through `ether1` and bridges `ether2`.
- **The circuit won't turn off the service it's using.** If `services` would switch off `www-ssl` while `rest_url` is `https://`, or `www` while it's `http://`, the plan stops with an error.

### Passwords stay out of state

RouterOS hands SNMP passwords back in plain text whenever they're read, and the provider has no write-only arguments, so anything it manages that holds a secret ends up in your state file. The circuit sidesteps that for the two things here that carry one:

- **Users** are created and updated by `curl` against the REST API, run by a `local-exec` step, with the password passed as an ephemeral value in its environment. RouterOS won't create a user without a password, so every name in `users` needs one in `user_passwords`.
- **The SNMPv3 community** goes the same way, and so does turning `public` off.

What that costs you: the router never returns a user's password, so neither a changed password nor a deleted user shows up as drift. When you change a password, raise `secrets_version` by one and apply. Removing a user or the SNMP block from your config leaves it on the router. The users' SSH keys, and everything else in the list below, go through the provider as usual, so drift on those is seen.

The machine running Conn3x needs `curl` 8.3 or later for this (it reads the secret from its environment with `--variable`), and a POSIX shell. CI checks that none of the passwords appear in the state file after apply.

## What it does

1. Sets the router's name (`/system identity`).
2. With `ntp_servers`, turns the NTP client on in unicast mode with those servers.
3. With `dns_servers`, sets the DNS servers and whether the router answers DNS queries from other hosts (`dns_allow_remote_requests`, off by default).
4. Turns IP services on or off by name. By default telnet, FTP, the plain-text API (8728) and API-SSL (8729) go off; SSH, WinBox and the web services are left as they are. A service you list gets its standard port back.
5. Creates or updates each user, with its group, its allowed address and its password, then adds its SSH keys.
6. With `vlans`, creates a VLAN-filtering bridge, adds `trunk_ports` (tagged, every VLAN) and `access_ports` (untagged, one VLAN), adds a bridge VLAN entry per VLAN with the bridge itself tagged, and makes a VLAN interface named `vlan<id>-<name>` per VLAN, with an address when you give one.
7. With `snmp`, creates or updates an SNMPv3 community with authentication and encryption, read-only, from `addresses` only, turns the default `public` community off, and then turns SNMP on with your contact and location.

It doesn't do firewall rules, DHCP servers, routing, WireGuard, certificates or RouterOS upgrades. The provider has resources for all of those, about 250 of them, and they sit fine next to this circuit in the same configuration.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `rest_url` | string | Required | The router's REST API address, the same one the provider's `hosturl` uses, such as `"https://192.0.2.1"`. Users and the SNMPv3 community are set through it. |
| `rest_username` | string | `"admin"` | User for the REST API calls, the same one the provider logs in as. |
| `rest_password` | string, ephemeral | Required | Password for `rest_username`. Never written to state or plan files. |
| `rest_ca_certificate` | string | `null` | Path to a CA certificate file that signed the router's HTTPS certificate. When null, curl uses the system's CA store. |
| `identity` | string | Required | The router's name. |
| `ntp_servers` | list(string) | `[]` | NTP servers. When empty, the NTP client is left as it is. |
| `dns_servers` | list(string) | `[]` | DNS servers the router uses. When empty, DNS settings are left as they are. |
| `dns_allow_remote_requests` | bool | `false` | Answer DNS queries from other hosts. Only applies when `dns_servers` is set. |
| `services` | map(bool) | telnet, ftp, api and api-ssl off | IP services to turn on (`true`) or off (`false`), by name: `telnet`, `ftp`, `www`, `www-ssl`, `ssh`, `api`, `api-ssl` or `winbox`. Services left out are left as they are. |
| `users` | map(object) | `{}` | Local users, by name, each with `group` (default `"full"`), `address` (where they may log in from; empty for anywhere), `ssh_keys` (OpenSSH public keys) and `comment`. |
| `user_passwords` | map(string), ephemeral | `{}` | A password for each user in `users`, by name. |
| `secrets_version` | number | `1` | Raise it to send `user_passwords` and `snmp_passwords` to the router again after you change them. |
| `bridge_name` | string | `"bridge-vlans"` | Name of the VLAN-filtering bridge, made when `vlans` is set. |
| `vlans` | map(object) | `{}` | VLANs by name, each with `id` (1 to 4094) and an optional `address` in CIDR form for the router's own interface on it. |
| `trunk_ports` | list(string) | `[]` | Ports that carry every VLAN tagged. Not the port you reach the router through. |
| `access_ports` | map(string) | `{}` | Ports that carry one VLAN untagged, as port name to VLAN name. Not the port you reach the router through. |
| `snmp` | object | `null` | SNMPv3 read-only access: `user`, `addresses` (required, at least one network), `contact`, `location`, `authentication_protocol` (`MD5` or `SHA1`, default `SHA1`) and `encryption_protocol` (`DES` or `AES`, default `AES`). When null, SNMP is left as it is. |
| `snmp_passwords` | object, ephemeral | `null` | `authentication` and `encryption` passwords for `snmp.user`, at least 8 characters each. |

## Outputs

| Name | Description |
| --- | --- |
| `identity` | The router's name. |
| `vlan_interfaces` | The VLAN interface for each VLAN, by VLAN name, such as `{ iot = "vlan20-iot" }`. |

## Requirements

Requires Conn3x v0.7.0 or later (ephemeral variables in `local-exec` environments), `curl` 8.3 or later and a POSIX shell on the machine that runs it, and a router on RouterOS 7.1 or later with the REST API reachable: the `www-ssl` service with a certificate, or `www` in a lab.

## The provider

This circuit pins [terraform-routeros/routeros](https://github.com/terraform-routeros/terraform-provider-routeros) at exactly 1.99.1. It's a community provider, not MikroTik's; most of its commits are by [vaerh](https://github.com/vaerh), with [gfenn-newbury](https://github.com/gfenn-newbury) next. A new provider release reaches this circuit only through a reviewed change that passes CI first.

Its maintenance has slowed this year, and you should know that before you build on it. As of 5 November 2026, its last release is 1.99.1 from 8 March 2026 and its last commit is from 16 March, while 39 pull requests are open, some from October. It isn't archived, and the issue tracker is still busy. If it stops being maintained, this circuit stops getting fixes with it: bugs we find go upstream, and we don't fork it.

RouterOS has a Safe Mode that undoes changes if your session drops, but it belongs to the terminal and WinBox, and the REST API this provider uses doesn't offer it, as far as we could find. So there's no automatic undo here: the guards above are what stands between a mistake and a trip to the router.

## Tested on

MikroTik CHR 7.25.1 (the stable channel on 5 November 2026), virtual, not hardware. CI downloads the CHR image from MikroTik, checks it against a pinned SHA-256, builds it into a local image with [vrnetlab](https://github.com/srl-labs/vrnetlab) at a pinned commit, and boots it under KVM in [containerlab](https://containerlab.dev) on a hosted Ubuntu 24.04 runner, with an Alpine container wired to its `ether2`. The image is never pushed or uploaded anywhere. [examples/local](examples/local) is the same lab.

In CI the example is applied first with the provider's previous release, 1.99.0, then with the pinned 1.99.1, and the plan after that has no changes. Then:

- `ops` logs in over SSH with its key and reads the router's name, and its password works on the REST API while a wrong one is refused.
- SNMPv3 with SHA1 and AES reads the router's name; a wrong password gets nothing, and `public` no longer answers.
- The client container pings the router's address on VLAN 20 and VLAN 30, tagged across `ether2`.
- Telnet and FTP refuse connections.
- None of the four passwords is in the state file.
- A name changed by hand through the REST API shows up in `conn3x drift`, and the next apply puts it back with a clean plan after.

A reboot test is left out. In vrnetlab's container the virtual CHR didn't come back from `/system reboot` within four minutes, so CI couldn't tell a router that lost its settings from one that never booted.

Things that can only show up on real hardware, such as switch-chip VLAN offload on CRS and hEX models, bridge hardware offload, PoE and SFP ports, weren't tested. CHR has none of them. Reports from people running it on hardware are welcome as issues.

## License

MPL-2.0. See [LICENSE](LICENSE). RouterOS is MikroTik's, under its own licence; CHR's free tier, which CI uses, has no time limit and caps upload at 1 Mbps per interface.
