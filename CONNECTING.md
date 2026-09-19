# Connecting to PostgreSQL — Tool & Recipe Guide

The single reference for "how do I actually get in?" — for the local Docker lab and for managed PostgreSQL on AWS, Azure, and GCP.

The daily lessons cover this piece-by-piece; this doc consolidates every recipe so you can flip to it during on-call.

---

## 1. Which tool?

| Tool | When to use | SQL Server analog |
|---|---|---|
| **`psql`** | Always. Production bastions, CI, runbooks, this whole program. Master it first. | `sqlcmd` |
| **DBeaver Community** (free) | Daily driver GUI. Multi-DB — you can keep SQL Server and PG in one workspace. Best middle ground for former SSMS users. | SSMS-ish |
| **pgAdmin 4** (free) | Official PG GUI. Good visual `EXPLAIN` graphs. Web UI, feels heavier than DBeaver. | SSMS Object Explorer |
| **Azure Data Studio** + PostgreSQL extension | If you already live in ADS for SQL Server; single UI for both. | Itself |
| **DataGrip** (paid, JetBrains) | If you write more SQL than you click. Best autocomplete/refactor in class. | Redgate SQL Prompt-ish |
| **VS Code / Kiro** + PG extension | Casual queries while already in the editor. Not a replacement for the above. | — |

**Recommendation for this program:** `psql` **plus** DBeaver. Muscle memory in `psql` pays every day. DBeaver covers "show me the table graph, drag a column" cases.

## 2. Install once

```bash
# macOS (Homebrew already installed for you)
brew install libpq                              # gives you psql without a local server
brew link --force libpq                         # put psql on PATH
brew install --cask dbeaver-community           # GUI

# Optional cloud CLIs (install what you'll use)
brew install --cask google-cloud-sdk            # gcloud
brew install azure-cli
brew install awscli
```

Why `libpq` and not `postgresql`? Because the Docker container is your local server. `libpq` gives you the client without a second server on your Mac.

## 3. Connection strings — two forms you'll see

```
# URI form
postgresql://user:password@host:5432/dbname?sslmode=require

# key=value form (also accepted by psql)
"host=… port=5432 dbname=… user=… password=… sslmode=require"
```

Environment variables act as defaults: `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSSLMODE`, `PGSERVICE`, `PGAPPNAME`.

## 4. Quality-of-life setup you should do once

### `~/.pg_service.conf` — named connection profiles

Put connection details in one place and refer to them by name.

```ini
# ~/.pg_service.conf

[shop-local]
host=localhost
port=5432
dbname=shop
user=svc_app

[rds-lab]
host=pgdba-lab.abcdef.us-east-1.rds.amazonaws.com
port=5432
dbname=appdb
user=appadmin
sslmode=require

[azure-lab]
host=pgdba-lab-pg.postgres.database.azure.com
port=5432
dbname=postgres
user=pgadmin
sslmode=require

[gcp-lab-via-proxy]
host=127.0.0.1
port=5432
dbname=appdb
user=postgres
sslmode=disable
```

Now:

```bash
psql service=rds-lab
psql service=shop-local
```

### `~/.pgpass` — passwords out of shell history

```
# ~/.pgpass  — MUST be chmod 0600
# hostname:port:database:username:password
pgdba-lab.abcdef.us-east-1.rds.amazonaws.com:5432:*:appadmin:<from Secrets Manager>
localhost:5432:*:svc_app:svc_app_pw
localhost:5432:*:postgres:postgres
```

```bash
chmod 0600 ~/.pgpass
```

Combined, `psql service=rds-lab` connects with zero extra flags — endpoint, port, user, DB, password, TLS, all resolved.

### A production-ready `~/.psqlrc`

```
\set QUIET 1
\pset border 2
\pset null '¤'
\set COMP_KEYWORD_CASE upper
\set HISTFILE ~/.psql_history- :DBNAME
\set HISTSIZE 5000
\set VERBOSITY verbose
\timing on
\x auto
\set PROMPT1 '%[%033[1;32m%]%n@%m:%>%[%033[0m%] %[%033[1;33m%]%~%[%033[0m%]%R%# '
\set PROMPT2 '  … %R> '
\unset QUIET
```

---

## 5. Local Docker lab

The compose file is at `labs/docker-compose-local-postgres.yml`.

