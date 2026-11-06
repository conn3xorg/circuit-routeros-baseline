locals {
  ports = {
    telnet    = 23
    ftp       = 21
    www       = 80
    ssh       = 22
    "www-ssl" = 443
    api       = 8728
    winbox    = 8291
    "api-ssl" = 8729
  }

  # The service the provider and the REST calls come in through. Turning it
  # off would cut this apply off halfway.
  management_service = startswith(lower(var.rest_url), "https://") ? "www-ssl" : "www"

  # RouterOS returns SNMP passwords in plain text when they're read, and the
  # provider has no write-only arguments, so anything holding a secret is sent
  # straight to the REST API instead and never read back into state. curl
  # takes AUTH and BODY from its environment, which keeps them off its
  # command line, where ps could see them.
  curl = join(" ", compact([
    "curl -sS --fail-with-body",
    "--variable %AUTH --variable %BODY",
    "--expand-header 'Authorization: Basic {{AUTH}}'",
    "-H 'Content-Type: application/json' --expand-data '{{BODY}}'",
    var.rest_ca_certificate == null ? "" : "--cacert \"$CA\"",
  ]))

  # add fails when the entry already exists, and set then changes it in place.
  upsert = "${local.curl} \"$URL/rest/$MENU/add\" >/dev/null 2>&1 || BODY=\"$SET\" ${local.curl} \"$URL/rest/$MENU/set\" >/dev/null"

  ca = var.rest_ca_certificate == null ? "" : pathexpand(var.rest_ca_certificate)

  ssh_keys = merge([for name, user in var.users : { for i, key in user.ssh_keys : "${name}/${i}" => { user = name, key = key } }]...)

  vlans = length(var.vlans) > 0
}

resource "routeros_system_identity" "this" {
  name = var.identity
}

resource "routeros_system_ntp_client" "this" {
  count   = length(var.ntp_servers) > 0 ? 1 : 0
  enabled = true
  mode    = "unicast"
  servers = var.ntp_servers
}

resource "routeros_ip_dns" "this" {
  count                 = length(var.dns_servers) > 0 ? 1 : 0
  servers               = var.dns_servers
  allow_remote_requests = var.dns_allow_remote_requests
}

resource "routeros_ip_service" "this" {
  for_each = var.services
  numbers  = each.key
  port     = local.ports[each.key]
  disabled = !each.value

  lifecycle {
    precondition {
      condition     = lookup(var.services, local.management_service, true)
      error_message = "services turns off ${local.management_service}, the service rest_url reaches the router through. The apply would lock itself out."
    }
  }
}

# Users carry a password, so they go through the REST API (see local.curl).
# The SSH keys below are public and go through the provider, where a change
# made on the router shows as drift.
resource "terraform_data" "user" {
  for_each         = var.users
  triggers_replace = [each.value.group, each.value.address, each.value.comment, var.secrets_version]

  provisioner "local-exec" {
    command = local.upsert
    environment = {
      URL  = var.rest_url
      CA   = local.ca
      MENU = "user"
      AUTH = base64encode("${var.rest_username}:${var.rest_password}")
      BODY = jsonencode(merge(
        { name = each.key, group = each.value.group, comment = each.value.comment, password = var.user_passwords[each.key] },
        each.value.address == "" ? {} : { address = each.value.address },
      ))
      SET = jsonencode(merge(
        { numbers = each.key, group = each.value.group, comment = each.value.comment, password = var.user_passwords[each.key] },
        each.value.address == "" ? {} : { address = each.value.address },
      ))
    }
  }
}

resource "routeros_system_user_sshkeys" "this" {
  for_each   = local.ssh_keys
  user       = each.value.user
  key        = each.value.key
  depends_on = [terraform_data.user]
}

resource "routeros_interface_bridge" "vlans" {
  count          = local.vlans ? 1 : 0
  name           = var.bridge_name
  vlan_filtering = true
}

