terraform {
  required_providers {
    # The version comes from the circuit's own pin.
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

# up.sh writes lab.auto.tfvars with the router's address and fresh lab
# passwords, so nothing here needs typing in.
variable "host" {
  type = string
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

# The lab router only serves plain HTTP. On a real router, give www-ssl a
# certificate and use https:// here and in rest_url.
provider "routeros" {
  hosturl  = "http://${var.host}"
  username = "admin"
  password = var.admin_password
}

module "routeros" {
  source = "../.."

  rest_url      = "http://${var.host}"
  rest_password = var.admin_password

  identity    = "lab-router"
  ntp_servers = ["time.cloudflare.com"]
  dns_servers = ["1.1.1.1", "9.9.9.9"]

  users = {
    ops = { group = "full", ssh_keys = [trimspace(file("${path.module}/id_ed25519.pub"))] }
  }
  user_passwords = { ops = var.ops_password }

  vlans = {
    iot   = { id = 20, address = "10.20.0.1/24" }
    guest = { id = 30, address = "10.30.0.1/24" }
  }
  # ether2 is the lab's link to the client container. ether1 is management
  # and stays off the bridge.
  trunk_ports = ["ether2"]

  snmp = {
    user      = "monitor"
    addresses = ["172.16.0.0/12"]
    location  = "lab"
  }
  snmp_passwords = {
    authentication = var.snmp_auth_password
    encryption     = var.snmp_priv_password
  }
}

output "vlan_interfaces" {
  value = module.routeros.vlan_interfaces
}