```bash
cd labs/
docker compose -f docker-compose-local-postgres.yml up -d

# Wait ~5 s, then load the sample schema
docker exec -i pgdba psql -U postgres -d postgres < sample-schema.sql
```

### Connect from your Mac

```bash
# Superuser (for admin tasks)
psql "postgresql://postgres:postgres@localhost:5432/postgres"

# Application role (after loading the sample schema)
psql "postgresql://svc_app:svc_app_pw@localhost:5432/shop"

# Read-only BI role
psql "postgresql://svc_bi:svc_bi_pw@localhost:5432/shop"

# Or via the service file:
psql service=shop-local
```

### From inside the container (no client install needed)

```bash
docker exec -it pgdba psql -U postgres
```

### DBeaver

- New Connection → PostgreSQL
- Host: `localhost`, Port: `5432`, Database: `shop`
- User: `svc_app`, Password: `svc_app_pw`
- Test connection → Save

---

## 6. AWS RDS (Day 15 lab)

The Terraform module sets `publicly_accessible = false`, so you need one of three paths.

### Where to find the password

```bash
export ENDPOINT=$(terraform -chdir=labs/terraform/rds-postgres output -raw rds_endpoint)
export SECRET_ARN=$(terraform -chdir=labs/terraform/rds-postgres output -raw master_password_secret_arn)

export PGPASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query SecretString --output text | jq -r .password)

echo "Endpoint: $ENDPOINT"
```

### Path A — bastion / jump box in the same VPC

1. In `terraform.tfvars`, put the bastion's SG in `allowed_security_group_ids`, or its CIDR in `allowed_cidrs`. Re-apply.
2. `ssh ec2-user@bastion`, then:

```bash
psql "host=$ENDPOINT port=5432 dbname=appdb user=appadmin sslmode=require"
```

Consider forwarding your local port through SSH so DBeaver on your Mac talks to RDS:

```bash
ssh -N -L 5432:$ENDPOINT:5432 ec2-user@bastion
# Then locally:
psql "host=127.0.0.1 port=5432 dbname=appdb user=appadmin sslmode=require"
```

### Path B — Session Manager port-forwarding (no SSH keys, no public bastion)

Requires a bastion instance with the SSM agent (default on Amazon Linux 2 / 2023) and an IAM role that includes `AmazonSSMManagedInstanceCore`.

```bash
aws ssm start-session \
  --target i-0123456789abcdef0 \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$ENDPOINT,portNumber=5432,localPortNumber=5432"

# In another terminal, on your laptop:
psql "host=127.0.0.1 port=5432 dbname=appdb user=appadmin sslmode=require"
```

Point DBeaver at `127.0.0.1:5432` and it works too.

### Path C — Public access (labs only, not prod)

```bash
# Get your public IP
curl ifconfig.me

# In terraform.tfvars:
#   allowed_cidrs = ["A.B.C.D/32"]
# Also flip publicly_accessible = true in the module.
terraform apply
```

Then connect directly. **Turn off before you sign off** — public 5432 is a magnet.

### IAM authentication (no stored password)

Once, from an admin session:

```sql
CREATE ROLE svc_iam LOGIN;
GRANT rds_iam TO svc_iam;
GRANT CONNECT ON DATABASE appdb TO svc_iam;
```

Every connection uses a short-lived token:

```bash
TOKEN=$(aws rds generate-db-auth-token \
  --hostname "$ENDPOINT" --port 5432 \
  --username svc_iam --region "$AWS_REGION")

PGPASSWORD="$TOKEN" psql \
  "host=$ENDPOINT port=5432 dbname=appdb user=svc_iam sslmode=require"
```

Tokens are valid ~15 min; regenerate on reconnect.

### SSL certificate for `verify-full`

```bash
mkdir -p ~/.postgresql
curl -o ~/.postgresql/rds-global-bundle.pem \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

psql "host=$ENDPOINT port=5432 dbname=appdb user=appadmin \
      sslmode=verify-full sslrootcert=$HOME/.postgresql/rds-global-bundle.pem"
```

---

## 7. AWS Aurora PostgreSQL (Day 16)

Same tools; two endpoints to know.

