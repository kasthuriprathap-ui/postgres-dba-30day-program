# Day 4 — Data Types & Schemas

## Objective

Choose the right PG data type for each SQL Server type you know, understand `search_path`, and use schemas to model your workload.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL | Note |
|---|---|---|
| `INT`, `BIGINT`, `SMALLINT`, `TINYINT` | `integer`, `bigint`, `smallint` | No `tinyint`; use `smallint` or `CHECK (col BETWEEN 0 AND 255)`. |
| `BIT` | `boolean` | Real true/false, not 0/1. |
| `DECIMAL(p,s)`, `NUMERIC(p,s)` | `numeric(p,s)` | Same. |
| `MONEY`, `SMALLMONEY` | `numeric(19,4)` | Avoid `money` type — locale-sensitive. |
| `FLOAT`, `REAL` | `double precision`, `real` | Same. |
| `CHAR(n)`, `NCHAR(n)` | `char(n)` | Blank-padded; rarely needed. |
| `VARCHAR(n)`, `NVARCHAR(n)` | `varchar(n)` or `text` | `text` and `varchar` are identical in perf; prefer `text` unless you truly need length limits. All PG text is Unicode by default (server encoding). |
| `VARCHAR(MAX)`, `NVARCHAR(MAX)` | `text` | Unlimited. |
| `DATE` | `date` | Same. |
| `TIME` | `time [without time zone]` | |
| `DATETIME`, `DATETIME2` | `timestamp` | |
| `DATETIMEOFFSET` | `timestamptz` | **Use this by default.** Stored as UTC; converted on I/O per `TimeZone` setting. |
| `UNIQUEIDENTIFIER` | `uuid` | `gen_random_uuid()` built into PG 13+. |
| `VARBINARY(MAX)`, `IMAGE` | `bytea` | Or use large objects for streaming. |
| `XML` | `xml` | Same. |
| `HIERARCHYID` | `ltree` extension | |
| `GEOGRAPHY`, `GEOMETRY` | PostGIS (`geometry`, `geography`) | Day 27. |
| `SQL_VARIANT` | none — redesign | |
| `ROWVERSION` / `TIMESTAMP` | `xmin` (system) or manual `version` column | PG's own `timestamp` is not the same as SQL Server's `timestamp` — big trap. |
| Table-valued parameter | `unnest()` of arrays, or `jsonb`, or temp table | |

PG also has **native types SQL Server lacks** that you should use:

- `jsonb` — indexable JSON. Default JSON type. `json` (non-b) is text-with-validation.
- `array` — any type can be an array: `int[]`, `text[]`, etc.
- `range` types — `int4range`, `tstzrange`, exclusion constraints on overlap.
- `inet`, `cidr`, `macaddr` — network types.
- `enum` — real enumerated types.
- Composite types — row-shaped types you define.

## Concepts

### Schemas and `search_path`

Every session has a `search_path`, an ordered list of schemas Postgres consults to resolve unqualified names.

```sql
SHOW search_path;                     -- default: "$user", public
SELECT * FROM orders;                 -- looks in $user, then public
SET search_path TO sales, public;     -- for the rest of the session
```

Persist per-role or per-database:

```sql
ALTER ROLE app_user SET search_path = sales, public;
ALTER DATABASE shop SET search_path = sales, public;
```

**Multi-tenant tip**: give each tenant a schema, then set `search_path` on connection. Same tables and queries, isolated data.

### Schemas as a modularization tool

Typical layouts:

- **App**: `public` for app tables, `audit` for triggers/history, `reporting` for read-only views.
- **Multi-team**: `team_a`, `team_b`, each with its own tables.
- **Multi-tenant**: `tenant_<id>` per customer.

Ownership: `ALTER SCHEMA name OWNER TO role;` — owner can create in it. Grant `USAGE` on the schema and `SELECT`/`INSERT` on tables to consumers.

### `IDENTITY` and sequences

Prefer `IDENTITY` on PG 10+:

