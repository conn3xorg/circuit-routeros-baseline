output "identity" {
  description = "The router's name."
  value       = routeros_system_identity.this.name
}

output "vlan_interfaces" {
  description = "The VLAN interface for each VLAN, by VLAN name, such as { iot = \"vlan20-iot\" }."
  value       = { for name, v in routeros_interface_vlan.this : name => v.name }
}
