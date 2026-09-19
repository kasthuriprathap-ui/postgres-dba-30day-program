# Day 24 — Security Hardening

## Objective

Apply a defensible security baseline to any PostgreSQL deployment: TLS, IAM auth, secrets, network isolation, auditing (`pgaudit`), least privilege, and RLS.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL |
|---|---|
| TDE (Transparent Data Encryption) | Storage-layer encryption on cloud (KMS-managed) + `pgcrypto` for column-level |
| Always Encrypted | Client-side encryption via app or `pgcrypto` |
| Windows Auth | IAM/Entra/Cloud IAM DB auth |
| SQL Server Audit | `pgaudit` extension |
| SQL Server sensitive data classification | Third-party or DIY via labels |
| Contained databases | Not analogous |
| Extended Protection for Auth | SSL + SCRAM-SHA-256 |
| Login lockout | `pg_hba.conf` deny + external policy |
| Row-level security | Native RLS (Day 5) |
| Dynamic Data Masking | Views or custom functions; some clouds have SQL masks (limited) |

## Concepts

### The 10-item baseline

1. **TLS in transit.** SCRAM-SHA-256 for passwords. Server presents cert; client verifies.
2. **Encryption at rest.** Storage-level, KMS-managed key. Rotate.
3. **Network isolation.** Private endpoint / VPC / VNet only. No `0.0.0.0/0`.
4. **Least privilege.** Multiple roles (Day 5). No app connects as superuser.
5. **Managed / rotated secrets.** Secrets Manager / Key Vault / Secret Manager. Or IAM-DB auth.
6. **Audit logging.** `pgaudit` for DDL, role changes, read of sensitive tables.
7. **`log_statement`, `log_connections`, `log_disconnections`.** Feed to central logs.
8. **`idle_in_transaction_session_timeout`, `statement_timeout`, `lock_timeout`.** Availability guardrails.
9. **RLS** on multi-tenant tables. Deny bypass with `NO INHERIT`.
10. **DR + backups tested.** Encrypted backups; separate account/subscription/project.

### TLS

Force it. On each cloud:

- **RDS**: parameter `rds.force_ssl = 1`. Download the RDS CA bundle; connect with `sslmode=verify-full sslrootcert=/path/rds-combined-ca-bundle.pem`.
- **Azure Flex**: SSL is enforced by default. Download the DigiCert Global Root G2 as fallback.
- **Cloud SQL**: `require_ssl = true` in `ip_configuration`, or use the Auth Proxy (SSL bundled).

### `pgaudit`

Extension that logs a structured stream of "who did what to what."

```sql
CREATE EXTENSION pgaudit;
ALTER SYSTEM SET pgaudit.log = 'ddl, role, misc';
ALTER SYSTEM SET pgaudit.log_relation = on;
SELECT pg_reload_conf();
```

Common categories: `read, write, function, role, ddl, misc, all`.
Object-level (only for specific tables):

```sql
CREATE ROLE audit_reader;
GRANT SELECT ON sales.customers TO audit_reader;
ALTER TABLE sales.customers SET (audit.roles = 'audit_reader');   -- pattern; pgaudit uses pgaudit.role
```

### IAM database auth

- **RDS/Aurora**: `GRANT rds_iam TO user;` — token via `aws rds generate-db-auth-token`.
- **Azure Flexible Server**: `CREATE ROLE "u@tenant" WITH LOGIN;` + `GRANT azure_pg_admin TO ...;` or role-based grants. Token via `az account get-access-token --resource-type oss-rdbms`.
- **Cloud SQL / AlloyDB**: `CREATE USER "u@project.iam" WITH LOGIN;` + `roles/cloudsql.instanceUser`. Auth Proxy handles the token.

### Secrets

Don't put passwords in Terraform state where you can help it. Two patterns:

1. **Cloud-managed master password**: RDS's `manage_master_user_password = true`, Azure Key Vault reference, Cloud SQL secret sync.
2. **External secret manager**: HashiCorp Vault. Roles have short-lived credentials, rotated per-connection with the `database` secret engine.

For app credentials (non-master), use ephemeral secrets from Vault or short-lived IAM tokens. Rotate any human passwords quarterly.

### Row-level security in production

