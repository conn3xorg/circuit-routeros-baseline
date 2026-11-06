terraform {
  required_providers {
    # Pinned exactly: a new provider release is a reviewed change to this
    # circuit, tested against the router before it's tagged.
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.99.1"
    }
  }
}
