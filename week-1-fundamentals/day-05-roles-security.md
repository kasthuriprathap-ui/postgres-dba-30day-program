# Day 5 — Roles, Users, and Grants

## Objective

Design a clean permission model in PG: application role, migration role, read-only role, DBA role. Understand why "roles" replaces the SQL Server "login vs user" split, and how default privileges save your life.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL |
|---|---|
| Login (server principal) | Role with `LOGIN` |
| Database user (mapped to login) | The same role, granted `CONNECT` on the DB |
| Server role (`sysadmin`, `securityadmin`) | Attributes on a role (`SUPERUSER`, `CREATEROLE`, `CREATEDB`, `REPLICATION`, `BYPASSRLS`) |
| Database role (`db_owner`, `db_datareader`) | You compose it with group roles + grants |
| `sp_addrolemember` | `GRANT groupname TO membername` |
| `EXECUTE AS` / impersonation | `SET ROLE` / `SET SESSION AUTHORIZATION` |
| Row-level security | Row-Level Security (RLS) policies |
| Ownership chaining | Grants + `SECURITY DEFINER` functions |

## Concepts

### One "role" concept, many hats

A **role** is a principal. It can:

- log in (`LOGIN`) or not (a group)
- own objects
- be granted membership in other roles

`CREATE USER x` is literally shorthand for `CREATE ROLE x LOGIN`.

### Attributes vs privileges

**Attributes** are cluster-wide flags on the role: `LOGIN`, `SUPERUSER`, `CREATEDB`, `CREATEROLE`, `REPLICATION`, `BYPASSRLS`, `INHERIT`.
**Privileges** (grants) are per-object: `CONNECT` on a DB, `USAGE` on a schema, `SELECT`/`INSERT`/`UPDATE`/`DELETE`/`REFERENCES`/`TRIGGER`/`TRUNCATE` on tables, `USAGE` on sequences, `EXECUTE` on functions, etc.

To let someone connect and read tables in the `sales` schema, you need **all** of:
- `GRANT CONNECT ON DATABASE shop TO analytics_ro;`
- `GRANT USAGE ON SCHEMA sales TO analytics_ro;`
- `GRANT SELECT ON ALL TABLES IN SCHEMA sales TO analytics_ro;`

Missing any one of these and it doesn't work. This trips up almost every SQL Server DBA on day one.

### Default privileges — the missing piece

`GRANT ... ON ALL TABLES IN SCHEMA` only affects tables that **exist right now**. For future tables you need:

```sql
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA sales
  GRANT SELECT ON TABLES TO analytics_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA sales
  GRANT USAGE, SELECT ON SEQUENCES TO analytics_ro;
```

Important: `ALTER DEFAULT PRIVILEGES FOR ROLE X` only applies to objects created **by role X**. If your migration runs as `deploy`, set defaults for `deploy`, not for `app_owner`.

### `INHERIT` — group memberships

By default a role `INHERIT`s its group memberships. If `analytics_ro` is a `NOINHERIT` role, members must `SET ROLE analytics_ro` before the privileges apply. Keep `INHERIT` unless you have a specific reason.

### Row-Level Security (RLS)

```sql
ALTER TABLE sales.orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON sales.orders
  USING (tenant_id = current_setting('app.tenant_id')::bigint);

-- App sets its tenant on each connection:
SET app.tenant_id = '42';
```

Superusers and `BYPASSRLS` roles skip policies — for maintenance windows.

### Password auth in the real world

- Cluster-level: `scram-sha-256` in `password_encryption` (default in PG14+) and in `pg_hba.conf`.
- Rotate passwords; keep them out of code (secrets manager, IAM auth on cloud).
- Consider **IAM auth**: RDS/Aurora, Cloud SQL (IAM database auth), Azure AD (Microsoft Entra) auth for Flexible Server. Day 24.

## Hands-on examples

### The reference 4-role model