```bash
# Writer endpoint (goes to current primary)
aws rds describe-db-clusters --db-cluster-identifier pgdba-lab-aurora \
  --query 'DBClusters[0].Endpoint' --output text

# Reader endpoint (round-robin across readers)
aws rds describe-db-clusters --db-cluster-identifier pgdba-lab-aurora \
  --query 'DBClusters[0].ReaderEndpoint' --output text
```

Point writes at the writer endpoint; point BI/read replicas at the reader endpoint. Everything else — bastion, SSM, IAM auth — is identical to RDS.

Babelfish clusters also listen on TDS **1433** — you can connect with `sqlcmd` or SSMS as if it were SQL Server. That's the whole point of Babelfish.

---

## 8. Azure Database for PostgreSQL — Flexible Server (Day 17)

### Path A — Public access (dev/test)

Add your IP as a firewall rule in the portal, then:

```bash
psql "host=<server>.postgres.database.azure.com port=5432 \
      dbname=postgres user=pgadmin sslmode=require"
```

### Path B — Private access (VNet-integrated, production shape)

You cannot reach the server from your laptop. Options:

- **Azure Bastion** to a VM in the VNet → `psql` from there.
- **Point-to-Site VPN** for developer access from your laptop.
- **Private Endpoint** across VNets.
- **Azure Cloud Shell** — a small VM Microsoft gives you in-portal; connect to the FQDN if it's on the same VNet or has firewall access.

### Microsoft Entra ID authentication (passwordless)

Once (from an admin session):

```sql
-- Grant Entra login access
CREATE ROLE "you@contoso.com" WITH LOGIN IN ROLE azure_pg_admin;
```

Every connection:

```bash
TOKEN=$(az account get-access-token \
          --resource-type oss-rdbms \
          --query accessToken -o tsv)

PGPASSWORD="$TOKEN" psql \
  "host=<server>.postgres.database.azure.com port=5432 \
   user='you@contoso.com' dbname=postgres sslmode=require"
```

Token lifetime is ~1 hour; regenerate on reconnect.

### SSL certificate

Flexible Server enforces TLS. `sslmode=require` is usually enough. For `verify-full`:

```bash
mkdir -p ~/.postgresql
curl -o ~/.postgresql/azure-root.pem \
  https://cacerts.digicert.com/DigiCertGlobalRootG2.crt.pem

psql "host=<server>.postgres.database.azure.com port=5432 \
      dbname=postgres user=pgadmin \
      sslmode=verify-full sslrootcert=$HOME/.postgresql/azure-root.pem"
```

---

## 9. GCP Cloud SQL and AlloyDB (Days 19–20)

The idiomatic way is the **Cloud SQL Auth Proxy** — a small binary that authenticates via your `gcloud` identity and tunnels to `127.0.0.1:5432`. It handles SSL. Your `psql`/DBeaver/apps talk to a local port and know nothing about the cloud.

### Install

```bash
gcloud components install cloud-sql-proxy
# or
brew install cloud-sql-proxy
```

### Cloud SQL — password auth

```bash
# Leave this running in one terminal
cloud-sql-proxy PROJECT_ID:REGION:pgdba-lab-pg

# In another terminal
psql "host=127.0.0.1 port=5432 dbname=appdb user=postgres sslmode=disable"
# SSL is provided by the proxy — the client-side `sslmode=disable` is intentional.
```

### Cloud SQL — IAM DB auth (passwordless)

```bash
# One-time: create the IAM user in the DB
gcloud sql users create you@example.com \
  --instance=pgdba-lab-pg --type=CLOUD_IAM_USER

# Grant the instance user IAM role
gcloud sql instances add-iam-policy-binding pgdba-lab-pg \
  --member=user:you@example.com \
  --role=roles/cloudsql.instanceUser

# Proxy with automatic IAM auth
cloud-sql-proxy --auto-iam-authn PROJECT_ID:REGION:pgdba-lab-pg

# Connect
psql "host=127.0.0.1 port=5432 dbname=appdb user=you@example.com sslmode=disable"
```

### AlloyDB

Same pattern, different binary:

```bash
gcloud components install alloydb-auth-proxy

alloydb-auth-proxy \
  "projects/PROJECT_ID/locations/REGION/clusters/pgdba-lab-cluster/instances/pgdba-lab-primary"

psql "host=127.0.0.1 port=5432 dbname=postgres user=postgres sslmode=disable"
```

### Public IP + authorized networks (only if you must)

Enable public IP on the instance, add your `curl ifconfig.me/32` to authorized networks, then:

```bash
psql "host=<public-ip> port=5432 dbname=appdb user=postgres sslmode=require"
```

Turn it off when done.

---

## 10. GUI connection recipes

### DBeaver — Local Docker

- Type: PostgreSQL
- Host: `localhost`, Port: `5432`
- Database: `shop`
- User: `svc_app`, Password: `svc_app_pw`
- **Driver Properties**: nothing to change

### DBeaver — RDS (over SSH tunnel or SSM port forward)

- Type: PostgreSQL
- Host: `127.0.0.1` (because of the tunnel), Port: `5432`
- Database: `appdb`
- User: `appadmin`, Password: paste from Secrets Manager
- **SSL tab**: SSL mode = `require`
- **Driver Properties**: `sslmode=require`

### DBeaver — Cloud SQL via Auth Proxy

- Start the proxy first: `cloud-sql-proxy PROJECT:REGION:INSTANCE`
- Host: `127.0.0.1`, Port: `5432`
- Database: `appdb`, User: `postgres` (or IAM user)
- SSL mode: `disable` (proxy handles SSL)

### DBeaver — Azure Flexible Server (public firewall)

- Host: `<server>.postgres.database.azure.com`, Port: `5432`
- Database: `postgres`, User: `pgadmin`
- SSL mode: `require`
- Password authentication only unless you're passing an Entra token as the password

### pgAdmin 4

- File → Add New Server
- **General**: name it (e.g., `rds-lab`)
- **Connection**: same fields as DBeaver
- **SSL**: SSL mode `require`; optional root cert path

---

## 11. Sanity checks after every connection

Paste these into psql on the first connect. They confirm you're really talking to what you think.

```sql
-- Where am I?
SELECT current_database(), current_user, current_schema(),
       inet_server_addr(), inet_server_port(), version();

-- Is my session actually encrypted?
SELECT ssl, version, cipher
FROM pg_stat_ssl WHERE pid = pg_backend_pid();

-- What did the DBA set for me?
SELECT name, setting
FROM pg_settings
WHERE name IN ('shared_preload_libraries','log_min_duration_statement',
               'idle_in_transaction_session_timeout','statement_timeout',
               'rds.force_ssl');

-- Who else is connected right now?
SELECT pid, usename, application_name, client_addr, state,
       now() - state_change AS state_age
FROM pg_stat_activity
WHERE backend_type = 'client backend'
ORDER BY state_change;
```

---

## 12. Troubleshooting quick-lookup

| Symptom | Most likely cause | First fix |
|---|---|---|
| `Connection refused` | Nothing listening / wrong port | Check `pg_ctl status`, `docker ps`, security group |
| `no pg_hba.conf entry for host` | Firewall/hba rejected you | Add your CIDR / SG; or wrong DB name in the entry |
| `FATAL: password authentication failed` | Wrong password or wrong `user@host` split | Refetch from secret; check for stale `.pgpass` |
| `FATAL: sorry, too many clients already` | Hit `max_connections` | Add PgBouncer or bump instance size |
| `SSL error: certificate verify failed` | Missing/wrong root cert with `verify-full` | Use `sslmode=require`, or point at correct root PEM |
| Hang, no error | Wrong SG / firewall, packets black-holed | `nc -vz host 5432` to test reachability |
| RDS IAM: `PAM authentication failed` | Token expired (>15 min) or role missing `rds_iam` | Regen token; `GRANT rds_iam TO ...` |
| Cloud SQL proxy: `permission denied` | IAM principal missing `roles/cloudsql.client` | Grant it and retry |
| Azure Entra: `password authentication failed` | You passed a stale AAD token | `az account get-access-token` again |

---

## 13. TL;DR

- **Learn `psql`.** Everything else assumes it.
- **Never open port 5432 to the internet in prod.** Use bastion + SSH tunnel, SSM port forwarding, Cloud SQL Auth Proxy, or Private Endpoint.
- **Prefer IAM auth** over stored passwords wherever the platform supports it — RDS `rds_iam`, Azure Entra ID, Cloud SQL IAM.
- **Use `~/.pg_service.conf` + `~/.pgpass`** for muscle-memory-fast reconnects.
- **Always** run the "sanity checks" block on your first connection to a new server. It saves incidents.