- Enable RLS on tables with tenant/customer scope.
- Set the tenant on every connection via `SET LOCAL app.tenant_id = ...;` from your app.
- Test with a non-superuser account. Superusers bypass RLS by default.
- Add `FORCE ROW LEVEL SECURITY` on the table for owners too (otherwise the owner bypasses).

```sql
ALTER TABLE sales.orders FORCE ROW LEVEL SECURITY;
```

### Data masking / column-level encryption

- **View-based**: expose views with masked columns; grant only on the view.
- **`pgcrypto`**: `pgp_sym_encrypt(...)` and friends. Keys managed outside the DB.
- **KMS-backed**: envelope-encrypt in the app, decrypt in the app. Keeps ciphertext out of backups.

### CIS-like checklist

- [ ] `password_encryption = scram-sha-256`
- [ ] `rds.force_ssl` / equivalent = 1
- [ ] No public IP or public firewall `0.0.0.0/0`
- [ ] Automated backups on; PITR configured
- [ ] Deletion protection on
- [ ] Master password not in Terraform plaintext / state
- [ ] All app roles limited to their schemas
- [ ] `pgaudit` on for DDL + role changes
- [ ] `log_connections`, `log_disconnections`, `log_lock_waits`
- [ ] Extensions restricted to the allowlist you approve
- [ ] Cross-account/subscription/project separation for prod vs non-prod

## Hands-on

### Enforce SSL on your lab

RDS: add to your Terraform parameter group `rds.force_ssl = 1`. Verify:

```sql
SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid();
```

### Turn on pgaudit

Add to the parameter group/flags:

```
shared_preload_libraries = 'pg_stat_statements,auto_explain,pgaudit'
pgaudit.log             = 'ddl, role, write'
pgaudit.log_catalog     = 'off'
pgaudit.log_relation    = 'on'
```

Reboot the instance. Then:

```sql
CREATE EXTENSION pgaudit;
```

Do some DDL:

```sql
CREATE TABLE sensitive(x int);
DROP TABLE sensitive;
```

Look at PG logs — you'll see `AUDIT: SESSION, ..., DDL, CREATE TABLE, ...`.

### Enforce a `search_path` for owners

Rogue schemas can trojan-horse a superuser. Set an explicit `search_path` and mark the owner as `NOINHERIT`:

```sql
ALTER ROLE app_owner SET search_path = pg_catalog, sales, public;
```

### Least-privilege template

```sql
-- App runtime role
CREATE ROLE svc_app LOGIN PASSWORD '<from Vault>' IN ROLE app_rw;
-- Read-only role for BI
CREATE ROLE svc_bi LOGIN PASSWORD '<from Vault>' IN ROLE app_ro;
-- Rotator role (short-lived tokens for humans)
CREATE ROLE rotator NOLOGIN;
GRANT app_rw TO rotator;
```

Rotate `svc_app` credentials weekly with Vault's `database/roles`.

## Cloud specifics

- **RDS**: `manage_master_user_password`, IAM auth per user, `pgaudit` on parameter group, KMS for storage.
- **Azure Flex**: **Entra ID** auth + `azure_pg_admin` role, private DNS zone for private endpoint, `pgaudit` via `azure.extensions`.
- **Cloud SQL / AlloyDB**: IAM DB auth + Cloud SQL Auth Proxy, `cloudsql.iam_authentication = on`, `pgaudit` via `cloudsql.enable_pgaudit`.

## Worksheet

1. Take one of your existing terraform modules and add a resource that stores the master password in Secrets Manager (not managed by RDS). Sketch the diff.  
   _Answer:_ …

2. Write the pgaudit config for a bank: audit all DDL, role changes, and reads on `sales.customers.ssn`.  
   _Answer:_ …

3. Explain FORCE ROW LEVEL SECURITY vs plain RLS.  
   _Answer:_ …

4. A dev has been given `SUPERUSER` on prod "just this once." Why is it dangerous even after they release it? Cleanup steps?  
   _Answer:_ …

5. Bonus: propose a rotation strategy for `pgcrypto` symmetric keys that doesn't require reencrypting the entire ciphertext at rotation time.  
   _Answer:_ …

## References

- PostgreSQL security: https://www.postgresql.org/docs/current/security.html
- `pgaudit`: https://www.pgaudit.org/
- Row Security Policies: https://www.postgresql.org/docs/current/ddl-rowsecurity.html
- HashiCorp Vault database secrets: https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql
