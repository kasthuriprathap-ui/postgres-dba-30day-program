# Day 20 — GCP AlloyDB for PostgreSQL

## Objective

Understand AlloyDB's architecture, when it beats Cloud SQL, and how to shape a cluster with the primary + read pool pattern.

## Terminology

| Cloud SQL | AlloyDB |
|---|---|
| Instance | **Cluster** + **Instances** (primary, read pool, secondary) |
| Read replica | Read pool instance |
| Cross-region replica | Cross-region **secondary cluster** |
| Storage | Distributed, log-based (similar idea to Aurora) |
| Query Insights | Columnar engine + AlloyDB AI + Insights |

## Concepts

### The single big idea

AlloyDB decouples compute and storage. The primary instance ships WAL to a **log processing service**; storage nodes materialize pages. Read pool instances read directly from the shared storage and get log-based invalidations. This is philosophically similar to Aurora — same trade-offs and benefits.

Extras AlloyDB adds:

- **Columnar engine** — an in-memory, auto-populated columnar cache maintained by the engine, adaptive to your query patterns. Great for mixed OLTP+analytics.
- **Machine-learning-informed autopilot** — automatic vacuum tuning, memory management.
- **AlloyDB AI** — pgvector-compatible plus optimizations for embedding search.
- **Google-scale storage** — 128 TiB, replicated storage.

### Cluster shape

```
  ┌─────────────── Cluster ─────────────────┐
  │  Primary instance (write)               │
  │       └── same shared storage           │
  │  Read pool instance A (2+ read replicas)│
  │  Read pool instance B (isolated pool)   │
  └─────────────────────────────────────────┘
       │
       ├── Cross-region secondary cluster (async, DR)
```

Read pool instances are a *set* of PG nodes fronted by a single endpoint, load-balancing the read traffic. You size the pool independently of the primary.

### HA

Primary is inherently HA: the storage layer is replicated and the compute node can be replaced within seconds. Failover to a **secondary cluster** in another region gives you cross-region DR (async).

### When to prefer AlloyDB over Cloud SQL

- Analytics on your OLTP data (columnar engine).
- Very read-heavy workloads with many replicas.
- pgvector / embedding search at scale.
- Very large data volumes (multi-TB) with expected growth.

Stick with Cloud SQL when:

- Cost matters more than perf; Cloud SQL is cheaper at the low end.
- You need a specific Cloud SQL feature or extension AlloyDB doesn't have.
- Your data is small and simple.

## Provision — `gcloud`

```bash
# Create cluster (control plane)
gcloud alloydb clusters create pgdba-lab-cluster \
  --region=us-central1 \
  --network=projects/PROJECT_ID/global/networks/default \
  --initial-user=postgres \
  --password='ChangeMe!'

# Create primary compute instance
gcloud alloydb instances create pgdba-lab-primary \
  --cluster=pgdba-lab-cluster \
  --region=us-central1 \
  --instance-type=PRIMARY \
  --cpu-count=2 \
  --database-flags=shared_preload_libraries=pg_stat_statements

# Create a read pool
gcloud alloydb instances create pgdba-lab-read \
  --cluster=pgdba-lab-cluster \
  --region=us-central1 \
  --instance-type=READ_POOL \
  --read-pool-node-count=2 \
  --cpu-count=2
```

## Terraform sketch

```hcl
resource "google_alloydb_cluster" "this" {
  cluster_id  = "${var.name}-cluster"
  location    = var.region
  network_config {
    network = google_compute_network.vpc.id
  }
  initial_user {
    user     = "postgres"
    password = random_password.postgres.result
  }
  database_version = "POSTGRES_16"
  automated_backup_policy {
    location      = var.region
    backup_window = "1800s"
    enabled       = true
    weekly_schedule {
      days_of_week = ["MONDAY","TUESDAY","WEDNESDAY","THURSDAY","FRIDAY","SATURDAY","SUNDAY"]
      start_times { hours = 3 minutes = 0 seconds = 0 nanos = 0 }
    }
    quantity_based_retention {
      count = 14
    }
  }
  continuous_backup_config {
    enabled              = true
    recovery_window_days = 14
  }
}

resource "google_alloydb_instance" "primary" {
  cluster       = google_alloydb_cluster.this.name
  instance_id   = "${var.name}-primary"
  instance_type = "PRIMARY"
  machine_config { cpu_count = 2 }

  database_flags = {
    "shared_preload_libraries"     = "pg_stat_statements,google_columnar_engine"
    "log_min_duration_statement"   = "500"
  }
}

resource "google_alloydb_instance" "read_pool" {
  cluster       = google_alloydb_cluster.this.name
  instance_id   = "${var.name}-read"
  instance_type = "READ_POOL"
  read_pool_config { node_count = 2 }
  machine_config { cpu_count = 2 }
  depends_on = [google_alloydb_instance.primary]
}
```

## Try the columnar engine

```sql
-- Enabled via shared_preload_libraries above.
-- Preload columns for the columnar cache:
SELECT google_columnar_engine_add_relation('sales.orders', array['ordered_at','total','status']);

EXPLAIN (ANALYZE, BUFFERS)
SELECT status, count(*), avg(total)
FROM sales.orders
WHERE ordered_at > now() - interval '90 days'
GROUP BY status;
-- Look for "Columnar Scan" in the plan.
```

You keep normal PG on the write side and get columnar acceleration on the read side, invisibly.

## Cost intuition

- More expensive per hour than Cloud SQL.
- Storage is separate and elastic.
- Cheap fast clones (like Aurora) — good for dev.
- Cross-region secondary cluster ~doubles compute+storage cost.

## Worksheet

1. When would you pick AlloyDB over Cloud SQL, and when would you not?  
   _Answer:_ …

2. Draw the AlloyDB read pool topology. What determines read latency vs read throughput here?  
   _Answer:_ …

3. Try enabling the columnar engine locally on `sales.orders`. What indexes become less useful once you do?  
   _Answer:_ …

4. Explain how a "secondary cluster" fits into a DR plan and its RPO/RTO characteristics.  
   _Answer:_ …

5. Bonus: sketch a hybrid — Cloud SQL for OLTP + AlloyDB for reporting. What pipes the data between them?  
   _Answer:_ …

## References

- AlloyDB docs: https://cloud.google.com/alloydb/docs
- Terraform `google_alloydb_cluster`: https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/alloydb_cluster
- Columnar engine: https://cloud.google.com/alloydb/docs/columnar-engine/about
- AlloyDB AI (pgvector++): https://cloud.google.com/alloydb/ai
