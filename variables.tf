variable "rest_url" {
  type        = string
  description = "The router's REST API address, the same one the provider's hosturl uses, such as \"https://192.0.2.1\". Users and the SNMPv3 community are set through it."

  validation {
    condition     = can(regex("^https?://[^/]+$", var.rest_url))
    error_message = "rest_url must be http:// or https:// followed by a host, with no path, such as \"https://192.0.2.1\"."
  }
}

variable "rest_username" {
  type        = string
  default     = "admin"
  description = "User for the REST API calls, the same one the provider logs in as."
}

variable "rest_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password for rest_username. Ephemeral: it's never written to state or plan files."
}

variable "rest_ca_certificate" {
  type        = string
  default     = null
  description = "Path to a CA certificate file that signed the router's HTTPS certificate. When null, curl uses the system's CA store."
}

variable "identity" {
  type        = string
  description = "The router's name, as `/system identity` holds it."

  validation {
    condition     = length(var.identity) > 0 && length(var.identity) <= 64
    error_message = "identity must be 1 to 64 characters."
  }
}

variable "ntp_servers" {
  type        = list(string)
  default     = []
  description = "NTP servers, by address or name. When empty, the NTP client is left as it is."
}

variable "dns_servers" {
  type        = list(string)
  default     = []
  description = "DNS servers the router uses. When empty, DNS settings are left as they are."
}

variable "dns_allow_remote_requests" {
  type        = bool
  default     = false
  description = "Answer DNS queries from other hosts. Only applies when dns_servers is set. Turn it on only with a firewall rule that keeps the resolver off the internet."
}

variable "services" {
  type = map(bool)
  default = {
    telnet    = false
    ftp       = false
    api       = false
    "api-ssl" = false
  }
  description = "IP services to turn on (true) or off (false), by name: telnet, ftp, www, www-ssl, ssh, api, api-ssl or winbox. Services left out are left as they are."

  validation {
    condition     = alltrue([for name in keys(var.services) : contains(["telnet", "ftp", "www", "www-ssl", "ssh", "api", "api-ssl", "winbox"], name)])
    error_message = "services keys must be telnet, ftp, www, www-ssl, ssh, api, api-ssl or winbox."
  }
}

variable "users" {
  type = map(object({
    group    = optional(string, "full")
    address  = optional(string, "")
    ssh_keys = optional(list(string), [])
    comment  = optional(string, "")
  }))
  default     = {}
  description = "Local users, by name. address limits where the user may log in from, such as \"192.0.2.0/24\"; empty allows anywhere. ssh_keys are public keys in OpenSSH format. Each user needs a password in user_passwords."
}

variable "user_passwords" {
  type        = map(string)
  default     = {}
  ephemeral   = true
  sensitive   = true
  description = "Password for each user in users, by name. Ephemeral: it's never written to state or plan files."

  validation {
    condition     = alltrue([for name in keys(var.users) : contains(keys(var.user_passwords), name)])
    error_message = "Every user in users needs a password in user_passwords: RouterOS won't create a user without one."
  }
}

variable "secrets_version" {
  type        = number
  default     = 1
  description = "Raise this to send user_passwords and snmp_passwords to the router again, after you change them. The router never returns the users' passwords, so a change can't be seen any other way."
}

variable "bridge_name" {
  type        = string
  default     = "bridge-vlans"
  description = "Name of the VLAN-filtering bridge the circuit creates when vlans is set."
}

variable "vlans" {
  type = map(object({
    id      = number
    address = optional(string)
  }))
  default     = {}
  description = "VLANs on the bridge, by name, such as { iot = { id = 20, address = \"10.20.0.1/24\" } }. Each gets a VLAN interface named vlan<id>-<name>, with the address on it when address is set."

  validation {
    condition     = alltrue([for v in var.vlans : v.id >= 1 && v.id <= 4094 && floor(v.id) == v.id])
    error_message = "Each VLAN id must be a whole number from 1 to 4094."
  }

  validation {
    condition     = length(distinct([for v in var.vlans : v.id])) == length(var.vlans)
    error_message = "Each VLAN needs its own id."
  }
}

variable "trunk_ports" {
  type        = list(string)
  default     = []
  description = "Ports that carry every VLAN in vlans tagged, such as [\"ether2\"]. Don't list the port you reach the router through."
}

variable "access_ports" {
  type        = map(string)
  default     = {}
  description = "Ports that carry one VLAN untagged, as port name to VLAN name, such as { ether3 = \"iot\" }. Don't list the port you reach the router through."

  validation {
    condition     = alltrue([for vlan in values(var.access_ports) : contains(keys(var.vlans), vlan)])
    error_message = "Each access port must name a VLAN in vlans."
  }

  validation {
    condition     = length(setintersection(toset(keys(var.access_ports)), toset(var.trunk_ports))) == 0
    error_message = "A port can be a trunk port or an access port, not both."
  }
}

variable "snmp" {
  type = object({
    user                    = string
    addresses               = list(string)
    contact                 = optional(string, "")
    location                = optional(string, "")
    authentication_protocol = optional(string, "SHA1")
    encryption_protocol     = optional(string, "AES")
  })
  default     = null
  description = "SNMPv3 read-only access with authentication and encryption, for the user named here, from the networks in addresses, such as [\"192.0.2.0/24\"]. The default community, public, is turned off. When null, SNMP is left as it is."

  validation {
    condition     = var.snmp == null || try(contains(["MD5", "SHA1"], var.snmp.authentication_protocol) && contains(["DES", "AES"], var.snmp.encryption_protocol), false)
    error_message = "authentication_protocol must be MD5 or SHA1, and encryption_protocol DES or AES."
  }

  validation {
    condition     = var.snmp == null || try(length(var.snmp.addresses) > 0, false)
    error_message = "snmp.addresses must list at least one network, so SNMP isn't open to every address."
  }
}

variable "snmp_passwords" {
  type = object({
    authentication = string
    encryption     = string
  })
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "SNMPv3 passwords for snmp.user, each at least 8 characters. Ephemeral: they're never written to state or plan files."

  validation {
    condition     = var.snmp == null || try(length(var.snmp_passwords.authentication) >= 8 && length(var.snmp_passwords.encryption) >= 8, false)
    error_message = "snmp needs snmp_passwords, with authentication and encryption passwords of at least 8 characters each."
  }
}
