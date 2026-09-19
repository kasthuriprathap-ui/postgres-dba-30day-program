# Week 1 — PostgreSQL Fundamentals for the SQL Server Mind

**Goal:** by Sunday you can install PostgreSQL, connect to it fluently with `psql`, understand the cluster/database/schema hierarchy, manage roles and permissions, and reason about MVCC well enough not to be surprised in production.

| Day | Topic | Why it matters |
|---|---|---|
| 1 | Architecture & mental model | The whole rest of the month hinges on this. |
| 2 | Installation & connectivity | You need a lab. Local Docker is enough. |
| 3 | The `psql` toolkit | This is your SSMS-replacement. Master it. |
| 4 | Data types & schemas | Schemas, `search_path`, and PG's rich type system. |
| 5 | Roles, users, and grants | The unified role model is the biggest permissions delta. |
| 6 | MVCC and transactions | Where the "no NOLOCK, no blocked-by-reader" world comes from. |
| 7 | Week 1 review & worksheet | Consolidate. Take the assessment. |

Keep `SQL_SERVER_TO_POSTGRES_CHEATSHEET.md` open. Reach for it every time you catch yourself typing T-SQL.