```sql
-- Group roles (no login)
CREATE ROLE app_owner   NOLOGIN;              -- owns schema and tables
CREATE ROLE app_rw      NOLOGIN;              -- app runtime
CREATE ROLE app_ro      NOLOGIN;              -- read-only consumers
CREATE ROLE app_deploy  NOLOGIN CREATEROLE;   -- migrations

-- Login roles that inherit those groups
CREATE ROLE svc_app     LOGIN PASSWORD 'x' IN ROLE app_rw;
CREATE ROLE svc_bi      LOGIN PASSWORD 'x' IN ROLE app_ro;
CREATE ROLE svc_deploy  LOGIN PASSWORD 'x' IN ROLE app_deploy;

-- Ownership
CREATE DATABASE shop OWNER app_owner;
\c shop
CREATE SCHEMA sales AUTHORIZATION app_owner;

-- Grants
GRANT CONNECT ON DATABASE shop TO app_rw, app_ro, app_deploy;
GRANT USAGE ON SCHEMA sales TO app_rw, app_ro;
GRANT USAGE, CREATE ON SCHEMA sales TO app_deploy;

-- Table grants (existing)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sales TO app_rw;
GRANT SELECT                        ON ALL TABLES IN SCHEMA sales TO app_ro;

-- Default privileges (future) — key step!
ALTER DEFAULT PRIVILEGES FOR ROLE app_deploy IN SCHEMA sales
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_deploy IN SCHEMA sales
  GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE app_deploy IN SCHEMA sales
  GRANT USAGE, SELECT ON SEQUENCES TO app_rw;
```

### Test it

```sql
SET ROLE svc_bi;
CREATE TABLE sales.x(id int);          -- ERROR: permission denied
SELECT * FROM sales.customers;         -- OK
RESET ROLE;

SET ROLE svc_app;
INSERT INTO sales.customers(email, full_name) VALUES ('c@x.com','Cara');  -- OK
RESET ROLE;
```

### Introspection

```sql
-- Who's a member of what?
SELECT r.rolname AS role, m.rolname AS is_member_of
FROM pg_roles r
JOIN pg_auth_members am ON am.member = r.oid
JOIN pg_roles m ON m.oid = am.roleid;

-- Grants on a schema
\dn+ sales

-- Grants on tables
\dp sales.*
```

## Cloud notes

- **RDS/Aurora**: you cannot be `SUPERUSER`. You get `rds_superuser` (a role with most privileges). Extensions are enabled via a parameter group parameter (`rds.extensions`) or `CREATE EXTENSION` if allowed.
- **Azure Flexible Server**: same idea — `azure_pg_admin` role.
- **Cloud SQL / AlloyDB**: `cloudsqlsuperuser` role. IAM database users can be created with `CREATE USER "user@example.com" WITH LOGIN`.
- All three support integrating cloud IAM: passwordless auth using short-lived tokens.

## Worksheet

1. Design a role model for a two-tenant SaaS where each tenant needs read/write to their tenant schema and BI has read-only cross-tenant. Draw the roles, memberships, and grants.  
   _Answer:_ …

2. A junior added a table `sales.audit_log` and now the BI role can't see it. Why, and what would you have done to prevent it?  
   _Answer:_ …

3. Enable RLS on `sales.customers` so users only see rows where `customers.owner_role = current_user`. Show the `CREATE POLICY`.  
   _Answer:_ …

4. What's the difference between `SET ROLE` and `SET SESSION AUTHORIZATION`? When would you use each?  
   _Answer:_ …

5. On RDS, you cannot `ALTER SYSTEM`. Where do you set `password_encryption = scram-sha-256` instead?  
   _Answer:_ …

## References

- Role attributes: https://www.postgresql.org/docs/current/role-attributes.html
- `GRANT`: https://www.postgresql.org/docs/current/sql-grant.html
- `ALTER DEFAULT PRIVILEGES`: https://www.postgresql.org/docs/current/sql-alterdefaultprivileges.html
- Row Security Policies: https://www.postgresql.org/docs/current/ddl-rowsecurity.html
