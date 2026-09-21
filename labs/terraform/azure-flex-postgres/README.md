# Terraform lab — Azure Database for PostgreSQL, Flexible Server

Provisions a production-shaped Flexible Server for the Day 17 lab.

## What it builds

- (Optional) Resource group.
- (Optional) VNet + delegated subnet + private DNS zone + VNet link — the private-access baseline required for a truly VPC-integrated Flexible Server.
- `azurerm_postgresql_flexible_server` with:
  - `public_network_access_enabled = false` — private only.
  - Chosen SKU tier + storage tier + PG major version.
  - `high_availability` block driven by `high_availability_mode` (`Disabled` / `SameZone` / `ZoneRedundant`).
  - Backup retention (optional geo-redundant).
  - Custom maintenance window.
  - `authentication` block: SCRAM password + Microsoft Entra ID (Azure AD) — both are on by default.
- Random 24-char admin password (change to Key Vault for prod — see below).
- Nine `azurerm_postgresql_flexible_server_configuration` resources setting the DBA baseline (`shared_preload_libraries`, `azure.extensions`, `log_min_duration_statement`, `log_connections`, `log_disconnections`, `log_lock_waits`, `idle_in_transaction_session_timeout`, `pg_stat_statements.track`, `pgaudit.log`).

## Prerequisites

- Terraform ≥ 1.6, `az login` authenticated to the target subscription.
- Budget alert configured on the subscription.
- If enabling Entra ID auth: the tenant ID (`az account show --query tenantId -o tsv`).
- If reusing existing network: an already-delegated subnet and matching private DNS zone.

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
# edit: location, tenant_id (if using AAD), sku_name, etc.

terraform init
terraform plan  -out=tfplan
terraform apply tfplan
```

Provisioning ~ 8–15 min. HA (`ZoneRedundant`) adds a few more.

## Get the endpoint and connect

The server is **private** — no public IP. Connect from a VM/Bastion in the same VNet or via VPN/Private Endpoint.

```bash
export FQDN=$(terraform output -raw fqdn)
export USER=$(terraform output -raw admin_username)
export PW=$(terraform output -raw admin_password)     # tfstate has this — see Key Vault note

# From inside the VNet (Azure Bastion → VM → this command):
PGPASSWORD="$PW" psql "host=$FQDN port=5432 dbname=postgres user=$USER sslmode=require"
```

### Microsoft Entra ID authentication

Once, from an admin session:

```sql
-- Grant an Entra user (or group) DBA privileges
CREATE ROLE "you@contoso.com" WITH LOGIN IN ROLE azure_pg_admin;
```

Every connection:

```bash
TOKEN=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)
PGPASSWORD="$TOKEN" psql "host=$FQDN port=5432 user='you@contoso.com' dbname=postgres sslmode=require"
```

Tokens are valid ~1 h.

## Tier picker cheat sheet

| Workload | SKU | HA supported? |
|---|---|---|
| Dev/sandbox | `B_Standard_B1ms` | No (Burstable) |
| Small OLTP | `GP_Standard_D2ds_v5` | Yes |
| Medium OLTP | `GP_Standard_D4ds_v5` | Yes |
| Memory-hungry | `MO_Standard_E4ds_v5` | Yes |

Attempting HA on a Burstable SKU will fail at plan/apply. The variable's default is `Disabled` for that reason.

## Turning HA on

```bash
terraform apply -var high_availability_mode=ZoneRedundant -var standby_availability_zone=2
```

Flexible Server will provision the standby and swap in ~15 minutes. Failover is automatic thereafter; test it with `az postgres flexible-server restart --failover Forced --name … --resource-group …`.

## Adding a read replica (Day 22)

Add to `main.tf`:

```hcl
resource "azurerm_postgresql_flexible_server" "replica" {
  name                          = "${var.name}-pg-ro"
  resource_group_name           = local.rg_name
  location                      = local.rg_location
  create_mode                   = "Replica"
  source_server_id              = azurerm_postgresql_flexible_server.this.id
  sku_name                      = var.sku_name
  version                       = azurerm_postgresql_flexible_server.this.version
  storage_mb                    = azurerm_postgresql_flexible_server.this.storage_mb
  delegated_subnet_id           = local.delegated_subnet_id
  private_dns_zone_id           = local.private_dns_zone_id
  public_network_access_enabled = false
  backup_retention_days         = 7
}
```

Read replicas are async; promotion is one-way.

## Production hygiene checklist

- [ ] Move `admin_password` out of Terraform state:
      - Use `azurerm_key_vault_secret` + reference in the app config, and set the server password via `AZ CLI` post-provision, **or**
      - Rotate the admin password after apply and delete the value from state.
- [ ] `azure_ad_auth_enabled = true` + `password_auth_enabled = false` once your apps are on Entra ID.
- [ ] Add a Private Endpoint for cross-VNet access if needed (extra resource; not in this module).
- [ ] `geo_redundant_backup = true` for prod that needs cross-region DR.
- [ ] Diagnostic setting → Log Analytics workspace for `PostgreSQLLogs` and metrics.

## Destroy

```bash
terraform destroy -auto-approve
```

If the resource group was created by this module, it will be deleted with everything inside. If you passed an existing RG name, only the flexible server, DNS zone, and VNet resources this module created will be removed.

## Cost note

Rough monthly ranges (public list price, us-east; check current pricing):
- `B_Standard_B1ms`, 32 GB, single-AZ: ~$15–20
- `GP_Standard_D2ds_v5`, 32 GB, single-AZ: ~$120–140
- Same with `ZoneRedundant` HA: ~$240–280
- Geo-redundant backup: extra ~$0.10/GB-month

Terraform destroy releases everything.
