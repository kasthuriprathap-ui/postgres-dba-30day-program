# Day 27 — The PostgreSQL Extensions Ecosystem

## Objective

Know the 15 extensions that come up most often as a PG DBA, when to reach for each, and which of them are allowed on each managed platform.

## Concepts

Extensions are the reason PG is a Swiss army knife. They ship first-class as `CREATE EXTENSION <name>;` once the extension is on the server. Managed platforms allowlist which extensions you can create — Day 15/17/19 covered how.

## The core 15

| Extension | Category | What it gives you |
|---|---|---|
| **`pg_stat_statements`** | Observability | Top statements by exec time. **Always on.** |
| **`auto_explain`** | Observability | Slow-query plans in logs. **Always on.** |
| **`pgaudit`** | Security | Structured audit stream. Day 24. |
| **`pgcrypto`** | Security | Hashes, symmetric encryption, `gen_random_uuid()`. |
| **`pg_partman`** | Ops | Automatic time / serial partitioning maintenance. |
| **`pg_repack`** | Ops | Online table rebuild without an `ACCESS EXCLUSIVE`. |
| **`pg_cron`** | Ops | In-database cron — the missing SQL Agent. |
| **`hypopg`** | Perf tuning | Hypothetical indexes for what-if planning. |
| **`pg_hint_plan`** | Perf tuning | Planner hints. Use sparingly. |
| **`postgres_fdw`** | Integration | Query a remote PG server (linked server). |
| **`file_fdw`** | Integration | Query a CSV as a table. |
| **`ltree`** | Data | Hierarchical labels (replaces `HIERARCHYID`). |
| **`hstore`** | Data | Key-value column type (predates `jsonb`; sometimes still useful). |
| **`PostGIS`** | Data | Geo types + spatial indexes. |
| **`pgvector`** | Data | Vector similarity search — LLM / semantic. |

## Highlights and gotchas

### `pg_stat_statements`

```
shared_preload_libraries = 'pg_stat_statements,auto_explain'
pg_stat_statements.track = 'ALL'
pg_stat_statements.max   = 10000
```

Restart to load the library. Then `CREATE EXTENSION` in each database you want statistics for.

### `pg_cron`

```
shared_preload_libraries = 'pg_cron'
cron.database_name       = 'postgres'   -- where cron catalog lives
```

Cron is stored **in one database**; jobs can run in *any* database on the same cluster:

```sql
SELECT cron.schedule(
  'nightly-vacuum-orders',
  '0 3 * * *',
  $$ VACUUM (ANALYZE) sales.orders $$
);
SELECT cron.schedule_in_database(
  'nightly-refresh-mv',
  '15 3 * * *',
  $$ REFRESH MATERIALIZED VIEW CONCURRENTLY reporting.mv_sales; $$,
  'shop'
);
SELECT * FROM cron.job;
```

**Managed availability**: RDS/Aurora yes (with parameter tweaks), Azure Flex yes, Cloud SQL yes.

### `pg_partman`

Automates the creation, retention, and migration of partitioned tables:

```sql
CREATE SCHEMA partman; CREATE EXTENSION pg_partman SCHEMA partman;

CREATE TABLE events (
  id bigint GENERATED ALWAYS AS IDENTITY,
  ts timestamptz NOT NULL,
  payload jsonb NOT NULL
) PARTITION BY RANGE (ts);

SELECT partman.create_parent(
  p_parent_table => 'public.events',
  p_control      => 'ts',
  p_type         => 'range',
  p_interval     => 'monthly',
  p_premake      => 6
);

-- Retention: drop partitions older than 24 months
UPDATE partman.part_config SET retention = '24 months', retention_keep_table = false
WHERE parent_table = 'public.events';

-- Have pg_cron run partman maintenance every hour
SELECT cron.schedule('partman-maint', '0 * * * *', $$ SELECT partman.run_maintenance() $$);
```

### `pgvector`

```sql
CREATE EXTENSION vector;

CREATE TABLE docs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  content text,
  embedding vector(1536)
);
CREATE INDEX ON docs USING hnsw (embedding vector_cosine_ops);

SELECT id, content
FROM docs
ORDER BY embedding <=> $1
LIMIT 5;
```

