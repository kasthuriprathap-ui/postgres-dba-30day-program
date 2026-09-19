# Day 17 — Azure Database for PostgreSQL — Flexible Server

## Objective

Provision an Azure Database for PostgreSQL **Flexible Server** (the only offering that matters now — Single Server is retired), understand its tiers, connectivity models, and how HA and read replicas work. Includes a Terraform snippet.

## Terminology bridge

| Concept | Azure Flexible Server |
|---|---|
| SQL Server license | Consumption-based; pay-as-you-go or reserved |
| Elastic pool | N/A — one server = one PG cluster |
| Windows Auth | **Microsoft Entra ID** (formerly Azure AD) authentication |
| Always On AG | Zone-redundant HA (sync standby) or same-zone HA |
| Log shipping | Read replicas (async) |
| SSMS server registration | Portal + `psql` + Azure Data Studio |
| Elastic Jobs | Azure Automation or `pg_cron` |

## Concepts

### Two products — one to use

Azure has had two PG offerings:

1. **Single Server** (retired for new deployments March 2025) — legacy multi-tenant model.
2. **Flexible Server** (use this) — VNet-integrated, tunable, HA-optional.

If a tutorial says "Azure Database for PostgreSQL" without qualifier, treat it as Flexible Server.

### Tiers

| Tier | Use case | Notes |
|---|---|---|
| **Burstable** (`B1ms`, `B2ms`, …) | Dev, low steady load | CPU credits like EC2 t-series; cheap. |
| **General Purpose** (`D2ds_v5`, …) | Most workloads | Balanced CPU/RAM/IO. |
| **Memory Optimized** (`E4ds_v5`, …) | Big working set, analytics | ~8 GB RAM per vCPU. |

Storage is decoupled: `32 GiB` to `32 TiB`, tunable IOPS.

### Connectivity

- **Public access with firewall rules** — simplest but public IP.
- **Private access (VNet integration)** — server sits in your VNet subnet. **This is the production choice.** Cannot switch after creation.
- **Private Endpoint** (PG 15+ Flexible Server) — connect over Private Link to an isolated PE without VNet integration.

### HA and read replicas

- **Zone-redundant HA** — sync standby in a different AZ within the same region. Automatic failover ~60–120 s.
- **Same-zone HA** — sync standby in the same AZ. Lower latency, no zone resilience.
- **Read replicas** — up to 5, async. Cross-region supported. Not usable as a sync HA target.

### Auth

- Native SCRAM (default).
- **Entra ID** auth for users and groups — assign the DB "Admin" identity, then `CREATE ROLE "user@contoso.com" WITH LOGIN IN ROLE azure_pg_admin;`.
- Password disable option for stricter environments.

### Extensions

`azure.extensions` allowlist controls which extensions you can `CREATE EXTENSION`. The list is generous: `pg_stat_statements`, `pgcrypto`, `postgis`, `pgvector`, `pg_cron`, `pg_partman`, `citus` (Hyperscale, another product), `hll`, `hypopg`, and more. You set `azure.extensions = 'pg_stat_statements,pgcrypto'` in server parameters before `CREATE EXTENSION`.

### Backups

Automated, geo-redundant option, PITR up to 35 days. `Long-term retention` up to 10 years is a separate feature.

## Terraform snippet

Full HA-capable Flexible Server, VNet-integrated:

```hcl
resource "azurerm_resource_group" "pg" {
  name     = "rg-${var.name}"
  location = var.region
}

# Delegated subnet for Flexible Server VNet integration
resource "azurerm_virtual_network" "pg" {
  name                = "vnet-${var.name}"
  resource_group_name = azurerm_resource_group.pg.name
  location            = azurerm_resource_group.pg.location
  address_space       = ["10.30.0.0/16"]
}

resource "azurerm_subnet" "pg" {
  name                 = "snet-pg"
  resource_group_name  = azurerm_resource_group.pg.name
  virtual_network_name = azurerm_virtual_network.pg.name
  address_prefixes     = ["10.30.1.0/24"]
  service_endpoints    = ["Microsoft.Storage"]
  delegation {
    name = "pg-fs-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "pg" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.pg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "pg" {
  name                  = "pg-dns-link"
  resource_group_name   = azurerm_resource_group.pg.name
  private_dns_zone_name = azurerm_private_dns_zone.pg.name
  virtual_network_id    = azurerm_virtual_network.pg.id
}

resource "random_password" "pg" {
  length  = 24
  special = true
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = "${var.name}-pg"
  resource_group_name = azurerm_resource_group.pg.name
  location            = azurerm_resource_group.pg.location

  version            = "16"
  sku_name           = "GP_Standard_D2ds_v5"
  storage_mb         = 32768
  storage_tier       = "P10"
  administrator_login    = "pgadmin"
  administrator_password = random_password.pg.result

  delegated_subnet_id = azurerm_subnet.pg.id
  private_dns_zone_id = azurerm_private_dns_zone.pg.id

  backup_retention_days        = 14
  geo_redundant_backup_enabled = false

  high_availability {
    mode                      = "ZoneRedundant"    # or "SameZone"
    standby_availability_zone = "2"
  }

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = true
    tenant_id                     = var.tenant_id
  }

  maintenance_window {
    day_of_week  = 0
    start_hour   = 4
    start_minute = 0
  }

  lifecycle {
    ignore_changes = [zone] # allow HA failovers to swap zones
  }
}

resource "azurerm_postgresql_flexible_server_configuration" "preload" {
  name      = "shared_preload_libraries"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "pg_stat_statements,auto_explain"
}

resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "pg_stat_statements,pgcrypto,pgvector,pg_cron"
}
```

Save the password to Key Vault (not shown) rather than leaving it in state.

## Connect

```bash
psql "host=<server>.postgres.database.azure.com \
      port=5432 dbname=postgres user=pgadmin sslmode=require"
```

Entra ID auth (after granting the identity `azure_pg_admin`):

```bash
export TOKEN=$(az account get-access-token \
  --resource-type oss-rdbms --query accessToken -o tsv)
PGPASSWORD="$TOKEN" psql \
  "host=<server>.postgres.database.azure.com port=5432 \
   user='you@contoso.com' dbname=postgres sslmode=require"
```

Then, in psql:

```sql
CREATE EXTENSION pg_stat_statements;
CREATE EXTENSION pgcrypto;
SHOW azure.extensions;
```

## Cost & sizing hints

- Burstable B1ms is enough for the lab.
- HA doubles compute cost.
- Storage IOPS scale with size — increase size or pay for provisioned IOPS on P-tiers.
- Read replicas cost the compute of the replica; storage is separate.

## Worksheet

1. Sketch the decision between **public firewall**, **VNet integration**, and **Private Endpoint**. Which do you pick for prod? Why is it hard to migrate later?  
   _Answer:_ …

2. Enable pg_cron on an existing Flexible Server. Which two settings must you change, and does either require a restart?  
   _Answer:_ …

3. Explain "Zone-redundant HA" vs a cross-region read replica: what does each protect against?  
   _Answer:_ …

4. You want passwordless auth for a service. Sketch the pieces: managed identity → role → connection.  
   _Answer:_ …

5. Bonus: what is Azure Cosmos DB for PostgreSQL and how does it fit against Flexible Server? (One paragraph.)  
   _Answer:_ …

## References

- Flexible Server docs: https://learn.microsoft.com/azure/postgresql/flexible-server/
- Extensions allowlist: https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-extensions
- Terraform provider `azurerm_postgresql_flexible_server`: https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server
- Entra ID auth: https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication
