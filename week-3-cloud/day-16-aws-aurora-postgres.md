# Day 16 — Amazon Aurora PostgreSQL-Compatible

## Objective

Understand where Aurora differs from stock RDS PostgreSQL, when to prefer it, and how you'd provision an Aurora cluster (writer + reader) with Terraform.

## SQL Server → PostgreSQL bridge

There is no exact SQL Server analog to Aurora. The closest mental model is a SQL Server database on **stretched storage with a shared LUN** where compute nodes are stateless and can be added or removed instantly, and every read replica is a full participant.

## Concepts

### The single big idea

Aurora **decouples storage from compute**. There is one shared, distributed storage volume (up to 128 TiB, 6-way replicated across 3 AZs) that all cluster nodes see. The writer node ships **only** the WAL records to that storage layer; storage nodes materialize pages themselves. Reader nodes read directly from the shared storage and receive log-based invalidations from the writer.

Consequences:

- Zero-copy replicas — no `pg_basebackup`, no rebuild.
- Storage auto-grows in 10 GiB increments; you never resize.
- Reader lag is measured in milliseconds (typically < 20 ms).
- Failover promotes any reader to writer in ~30 seconds. No sync standby needed.
- Backups are continuous, restore is `RestoreDBClusterToPointInTime` and takes seconds to *start* (data is streamed on demand).

### Cluster endpoints

- **Writer endpoint** — always points at the current writer.
- **Reader endpoint** — DNS round-robin across current readers.
- **Custom endpoints** — pin a set of readers (BI vs application).
- **Instance endpoint** — a specific node (rarely used by apps).

### Feature deltas from stock RDS PostgreSQL

| Feature | Stock RDS PG | Aurora PG |
|---|---|---|
| Storage | Amazon EBS (`gp3`/`io1`) | Aurora shared distributed storage |
| Read replicas | Yes, physical streaming | Up to 15, ~ms lag, storage-native |
| HA failover time | Multi-AZ: ~60–120 s | Cluster: ~30 s |
| Global reach | Cross-region read replicas | **Global Database**: sub-second replication to secondary region |
| Serverless | No | **Aurora Serverless v2** — Aurora Capacity Units (ACU) autoscale |
| Storage cost | Provisioned + IOPS | Pay per stored GB + per I/O (or I/O-Optimized flat rate) |
| Extensions | RDS allowlist | Very similar; usually gets new ones first |
| Backup mechanism | Snapshots + WAL to S3 | Continuous, storage-native |
| Max size | 64 TiB | 128 TiB |
| Fast clones | No | Yes — near-instant, copy-on-write clones for dev/test |
| Babelfish (SQL Server T-SQL/TDS compat) | No | **Yes** (Aurora PG only) |

### When to choose Aurora over RDS PG

Choose **Aurora** when any of:

- You need 5+ read replicas or global read scale.
- You want sub-minute failover on a busy workload.
- You want fast cloning for CI or PR-per-schema testing.
- You want a serverless price/scale profile.
- You need Babelfish for lift-and-shift T-SQL workloads.

Choose **stock RDS PG** when:

- Cost matters more than the above (Aurora has a storage-per-GB and I/O cost model that can be higher).
- You need extensions Aurora doesn't yet allow.
- You need the *exact* PG binary compatibility (Aurora runs a fork with the same major-version SQL surface).

### Aurora Serverless v2

Compute in **ACUs** (roughly, 1 ACU ≈ 2 GiB RAM + proportional CPU). Set `min_capacity` and `max_capacity`; Aurora scales within seconds without connection drops. Great for intermittent workloads. You still pay for storage.

## Terraform sketch

Aurora is two resources: an `aws_rds_cluster` and one-to-many `aws_rds_cluster_instance`s. You keep the same subnet group, parameter groups (now cluster + DB parameter groups), and security group as in Day 15.

```hcl
resource "aws_rds_cluster" "this" {
  cluster_identifier      = "${var.name}-aurora"
  engine                  = "aurora-postgresql"
  engine_version          = "16.3"
  database_name           = var.db_name
  master_username         = var.master_username
  manage_master_user_password = true
  master_user_secret_kms_key_id = aws_kms_key.rds.arn

  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.rds.id]

  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.rds.arn

  backup_retention_period = 7
  preferred_backup_window = "03:00-04:00"
  deletion_protection     = true
  skip_final_snapshot     = false
  final_snapshot_identifier = "${var.name}-aurora-final-${formatdate("YYYYMMDDhhmm", timestamp())}"

  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  # Serverless v2 example (comment out for provisioned):
  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 4
  }

  engine_mode = "provisioned" # Serverless v2 uses "provisioned" mode with the scaling block
}

resource "aws_rds_cluster_instance" "writer" {
  cluster_identifier = aws_rds_cluster.this.id
  identifier         = "${var.name}-aurora-writer"
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version
  instance_class     = "db.serverless"          # or "db.r7g.large" for provisioned
  performance_insights_enabled = true
  monitoring_interval = 30
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn
}

resource "aws_rds_cluster_instance" "reader" {
  count              = 1                         # scale readers here
  cluster_identifier = aws_rds_cluster.this.id
  identifier         = "${var.name}-aurora-reader-${count.index}"
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version
  instance_class     = "db.serverless"
  performance_insights_enabled = true
  monitoring_interval = 30
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn
}
```

Reuse the KMS key, DB subnet group, security group, and monitoring IAM role from the Day 15 module.

## Hands-on

Once provisioned:

```bash
# Writer endpoint (goes to current primary)
aws rds describe-db-clusters --db-cluster-identifier pgdba-lab-aurora \
  --query 'DBClusters[0].Endpoint' --output text

# Reader endpoint (round-robins across readers)
aws rds describe-db-clusters --db-cluster-identifier pgdba-lab-aurora \
  --query 'DBClusters[0].ReaderEndpoint' --output text
```

Try a fast clone:

```bash
aws rds restore-db-cluster-to-point-in-time \
  --source-db-cluster-identifier pgdba-lab-aurora \
  --db-cluster-identifier pgdba-lab-clone \
  --restore-type copy-on-write \
  --use-latest-restorable-time
```

Failover on demand:

```bash
aws rds failover-db-cluster --db-cluster-identifier pgdba-lab-aurora
```

Watch `pg_stat_activity` from an app connected via the writer endpoint — you'll see a brief interruption, then reconnect resumes.

## Babelfish (T-SQL on Aurora PG)

Babelfish is an Aurora-only capability: the cluster listens on TDS 1433 in addition to 5432 and understands a large subset of T-SQL. It lets you point a SQL Server app at Aurora PG with minimal changes. It's not a magic wand — cursors, some builtins, and stored proc idioms differ — but for lift-and-shift, it dramatically shortens migration time. Day 26 covers migration strategies.

Enable at cluster creation with `engine_mode = "provisioned"` and set the `babelfishpg_tsql.migration_mode` parameter; port 1433 exposure is a cluster setting.

## Cost intuition

- Aurora Standard: pay for compute + storage per GB + I/Os. Great for spiky workloads.
- Aurora I/O-Optimized: higher storage + compute rate, no per-I/O charge. Better when I/O is > ~25% of your bill.
- Aurora Serverless v2: pay per ACU-hour with second-level granularity, minimum 0.5 ACU.

## Worksheet

1. When would you pick Aurora over RDS PG despite the higher storage cost? Give two workload types.  
   _Answer:_ …

2. Difference between the writer endpoint and the cluster endpoint (there's a trick here — `Endpoint` in the API is the writer/cluster endpoint).  
   _Answer:_ …

3. Sketch how you'd use fast clones to give every pull request its own DB.  
   _Answer:_ …

4. Aurora Serverless v2 min/max = 0.5/16 ACU. What does this cap? What doesn't it cap?  
   _Answer:_ …

5. Why is Babelfish only on Aurora PG and not on stock RDS PG?  
   _Answer:_ …

## References

- Aurora PG user guide: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/CHAP_PostgreSQL.html
- `aws_rds_cluster`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster
- Aurora Global Database: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database.html
- Babelfish: https://babelfishpg.org/