- IVFFlat and HNSW indexes. HNSW is usually the better default.
- The vector dimensionality is fixed per column.
- AlloyDB adds **ScaNN** and columnar acceleration for vector filtering.

### `postgres_fdw`

```sql
CREATE EXTENSION postgres_fdw;
CREATE SERVER reporting_srv FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'reporting.internal', dbname 'reporting', port '5432');
CREATE USER MAPPING FOR appadmin SERVER reporting_srv
  OPTIONS (user 'appadmin', password 'x');
IMPORT FOREIGN SCHEMA public FROM SERVER reporting_srv INTO reporting;
SELECT * FROM reporting.daily_sales;
```

The federated tables use predicate pushdown — reasonable performance for reporting. Not a substitute for a real replica.

### `PostGIS`

Enable, then use:

```sql
CREATE EXTENSION postgis;
CREATE TABLE stores (id serial PRIMARY KEY, geog geography(Point,4326));
CREATE INDEX ON stores USING gist (geog);
SELECT id, ST_Distance(geog, ST_MakePoint(-73.9857, 40.7484)::geography)
FROM stores ORDER BY 2 LIMIT 5;
```

Enormous ecosystem. Managed on all three clouds.

## Managed platform allowlist snapshots

Availability changes over time. Check before you assume. As of 2026:

| Extension | RDS PG | Aurora PG | Azure Flex | Cloud SQL | AlloyDB |
|---|---|---|---|---|---|
| pg_stat_statements | ✓ | ✓ | ✓ | ✓ | ✓ |
| auto_explain | ✓ | ✓ | ✓ | ✓ | ✓ |
| pgaudit | ✓ | ✓ | ✓ | ✓ | ✓ |
| pgcrypto | ✓ | ✓ | ✓ | ✓ | ✓ |
| pg_partman | ✓ | ✓ | ✓ | ✓ | ✓ |
| pg_cron | ✓ | ✓ | ✓ | ✓ | ✓ |
| pg_repack | ✓ | ✓ | ✓ | ✓ | (built-in maintenance) |
| hypopg | ✓ | ✓ | ✓ | ✓ | ✓ |
| pg_hint_plan | ~ | ~ | ✓ | ✓ | ✓ |
| postgres_fdw | ✓ | ✓ | ✓ | ✓ | ✓ |
| ltree | ✓ | ✓ | ✓ | ✓ | ✓ |
| hstore | ✓ | ✓ | ✓ | ✓ | ✓ |
| PostGIS | ✓ | ✓ | ✓ | ✓ | ✓ |
| pgvector | ✓ | ✓ | ✓ | ✓ | ✓+ScaNN |
| Citus (`citus`) | Aurora Limitless preview; RDS ✗ | Aurora Limitless (preview) | ✓ (Cosmos DB for PG) | ✗ | ✗ |

## Worksheet

1. Pick the right extension:
   a. You need a scheduler in-DB. → …  
   b. You need to know if hypothetically adding an index would help. → …  
   c. You want to shrink a 500 GB bloated table without downtime. → …  
   d. You want to store 1536-dim OpenAI embeddings. → …  
   e. You need audit logs of role changes. → …  

2. Write a `pg_cron` job that runs `ANALYZE sales.orders` every night at 03:15.  
   _Answer:_ …

3. Enable `pgvector` and design a schema for storing product descriptions + embeddings.  
   _Answer:_ …

4. Bonus: your `pg_cron` job silently stopped running. Where do you look first? What does `cron.job_run_details` show?  
   _Answer:_ …

5. Bonus: what's the difference between `postgres_fdw` and `dblink`?  
   _Answer:_ …

## References

- Extensions on postgresql.org: https://www.postgresql.org/docs/current/contrib.html
- `pgvector`: https://github.com/pgvector/pgvector
- `pg_cron`: https://github.com/citusdata/pg_cron
- `pg_partman`: https://github.com/pgpartman/pg_partman
- PostGIS: https://postgis.net/
