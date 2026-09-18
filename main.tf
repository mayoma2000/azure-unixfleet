# terraform-azure-fleets
#
# Common IaC to rehost on-prem VMs as Azure VM fleets — the Azure counterpart of
# sanservices/terraform-ec2-fleets. Each application is one data-driven entry that produces a
# Flexible VMSS + NSG + a backend pool/probe/rule on the shared Load Balancer + a Private DNS
# record. Multiple VM sizes; zone-redundant HA (>=2 instances across availability zones).
#
# Lifecycle: TEMPORARY bridge — retired as applications move to containers on AKS. Build
# everything to delete as cleanly as it was created; no deep per-VM modernization here.
#
# Publishes to contract: none
# Consumes from contract: platform/lb/*, platform/dns/*, platform/net/*  (Azure App Configuration)
#
# ---------------------------------------------------------------------------------------------
# WHY A LAYER-4 SHARED LB AND NOT AN APPLICATION GATEWAY
#
# The AWS repo attaches to a shared ALB because aws_lb_target_group and aws_lb_listener_rule are
# independent resources — they can point at a listener owned by another Terraform state. Azure has
# no equivalent for Application Gateway: azurerm_application_gateway is a single monolithic
# resource whose backend pools, listeners and routing rules are inline blocks, so a second state
# cannot add a backend to it without fighting over the whole resource. Attaching to a shared AGW
# would mean either moving these fleets into the shared-lb state (killing the decoupling the whole
# repo set is built on) or PATCHing child collections through the azapi provider (too fragile for
# a bridge that is supposed to be deleted).
#
# azurerm_lb_backend_address_pool / _probe / _rule ARE independent resources, so the shared
# Standard Load Balancer keeps the contract intact. Two consequences, both deliberate:
#
#   1. Each fleet claims a pre-provisioned FRONTEND IP CONFIG on the shared LB instead of a
#      listener-rule priority. The shared-lb repo publishes the pool of available config names and
#      their private IPs; a fleet names one, and the same two cross-entry guards apply (claimed at
#      most once per scope, and a member of the published set). Every fleet then serves on 443 —
#      no per-app ports in URLs.
#   2. L4 means NO host-header routing, so TLS terminates ON THE VM, on the source's own nginx.
#      That inverts the AWS migration, which stripped the guest's TLS keys because the ALB
#      terminated. Keep the certs when capturing a guest for Azure. It also collapses the
#      hostname/extra_hostnames/aliases distinction: with nothing matching a Host header, every
#      name is simply another A record, and `aliases` (matched-but-never-recorded) has no meaning.
# ---------------------------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
  }

  # Azure Blob leases the state file natively, so there is no DynamoDB/use_lockfile analog to
  # configure — the lock is a property of the blob. Key mirrors the AWS layout:
  #   terraform init -backend-config="key=platform/terraform-azure-fleets/prod/terraform.tfstate"
  backend "azurerm" {
    resource_group_name  = "rg-uvi-terraform-state"
    storage_account_name = "uviterraformstatecac"
    container_name       = "tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# Private DNS zones live in the hub subscription (terraform-azure-dns). Aliased provider mirrors
# the AWS repo's aws.dns provider + record-writer role.
provider "azurerm" {
  alias = "dns"
  features {}
  subscription_id = var.dns_subscription_id
}

# =================================================================================================
# Variables
# =================================================================================================

variable "subscription_id" {
  description = "Subscription hosting the fleets."
  type        = string
}

variable "dns_subscription_id" {
  description = "Subscription hosting the Private DNS zones (hub)."
  type        = string
}

variable "location" {
  description = "Azure region. Canada Central is the ca-central-1 counterpart."
  type        = string
  default     = "canadacentral"
}

variable "environment" {
  description = "Environment name; selects the contract label and the state key."
  type        = string

  validation {
    condition     = contains(["nonprod", "prod"], var.environment)
    error_message = "environment must be nonprod or prod (no propci — PCI fleets get their own repo)."
  }
}

variable "app_config_id" {
  description = "Resource ID of the Azure App Configuration store holding the platform/* contract."
  type        = string
}

variable "user_data_dir" {
  description = "Base directory for fleets[*].user_data_file."
  type        = string
  default     = "userdata"
}

variable "azure_api_egress" {
  description = <<-EOT
    How the VM guest agent and Key Vault/Storage clients reach Azure control-plane endpoints.
    "internet"          = one outbound TCP/443 rule to the AzureCloud service tag, via NAT Gateway.
    "private-endpoints" = in-VNet Private Endpoints only; required for the no-egress CDE.
    Counterpart of the AWS repo's aws_api_egress.
  EOT
  type        = string
  default     = "internet"

  validation {
    condition     = contains(["internet", "private-endpoints"], var.azure_api_egress)
    error_message = "azure_api_egress must be internet or private-endpoints."
  }
}

variable "ssh_admin_cidrs" {
  description = "Default source CIDRs for fleets that declare ssh. Internal ranges only."
  type        = list(string)
  default     = []
}

variable "enable_artifact_store" {
  description = "Create the shared Storage Account used to get files onto instances."
  type        = bool
  default     = false
}

variable "enable_disk_cmk" {
  description = "Create a Key Vault CMK + disk encryption set for managed disks."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "fleets" {
  description = <<-EOT
    One entry per rehosted application. Kept in envs/<env>-fleets.tfvars, separate from the
    environment scalars in envs/<env>.tfvars, because Terraform does not deep-merge map-typed
    variables across multiple -var-file inputs — so a per-app .tfvars file cannot work.
  EOT

  type = map(object({
    hostname        = string              # canonical FQDN; gets the Private DNS A record
    vm_size         = string              # e.g. Standard_D2as_v5
    count           = optional(number, 1) # >= 2 across zones for HA
    source_image_id = string              # Compute Gallery image version or managed image (Azure Migrate)
    scope           = string              # internal | external
    zones           = optional(list(string), ["1", "2", "3"])

    # The claimed slot on the shared LB — see the header. Replaces the AWS listener-rule priority.
    frontend_ip_config = string

    target_port     = optional(number, 443)
    health_path     = optional(string, "/")
    health_protocol = optional(string, "Https")

    # Bootstrap. Both empty for an Azure Migrate image (already configured). Set exactly one:
    # user_data for a few inline lines, user_data_file for anything longer.
    user_data      = optional(string, "")
    user_data_file = optional(string, "")
    user_data_vars = optional(map(string), null) # declaring vars switches file() -> templatefile()

    # Extra Private DNS A records. Under L4 there is no Host-header match to widen, so unlike the
    # AWS repo there is no matched-only `aliases` list — a name either gets a record or it doesn't.
    extra_hostnames = optional(list(string), [])

    egress_cidrs = optional(list(string), []) # exceptions beyond the VNet; empty = VNet-only

    # Never silently rebuilt from its image on a failed probe. Default, same as AWS.
    stateful            = optional(bool, true)
    health_grace_period = optional(string, "PT30M")

    ssh = optional(object({
      source_cidrs   = optional(list(string), null) # null = var.ssh_admin_cidrs
      bastion_subnet = optional(string, null)       # or allow from the Bastion subnet prefix
    }), null)

    admin_username = optional(string, "azureuser")
    admin_ssh_key  = optional(string, null)

    data_disks = optional(map(object({
      lun                    = number
      size_gb                = number
      storage_account_type   = optional(string, "Premium_LRS")
      caching                = optional(string, "ReadWrite")
      disk_encryption_set_id = optional(string, null)
    })), {})

    artifacts = optional(object({
      read_containers = optional(list(string), [])
      write           = optional(bool, false)
    }), null)

    key_vault_ids = optional(list(string), []) # grants the fleet identity secret read access
  }))

  default = {}

  validation {
    condition     = alltrue([for k, v in var.fleets : contains(["internal", "external"], v.scope)])
    error_message = "Each fleet's scope must be internal or external."
  }

  validation {
    condition     = alltrue([for k, v in var.fleets : v.count >= 1])
    error_message = "Each fleet's count must be >= 1 (use >= 2 for zone-redundant HA)."
  }

  validation {
    condition     = alltrue([for k, v in var.fleets : !(v.user_data != "" && v.user_data_file != "")])
    error_message = "Set user_data or user_data_file on a fleet, never both."
  }

  validation {
    condition     = alltrue([for k, v in var.fleets : contains(["Http", "Https", "Tcp"], v.health_protocol)])
    error_message = "health_protocol must be Http, Https or Tcp."
  }

  validation {
    condition     = alltrue([for k, v in var.fleets : can(regex("^[a-z0-9-]{1,40}$", k))])
    error_message = "Fleet keys are used in resource names: lowercase letters, digits and hyphens only."
  }
}

# =================================================================================================
# Contract — read from Azure App Configuration (the SSM Parameter Store counterpart).
# Ownership-neutral keys under platform/*, labelled by environment. No cross-repo state access.
# =================================================================================================

locals {
  scopes = distinct([for v in var.fleets : v.scope])
}

data "azurerm_app_configuration_key" "vnet_id" {
  configuration_store_id = var.app_config_id
  key                    = "platform/net/vnet-id"
  label                  = var.environment
}

data "azurerm_app_configuration_key" "private_subnet_ids" {
  configuration_store_id = var.app_config_id
  key                    = "platform/net/private-subnet-ids"
  label                  = var.environment
}

data "azurerm_app_configuration_key" "resource_group" {
  configuration_store_id = var.app_config_id
  key                    = "platform/net/workload-resource-group"
  label                  = var.environment
}

data "azurerm_app_configuration_key" "lb_id" {
  for_each               = toset(local.scopes)
  configuration_store_id = var.app_config_id
  key                    = "platform/lb/${each.key}/id"
  label                  = var.environment
}

# name -> private IP of every frontend IP configuration the shared LB pre-provisions for fleets.
# A fleet claims one by name; the DNS A record points at its IP. This is the published-range
# counterpart of the AWS repo's /platform/lb/<scope>/priority-range.
data "azurerm_app_configuration_key" "lb_frontend_ips" {
  for_each               = toset(local.scopes)
  configuration_store_id = var.app_config_id
  key                    = "platform/lb/${each.key}/frontend-ips"
  label                  = var.environment
}

data "azurerm_app_configuration_key" "dns_zone_name" {
  configuration_store_id = var.app_config_id
  key                    = "platform/dns/${var.environment}/private-zone-name"
  label                  = var.environment
}

data "azurerm_app_configuration_key" "dns_zone_id" {
  configuration_store_id = var.app_config_id
  key                    = "platform/dns/${var.environment}/private-zone-id"
  label                  = var.environment
}

data "azurerm_virtual_network" "shared" {
  name                = element(split("/", data.azurerm_app_configuration_key.vnet_id.value), 8)
  resource_group_name = element(split("/", data.azurerm_app_configuration_key.vnet_id.value), 4)
}

# =================================================================================================
# Locals — contract decoding, bootstrap resolution, guard inputs
# =================================================================================================

locals {
  resource_group_name = data.azurerm_app_configuration_key.resource_group.value
  vnet_cidrs          = data.azurerm_virtual_network.shared.address_space
  private_subnet_ids  = split(",", data.azurerm_app_configuration_key.private_subnet_ids.value)
  dns_zone_name       = data.azurerm_app_configuration_key.dns_zone_name.value
  dns_zone_id         = data.azurerm_app_configuration_key.dns_zone_id.value

  # scope -> { frontend-config-name = "10.x.y.z" }
  lb_frontend_ips = {
    for scope, kv in data.azurerm_app_configuration_key.lb_frontend_ips :
    scope => jsondecode(kv.value)
  }

  # Resolved bootstrap per fleet. A path containing "/" is repo-relative and skips user_data_dir,
  # so "gcv.sh" resolves to userdata/gcv.sh while "shared/common.sh" resolves exactly as written.
  fleet_user_data_paths = {
    for k, v in var.fleets : k => (
      strcontains(v.user_data_file, "/")
      ? "${path.root}/${v.user_data_file}"
      : "${path.root}/${var.user_data_dir}/${v.user_data_file}"
    ) if v.user_data_file != ""
  }

  fleet_user_data_missing = [
    for k, p in local.fleet_user_data_paths : k if !fileexists(p)
  ]

  # The file is read VERBATIM with file() and is NOT a template unless the fleet declares
  # user_data_vars — declaring vars is what switches the read to templatefile(). Deliberate:
  # bootstrap scripts are shell, and shell is full of $ ($1, $(…), ${VAR}, nginx's $remote_addr).
  # Under templatefile() every ${ and %{ is a Terraform interpolation needing $${ / %%{, and when
  # it isn't escaped the result is a plan error or — worse — a silent substitution.
  fleet_user_data = {
    for k, v in var.fleets : k => (
      v.user_data != "" ? v.user_data
      : v.user_data_file == "" ? ""
      : !fileexists(local.fleet_user_data_paths[k]) ? ""
      : v.user_data_vars == null ? file(local.fleet_user_data_paths[k])
      : templatefile(local.fleet_user_data_paths[k], v.user_data_vars)
    )
  }

  # Azure caps custom data at 64 KB of RAW bytes, enforced at VM create — so exceeding it means the
  # scale set silently never reaches capacity. Measured through base64encode() because length()
  # counts characters, not bytes.
  fleet_user_data_oversized = [
    for k, d in local.fleet_user_data : k
    if d != "" && (length(base64encode(d)) / 4 * 3) > 65536
  ]

  # Cross-entry check a single-variable validation block cannot express: two fleets in the same
  # scope must not claim the same frontend IP configuration. Grouped by "<scope>/<slot>" rather
  # than compared pairwise via setproduct — Terraform's < operator only accepts numbers, so the
  # usual pair[0] < pair[1] trick for deduping the pair list cannot be used on map keys.
  slot_conflicts = {
    for slot, names in { for k, v in var.fleets : "${v.scope}/${v.frontend_ip_config}" => k... } :
    slot => names if length(names) > 1
  }

  # Cross-entry check against the set the shared LB actually publishes for that scope.
  slot_unpublished = [
    for k, v in var.fleets : k
    if !contains(keys(local.lb_frontend_ips[v.scope]), v.frontend_ip_config)
  ]

  # Flattened fleet -> data disk pairs, so the disks can be declared once at the root.
  fleet_data_disks = merge([
    for k, v in var.fleets : {
      for dk, dv in v.data_disks : "${k}/${dk}" => merge(dv, { fleet = k })
    }
  ]...)
}

# =================================================================================================
# Plan-time guards. Resources that create nothing and exist only to carry preconditions — the
# checks a variable validation block cannot reach because they need path.root, the file's contents,
# or another entry in the map.
# =================================================================================================

resource "terraform_data" "fleet_slot_guard" {
  lifecycle {
    precondition {
      condition     = length(local.slot_conflicts) == 0
      error_message = "Two fleets claim the same frontend IP configuration within a scope: ${jsonencode(local.slot_conflicts)}"
    }
    precondition {
      condition     = length(local.slot_unpublished) == 0
      error_message = "Fleet claims a frontend IP configuration the shared LB does not publish for its scope: ${jsonencode({ for k in local.slot_unpublished : k => var.fleets[k].frontend_ip_config })}"
    }
  }
}

resource "terraform_data" "fleet_user_data_guard" {
  lifecycle {
    precondition {
      condition     = length(local.fleet_user_data_missing) == 0
      error_message = "Fleet user_data_file does not exist (resolved under var.user_data_dir unless the path contains \"/\"): ${jsonencode({ for k in local.fleet_user_data_missing : k => local.fleet_user_data_paths[k] })}"
    }
    precondition {
      condition     = length(local.fleet_user_data_oversized) == 0
      error_message = "Fleet user_data exceeds Azure's 64 KB custom-data limit (rejected at VM create, so the scale set would never reach capacity): ${jsonencode({ for k in local.fleet_user_data_oversized : k => "${length(base64encode(local.fleet_user_data[k])) / 4 * 3} bytes" })}"
    }
  }
}

# =================================================================================================
# Per-fleet identity — the instance-profile counterpart. Managed identity + RBAC, no static keys.
# =================================================================================================

resource "azurerm_user_assigned_identity" "fleet" {
  for_each = var.fleets

  name                = "id-fleet-${each.key}-${var.environment}"
  resource_group_name = local.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "fleet_key_vault" {
  for_each = merge([
    for k, v in var.fleets : {
      for kv in v.key_vault_ids : "${k}/${basename(kv)}" => { fleet = k, vault_id = kv }
    }
  ]...)

  scope                = each.value.vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.fleet[each.value.fleet].principal_id
}

# =================================================================================================
# Per-fleet NSG. One NSG per fleet, so rule priorities are local and no cross-fleet guard is
# needed for them — unlike the shared LB slot above.
#
# Azure allows all outbound by default (AllowInternetOutbound), which is the opposite of an AWS
# security group. To land on the AWS repo's posture — VNet-only egress unless the fleet declares
# exceptions — every rule below is an explicit allow ahead of a deny-all at 4000.
# =================================================================================================

resource "azurerm_network_security_group" "fleet" {
  for_each = var.fleets

  name                = "nsg-fleet-${each.key}-${var.environment}"
  resource_group_name = local.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_network_security_rule" "app_from_lb" {
  for_each = var.fleets

  name                        = "allow-app-from-lb"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.fleet[each.key].name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.target_port)
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
}

# The health probe originates from AzureLoadBalancer too, but data-plane traffic through a Standard
# LB arrives with the ORIGINAL client source IP (it is a pass-through, not a proxy like an ALB).
# Allowing only the AzureLoadBalancer tag would pass probes and drop every real request.
resource "azurerm_network_security_rule" "app_from_vnet" {
  for_each = var.fleets

  name                        = "allow-app-from-vnet"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.fleet[each.key].name
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.target_port)
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
}

# SSH is the exception for guests too old to run the VM agent. Terraform owns the network path,
# NOT the credential: admin_ssh_key is a no-op without cloud-init, and an Azure Migrate guest keeps
# its on-prem users and keys.
resource "azurerm_network_security_rule" "ssh" {
  for_each = { for k, v in var.fleets : k => v if v.ssh != null }

  name                        = "allow-ssh-internal"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.fleet[each.key].name
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes = coalesce(
    each.value.ssh.bastion_subnet != null ? [each.value.ssh.bastion_subnet] : null,
    each.value.ssh.source_cidrs,
    var.ssh_admin_cidrs,
  )
  destination_address_prefix = "*"
}

resource "azurerm_network_security_rule" "egress_vnet" {
  for_each = var.fleets

  name                        = "allow-egress-vnet"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.fleet[each.key].name
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "VirtualNetwork"
}

# One TCP/443 rule to the AzureCloud service tag when the guest agent egresses over NAT. Under
# "private-endpoints" the rule is omitted and the agent must reach Azure in-VNet.
resource "azurerm_network_security_rule" "egress_azure_api" {
  for_each = var.azure_api_egress == "internet" ? var.fleets : {}

  name                        = "allow-egress-azure-api"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.fleet[each.key].name
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "AzureCloud"
}

resource "azurerm_network_security_rule" "egress_declared" {
  for_each = { for k, v in var.fleets : k => v if length(v.egress_cidrs) > 0 }

  name                         = "allow-egress-declared"
  resource_group_name          = local.resource_group_name
  network_security_group_name  = azurerm_network_security_group.fleet[each.key].name
  priority                     = 120
  direction                    = "Outbound"
  access                       = "Allow"
  protocol                     = "*"
  source_port_range            = "*"
  destination_port_range       = "*"
  source_address_prefix        = "*"
  destination_address_prefixes = each.value.egress_cidrs
}

resource "azurerm_network_security_rule" "egress_deny" {
  for_each = var.fleets

  name                        = "deny-egress-default"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.fleet[each.key].name
  priority                    = 4000
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

# =================================================================================================
# Shared LB attachment. These three are independent resources pointing at a loadbalancer_id owned
# by terraform-azure-shared-lb — the property that makes the whole contract possible in Azure.
# =================================================================================================

resource "azurerm_lb_backend_address_pool" "fleet" {
  for_each = var.fleets

  name            = "bep-${each.key}"
  loadbalancer_id = data.azurerm_app_configuration_key.lb_id[each.value.scope].value
}

resource "azurerm_lb_probe" "fleet" {
  for_each = var.fleets

  name                = "probe-${each.key}"
  loadbalancer_id     = data.azurerm_app_configuration_key.lb_id[each.value.scope].value
  protocol            = each.value.health_protocol
  port                = each.value.target_port
  request_path        = each.value.health_protocol == "Tcp" ? null : each.value.health_path
  interval_in_seconds = 15
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "fleet" {
  for_each = var.fleets

  name                           = "rule-${each.key}"
  loadbalancer_id                = data.azurerm_app_configuration_key.lb_id[each.value.scope].value
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = each.value.target_port
  frontend_ip_configuration_name = each.value.frontend_ip_config
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.fleet[each.key].id]
  probe_id                       = azurerm_lb_probe.fleet[each.key].id
  idle_timeout_in_minutes        = 30
  tcp_reset_enabled              = true

  depends_on = [terraform_data.fleet_slot_guard]
}

# =================================================================================================
# Compute. Flexible-orchestration scale set is the ASG counterpart: N instances spread across
# availability zones behind one backend pool, replaceable without touching the fleet declaration.
# =================================================================================================

resource "azurerm_orchestrated_virtual_machine_scale_set" "fleet" {
  for_each = var.fleets

  name                = "vmss-${each.key}-${var.environment}"
  resource_group_name = local.resource_group_name
  location            = var.location

  sku_name                    = each.value.vm_size
  instances                   = each.value.count
  source_image_id             = each.value.source_image_id
  zones                       = each.value.zones
  zone_balance                = each.value.count >= 2
  platform_fault_domain_count = 1 # required for a zonal Flexible scale set

  # A stateful fleet is never silently rebuilt from its image on a failed probe — the AWS repo
  # suspends the ASG HealthCheck process for the same reason. Consequence, and it has bitten:
  # after a manual delete the scale set will NOT launch a replacement, so a reprovision has to
  # scale down and back up rather than relying on auto-repair.
  automatic_instance_repair {
    enabled      = !each.value.stateful
    grace_period = each.value.health_grace_period
  }

  os_profile {
    linux_configuration {
      admin_username                  = each.value.admin_username
      disable_password_authentication = true
      provision_vm_agent              = true

      dynamic "admin_ssh_key" {
        for_each = each.value.admin_ssh_key != null ? [each.value.admin_ssh_key] : []
        content {
          username   = each.value.admin_username
          public_key = admin_ssh_key.value
        }
      }
    }
  }

  user_data_base64 = local.fleet_user_data[each.key] != "" ? base64encode(local.fleet_user_data[each.key]) : null

  network_interface {
    name                      = "nic-${each.key}"
    primary                   = true
    network_security_group_id = azurerm_network_security_group.fleet[each.key].id

    ip_configuration {
      name      = "ipconfig-${each.key}"
      primary   = true
      version   = "IPv4"
      subnet_id = local.private_subnet_ids[0]

      load_balancer_backend_address_pool_ids = [
        azurerm_lb_backend_address_pool.fleet[each.key].id
      ]
    }
  }

  os_disk {
    storage_account_type   = "Premium_LRS"
    caching                = "ReadWrite"
    disk_encryption_set_id = var.enable_disk_cmk ? azurerm_disk_encryption_set.fleets[0].id : null
  }

  dynamic "data_disk" {
    for_each = each.value.data_disks
    content {
      lun                  = data_disk.value.lun
      disk_size_gb         = data_disk.value.size_gb
      storage_account_type = data_disk.value.storage_account_type
      caching              = data_disk.value.caching
      create_option        = "Empty"
      disk_encryption_set_id = coalesce(
        data_disk.value.disk_encryption_set_id,
        var.enable_disk_cmk ? azurerm_disk_encryption_set.fleets[0].id : null,
      )
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.fleet[each.key].id]
  }

  tags = merge(var.tags, { fleet = each.key, lifecycle-stage = "migration-bridge" })

  depends_on = [terraform_data.fleet_user_data_guard]
}

# =================================================================================================
# Private DNS. The AWS repo aliases a name to the ALB's own FQDN; here the record is an A to the
# private IP of the frontend configuration the fleet claimed.
# =================================================================================================

resource "azurerm_private_dns_a_record" "fleet" {
  provider = azurerm.dns
  for_each = var.fleets

  name                = trimsuffix(trimsuffix(each.value.hostname, local.dns_zone_name), ".")
  private_dns_zone_id = local.dns_zone_id
  ttl                 = 60
  records             = [local.lb_frontend_ips[each.value.scope][each.value.frontend_ip_config]]
  tags                = var.tags
}

resource "azurerm_private_dns_a_record" "extra" {
  provider = azurerm.dns

  for_each = merge([
    for k, v in var.fleets : {
      for h in v.extra_hostnames : h => { fleet = k, scope = v.scope, slot = v.frontend_ip_config }
    }
  ]...)

  name                = trimsuffix(trimsuffix(each.key, local.dns_zone_name), ".")
  private_dns_zone_id = local.dns_zone_id
  ttl                 = 60
  records             = [local.lb_frontend_ips[each.value.scope][each.value.slot]]
  tags                = var.tags
}

# =================================================================================================
# Managed-disk CMK (optional)
# =================================================================================================

resource "azurerm_key_vault" "disks" {
  count = var.enable_disk_cmk ? 1 : 0

  name                       = "kv-fleet-disks-${var.environment}"
  resource_group_name        = local.resource_group_name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = true # required before a key can back a disk encryption set
  rbac_authorization_enabled = true
  tags                       = var.tags
}

resource "azurerm_key_vault_key" "disks" {
  count = var.enable_disk_cmk ? 1 : 0

  name         = "fleet-disks"
  key_vault_id = azurerm_key_vault.disks[0].id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["decrypt", "encrypt", "wrapKey", "unwrapKey"]
}

resource "azurerm_disk_encryption_set" "fleets" {
  count = var.enable_disk_cmk ? 1 : 0

  name                = "des-fleets-${var.environment}"
  resource_group_name = local.resource_group_name
  location            = var.location
  key_vault_key_id    = azurerm_key_vault_key.disks[0].id
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "des_key_access" {
  count = var.enable_disk_cmk ? 1 : 0

  scope                = azurerm_key_vault.disks[0].id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.fleets[0].identity[0].principal_id
}

data "azurerm_client_config" "current" {}

# =================================================================================================
# Artifact store (optional). One Storage Account per environment for getting files onto instances —
# the auditable alternative to scp, which the access model exists to avoid.
#
# Isolation is CLEANER than the AWS repo's S3 prefixes: a container is a real RBAC scope, so each
# fleet's identity is granted Blob Data Reader on ITS OWN CONTAINER and nothing else. No ABAC
# condition, and no prefix policy to get wrong.
# =================================================================================================

resource "azurerm_storage_account" "artifacts" {
  count = var.enable_artifact_store ? 1 : 0

  name                            = "uvifleetartifacts${var.environment}"
  resource_group_name             = local.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # identity-only; no account keys to leak
  tags                            = var.tags
}

resource "azurerm_storage_container" "fleet" {
  for_each = var.enable_artifact_store ? var.fleets : {}

  name                  = each.key
  storage_account_id    = azurerm_storage_account.artifacts[0].id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "artifact_read_own" {
  for_each = var.enable_artifact_store ? var.fleets : {}

  scope                = azurerm_storage_container.fleet[each.key].resource_manager_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.fleet[each.key].principal_id
}

# write = true opens the fleet's OWN container only, never a shared one.
resource "azurerm_role_assignment" "artifact_write_own" {
  for_each = {
    for k, v in var.fleets : k => v
    if var.enable_artifact_store && v.artifacts != null && try(v.artifacts.write, false)
  }

  scope                = azurerm_storage_container.fleet[each.key].resource_manager_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.fleet[each.key].principal_id
}

resource "azurerm_role_assignment" "artifact_read_extra" {
  for_each = merge([
    for k, v in var.fleets : {
      for c in try(v.artifacts.read_containers, []) : "${k}/${c}" => { fleet = k, container = c }
    } if var.enable_artifact_store && v.artifacts != null
  ]...)

  scope                = azurerm_storage_container.fleet[each.value.container].resource_manager_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.fleet[each.value.fleet].principal_id
}

# =================================================================================================
# Outputs
# =================================================================================================

output "fleets" {
  description = "Per-fleet resolved attributes, for the onboarding checklist and cutover runbooks."
  value = {
    for k, v in var.fleets : k => {
      hostname           = v.hostname
      frontend_ip        = local.lb_frontend_ips[v.scope][v.frontend_ip_config]
      frontend_ip_config = v.frontend_ip_config
      scope              = v.scope
      vmss_name          = azurerm_orchestrated_virtual_machine_scale_set.fleet[k].name
      backend_pool_id    = azurerm_lb_backend_address_pool.fleet[k].id
      identity_client_id = azurerm_user_assigned_identity.fleet[k].client_id
      artifact_container = var.enable_artifact_store ? azurerm_storage_container.fleet[k].name : null
    }
  }
}

output "artifact_storage_account" {
  description = "Storage account holding fleet bootstrap artifacts."
  value       = var.enable_artifact_store ? azurerm_storage_account.artifacts[0].name : null
}
