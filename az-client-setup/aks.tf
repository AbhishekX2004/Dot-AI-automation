locals {
  resolved_cluster_name = var.cluster_name != "" ? var.cluster_name : "dot-ai-az-client-${var.client_name}"
  resource_group_name   = "${local.resolved_cluster_name}-rg"
}

resource "azurerm_resource_group" "rg" {
  name     = local.resource_group_name
  location = var.az_location

  tags = {
    environment = var.environment
    client      = var.client_name
  }
}

# Low-cost AKS Cluster (Free Tier, SystemAssigned identity, basic routing)
resource "azurerm_kubernetes_cluster" "this" {
  name                = local.resolved_cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "${local.resolved_cluster_name}-dns"

  sku_tier = "Free"

  default_node_pool {
    name       = "system"
    node_count = var.node_count
    vm_size    = var.node_vm_size
    os_disk_size_gb = var.node_disk_size_gb

    tags = {
      environment = var.environment
      client      = var.client_name
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
  }

  tags = {
    environment = var.environment
    client      = var.client_name
  }
}