resource "routeros_interface_bridge_port" "trunk" {
  for_each          = local.vlans ? toset(var.trunk_ports) : toset([])
  bridge            = routeros_interface_bridge.vlans[0].name
  interface         = each.key
  pvid              = 1
  frame_types       = "admit-only-vlan-tagged"
  ingress_filtering = true
}

resource "routeros_interface_bridge_port" "access" {
  for_each          = local.vlans ? var.access_ports : {}
  bridge            = routeros_interface_bridge.vlans[0].name
  interface         = each.key
  pvid              = var.vlans[each.value].id
  frame_types       = "admit-only-untagged-and-priority-tagged"
  ingress_filtering = true
}

resource "routeros_interface_bridge_vlan" "this" {
  for_each = var.vlans
  bridge   = routeros_interface_bridge.vlans[0].name
  vlan_ids = [tostring(each.value.id)]
  # The bridge itself is tagged so the router's own VLAN interfaces see the traffic.
  tagged   = concat([routeros_interface_bridge.vlans[0].name], var.trunk_ports)
  untagged = sort([for port, vlan in var.access_ports : port if vlan == each.key])
}

resource "routeros_interface_vlan" "this" {
  for_each  = var.vlans
  name      = "vlan${each.value.id}-${each.key}"
  interface = routeros_interface_bridge.vlans[0].name
  vlan_id   = each.value.id
}

resource "routeros_ip_address" "this" {
  for_each  = { for name, v in var.vlans : name => v if v.address != null }
  address   = each.value.address
  interface = routeros_interface_vlan.this[each.key].name
}

# SNMPv3 community: it holds the passwords, so it goes through the REST API
# (see local.curl).
resource "terraform_data" "snmp_community" {
  count            = var.snmp == null ? 0 : 1
  triggers_replace = [var.snmp.user, var.snmp.addresses, var.snmp.authentication_protocol, var.snmp.encryption_protocol, var.secrets_version]

  provisioner "local-exec" {
    command = local.upsert
    environment = {
      URL  = var.rest_url
      CA   = local.ca
      MENU = "snmp/community"
      AUTH = base64encode("${var.rest_username}:${var.rest_password}")
      BODY = jsonencode({
        name                      = var.snmp.user
        security                  = "private"
        "authentication-protocol" = var.snmp.authentication_protocol
        "encryption-protocol"     = var.snmp.encryption_protocol
        "authentication-password" = var.snmp_passwords.authentication
        "encryption-password"     = var.snmp_passwords.encryption
        addresses                 = join(",", var.snmp.addresses)
        "read-access"             = "yes"
        "write-access"            = "no"
      })
      SET = jsonencode({
        numbers                   = var.snmp.user
        security                  = "private"
        "authentication-protocol" = var.snmp.authentication_protocol
        "encryption-protocol"     = var.snmp.encryption_protocol
        "authentication-password" = var.snmp_passwords.authentication
        "encryption-password"     = var.snmp_passwords.encryption
        addresses                 = join(",", var.snmp.addresses)
        "read-access"             = "yes"
        "write-access"            = "no"
      })
    }
  }
}

# The default community, public, answers SNMPv1 and v2c from every address
# with no password. RouterOS always gives it the id *0.
resource "terraform_data" "snmp_public_off" {
  count            = var.snmp == null ? 0 : 1
  triggers_replace = [var.secrets_version]

  provisioner "local-exec" {
    command = "BODY=\"$SET\" ${local.curl} \"$URL/rest/snmp/community/set\" >/dev/null"
    environment = {
      URL  = var.rest_url
      CA   = local.ca
      AUTH = base64encode("${var.rest_username}:${var.rest_password}")
      SET  = jsonencode({ numbers = "*0", disabled = "yes" })
    }
  }
}

# Turned on only once the community exists and public is off.
resource "routeros_snmp" "this" {
  count      = var.snmp == null ? 0 : 1
  enabled    = true
  contact    = var.snmp.contact
  location   = var.snmp.location
  depends_on = [terraform_data.snmp_community, terraform_data.snmp_public_off]
}