```sql
CREATE TABLE sales.orders (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL,
  total       numeric(12,2) NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
```

Legacy `SERIAL` / `BIGSERIAL` still works but is a macro over a sequence and has quirks around `OWNED BY`.

### `jsonb` — use it, but not for everything

```sql
CREATE TABLE events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payload jsonb NOT NULL,
  ts timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON events USING gin (payload jsonb_path_ops);

-- Query
SELECT payload->>'user_id' AS uid, count(*)
FROM events
WHERE payload @> '{"kind":"purchase"}'::jsonb
GROUP BY 1;
```

Rule of thumb: relational for known fields, `jsonb` for extensible/rare attributes.

### Time zones — the one thing to internalize

- `timestamp` is naive. It stores what you gave it. Don't use it unless you truly mean "local wall time, no time zone."
- `timestamptz` stores UTC internally and applies the session's `TimeZone` on display. **Default to `timestamptz` for everything you would use `datetime2` for in SQL Server.**

## Hands-on examples

```sql
\c shop
CREATE SCHEMA sales;
CREATE TABLE sales.customers (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email       text NOT NULL UNIQUE,
  full_name   text NOT NULL,
  attributes  jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sales.orders (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES sales.customers(id),
  total       numeric(12,2) NOT NULL CHECK (total >= 0),
  tags        text[] NOT NULL DEFAULT '{}',
  ordered_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO sales.customers(email, full_name, attributes) VALUES
  ('a@x.com','Alice', '{"tier":"gold","prefs":{"marketing":true}}'),
  ('b@x.com','Bob',   '{"tier":"silver"}');

INSERT INTO sales.orders(customer_id, total, tags) VALUES
  (1, 99.90, ARRAY['first','discount']),
  (1, 12.00, ARRAY['reorder']),
  (2,  5.00, ARRAY['reorder']);

-- Array containment
SELECT * FROM sales.orders WHERE tags @> ARRAY['discount'];

-- jsonb path filter
SELECT full_name FROM sales.customers WHERE attributes @> '{"tier":"gold"}';
```

Range example — non-overlapping bookings:

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE TABLE bookings (
  room_id int NOT NULL,
  during  tstzrange NOT NULL,
  EXCLUDE USING gist (room_id WITH =, during WITH &&)
);
```

## Cloud notes

- All three managed offerings default to server encoding `UTF8` and collation `en_US.UTF-8` (or the equivalent). Match this in your CI to avoid nasty surprises.
- `jsonb`, arrays, ranges, `uuid`: available everywhere.
- PostGIS: available as an extension you enable — Day 27.

## Worksheet

1. For each SQL Server column below, pick the PG type and justify:  
   a. `INT IDENTITY PRIMARY KEY` → …  
   b. `NVARCHAR(200)` → …  
   c. `DATETIMEOFFSET` → …  
   d. `MONEY` → …  
   e. `VARBINARY(MAX)` → …  

2. Design a `search_path` strategy for a multi-tenant app where each tenant is a schema. How would you set it, and what breaks if you forget?  
   _Answer:_ …

3. Convert this SQL Server table verbatim to idiomatic PostgreSQL:  
   ```sql
   CREATE TABLE dbo.Users (
     UserID INT IDENTITY(1,1) PRIMARY KEY,
     Email NVARCHAR(320) NOT NULL UNIQUE,
     CreatedAtUTC DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
     IsActive BIT NOT NULL DEFAULT 1,
     Metadata NVARCHAR(MAX) NULL
   );
   ```  
   _Answer:_ …

4. Add a `GIN` index on `sales.customers.attributes` and write a query that finds gold-tier customers who opted into marketing.  
   _Answer:_ …

5. Explain the difference between `timestamp` and `timestamptz` to a teammate in two sentences.  
   _Answer:_ …

## References

- Data types: https://www.postgresql.org/docs/current/datatype.html
- `jsonb` functions: https://www.postgresql.org/docs/current/functions-json.html
- Schemas & `search_path`: https://www.postgresql.org/docs/current/ddl-schemas.html
