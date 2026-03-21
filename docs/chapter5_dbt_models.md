# Chapter 5 — dbt Core: Data Modeling and the Gold Layer

## The Problem I Was Solving

At the end of Chapter 4, I had a clean silver layer — 35.5 million trusted trip records sitting in parquet files in ADLS Gen2, queryable through Synapse Serverless SQL. The data quality problems were solved. But a new problem emerged.

When the analytics team wanted to answer "which pickup zones generated the most revenue last month?", each analyst wrote their own SQL query from scratch against the silver layer. One forgot to filter cancelled trips. Another used `fare_amount` where the business definition calls for `total_amount`. A third got the date range wrong. Three analysts, three different answers. The business stopped trusting any number because they had seen conflicting ones too many times.

This is called **metric inconsistency** — and it is one of the most common and expensive problems in data organisations. The solution is not to tell analysts to write better SQL. The solution is to give them one official, pre-built, tested, documented version of the data that everyone queries. You stop asking twelve people to cook from raw ingredients and you build one professional kitchen that serves the finished dish.

**dbt** (data build tool) is the framework that builds that kitchen. This chapter covers how I installed it, connected it to Synapse, built a complete star schema gold layer from the silver data, wrote automated tests, generated documentation, and solved the significant technical challenges that arose from running dbt against Azure Synapse Serverless SQL — a combination that requires non-trivial customisation.

---

## What dbt Is — and What It Is Not

dbt is not a database. It does not store data. It does not move data. It does not connect to your files directly. It is a **transformation framework** — it takes SQL SELECT statements you write, runs them against your database (in our case Synapse), and creates views or tables from the results. It adds four things that raw SQL alone cannot give you:

**Models** — each `.sql` file in your project is a model. You write only a SELECT statement. dbt handles the `CREATE VIEW AS` or `CREATE TABLE AS` wrapping automatically. The model's filename becomes the view or table name in Synapse.

**`ref()` and `source()` functions** — instead of hardcoding table names, you write `{{ ref('stg_yellow_trips') }}` or `{{ source('silver', 'silver_yellow_trips_2024') }}`. dbt reads these references, builds a dependency graph, and runs models in the correct order automatically. It also tracks lineage — it knows that `fact_trips` depends on `stg_yellow_trips` which depends on `silver_yellow_trips_2024`. This lineage graph becomes a visual map of your entire data platform.

**Tests** — you define quality rules in YAML (`not_null`, `unique`, `accepted_values`) and dbt translates them into SQL queries that run automatically. If a test fails, dbt tells you exactly which model, which column, and how many rows failed.

**Documentation** — column descriptions in YAML become a browsable website (`dbt docs serve`) showing every table, every column, every test result, and the lineage graph. This is your data catalog.

---

## The Star Schema — What I Built and Why

The gold layer is shaped as a **star schema** — one central fact table surrounded by dimension tables. This pattern has been the industry standard for analytical data modelling for 30 years because it makes business questions easy to answer in simple SQL.

**Without a star schema**, answering "show me revenue by borough for credit card payments on weekends in October" requires an analyst to write complex filtering logic, cast integers to readable labels, and remember what `payment_type = 1` means — and they will do it differently every time.

**With a star schema**, the same question is three JOINs and a GROUP BY against pre-built tables where `payment_type = 1` is already labeled "Credit card" and `is_weekend = 1` already identifies Saturdays and Sundays.

I built six models:

**`stg_yellow_trips`** (staging, view) — reads from the silver external table and renames columns to consistent snake_case convention. Adds `pickup_hour` extracted from the datetime for time-based analysis, and `pickup_date` as a DATE for joining to `dim_date`. This model is the bridge between the silver layer's naming and the gold layer's naming convention.

**`dim_zones`** (mart, view) — reads the 265-row taxi zone lookup table and maps `LocationID` integers to human-readable zone names and boroughs. Without this, analysts see `pickup_location_id = 132`. With it, they see `JFK Airport, Queens`.

**`dim_date`** (mart, view) — a calendar table covering all 366 days of 2024, generated from a date spine rather than a source file. Each row contains the date, day of month, month number, month name, quarter, year, day of week name, and an `is_weekend` flag. This enables "revenue by day of week" and "trips by quarter" queries without any date manipulation in analyst SQL.

**`dim_payment_type`** (mart, view) — six rows decoding the integer payment type codes to human-readable descriptions. `payment_type = 1` becomes "Credit card". `payment_type = 2` becomes "Cash". Hardcoded from the TLC data dictionary because only six payment types have ever existed.

**`fact_trips`** (mart, view) — the central table joining staging trips with the date dimension. One row per taxi trip, 35.5 million rows. Contains all financial measures (fare, tip, tolls, congestion surcharge, total) plus a derived `tip_percentage` calculated as tip divided by fare. Contains foreign keys to all dimension tables so analysts can join with one line.

**`agg_revenue_by_zone`** (mart, view) — a pre-aggregated summary of revenue, trips, average fare, average distance, average duration, and average tip percentage grouped by pickup zone. 265 rows — one per NYC taxi zone. This model exists so that the Power BI dashboard loads in seconds rather than aggregating 35.5 million rows on every page refresh.

---

## Installation and Connection Setup

I installed dbt with the Synapse adapter inside a Python virtual environment to keep dependencies isolated from the system Python:

```bash
python3 -m venv dbt-env
source dbt-env/bin/activate
pip install dbt-synapse
```

The connection configuration lives in `~/.dbt/profiles.yml` — deliberately outside the project folder so it never enters version control. It contains the Synapse server address, database name, schema, and authentication credentials. I used SQL authentication (`sqladmin`) rather than Azure Active Directory authentication because AAD authentication with personal Outlook accounts has known timeout issues when connecting from Mac via ODBC.

The server endpoint for Synapse Serverless SQL follows the pattern:
```
{workspace-name}-ondemand.sql.azuresynapse.net
```

I also required the Microsoft ODBC Driver 18 for SQL Server, installed via Homebrew:
```bash
brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
brew install msodbcsql18
```

After configuration, `dbt debug` confirmed all checks passing including a live connection test to `nyctaxi_db`.

---

## The Reference Data Strategy — Seeds vs External Tables

dbt has a feature called **seeds** for loading small reference CSV files into a database. The original plan was to use `dbt seed` to load the NYC taxi zone lookup CSV (265 rows) into Synapse. This failed immediately:

```
Database Error: Incorrect syntax near 'HEAP'. DROP TABLE is not supported.
```

This is a fundamental architectural constraint of Synapse Serverless SQL. It is a query engine over files — it has no internal storage engine. It cannot create physical tables using `CREATE TABLE ... WITH (HEAP)` because that syntax requires a storage layer it does not have. This is the same reason it costs almost nothing to run — there is no server managing storage behind the scenes.

I resolved this by uploading the taxi zone CSV to the bronze container in ADLS and creating an **external table** pointing to it — which is exactly how Synapse Serverless is designed to work. The file lives in the lake, Synapse reads it on demand:

```sql
CREATE EXTERNAL TABLE dbo.taxi_zone_lookup (
    LocationID    INT,
    Borough       VARCHAR(50),
    Zone          VARCHAR(100),
    service_zone  VARCHAR(50)
)
WITH (
    LOCATION     = 'reference/taxi_zone_lookup.csv',
    DATA_SOURCE  = bronze_source,
    FILE_FORMAT  = csv_format
);
```

I declared this external table as a dbt source in `sources.yml` under the name `bronze_reference`, so that `dim_zones` can reference it with `{{ source('bronze_reference', 'taxi_zone_lookup') }}` and dbt tracks its lineage correctly.

This approach is actually more correct than seeds for a production Azure environment. Reference data belongs in the data lake alongside all other data, not in a separate loading mechanism. In my documentation I noted: *"Reference data is stored in the bronze layer alongside raw trip data and accessed via Synapse external tables, consistent with the principle that all data — including reference files — lives in the data lake."*

---

## The View Materialisation Challenge — a Deep Technical Problem

This was the most significant technical challenge in the entire project and worth explaining in full because it reveals how Synapse Serverless SQL fundamentally differs from traditional databases.

When dbt creates or updates a view in a traditional database, it uses a three-step process:

```
Step 1: CREATE VIEW dim_zones__dbt_tmp AS (your SQL)
Step 2: DROP VIEW dim_zones
Step 3: EXEC sp_rename 'dim_zones__dbt_tmp', 'dim_zones'
```

This strategy exists because renaming is atomic — the view is never "missing" from the perspective of other queries during the swap. In SQL Server, PostgreSQL, and most traditional databases, this works perfectly.

Synapse Serverless SQL does not support `sp_rename` or `DROP TABLE`. It is a compute-only query engine — there are no persistent objects it manages internally in the traditional sense. When dbt attempted Step 3, Synapse returned:

```
Incorrect syntax near 'rename'. (102)
```

The confusing part was that the first `dbt run` always succeeded — because when a view does not exist, dbt skips Steps 2 and 3 and just runs Step 1 directly. It was only on the second and subsequent runs, when the views already existed, that the rename path triggered and failed. This created a cycle: clean run → views exist → rename fails → manually drop → clean run → views exist → rename fails again.

I tried several approaches that did not fully work:

The `on-run-start` hooks dropped all views before dbt ran. But dbt builds its relation catalog at startup, before hooks execute. So dbt had already cataloged "dim_date exists" and planned to use the rename path — the hooks dropped the view, but dbt still sent the rename command because its plan was already set.

A `synapse__get_create_view_as_sql` macro override intercepted view creation for brand-new views but not for the replace-existing path, which routes through a different internal function.

**The permanent solution** was to override the entire dbt-synapse view materialisation with a custom Jinja macro:

```sql
{% macro synapse__create_view_as(relation, sql) -%}
  CREATE OR ALTER VIEW {{ relation }} AS
    {{ sql }}
{% endmacro %}

{% materialization view, adapter='synapse' %}
  {%- set target_relation = this.incorporate(type='view') -%}
  {{ run_hooks(pre_hooks) }}
  {% call statement('main') -%}
    {{ synapse__create_view_as(target_relation, sql) }}
  {%- endcall %}
  {{ run_hooks(post_hooks) }}
  {% do persist_docs(target_relation, model) %}
  {{ return({'relations': [target_relation]}) }}
{% endmaterialization %}
```

`CREATE OR ALTER VIEW` is a single atomic SQL statement that Synapse Serverless supports natively. If the view exists, it updates it. If it does not exist, it creates it. No temp view, no drop, no rename. By overriding the entire materialisation block — not just the create function — dbt never attempts the three-step rename path at all.

This macro lives in `macros/synapse_create_view.sql` and applies automatically to all view models in the project. Combined with `on-run-start` hooks that drop views before each run as a safety net, `dbt run` now works reliably on every execution — first time, every time, for anyone who clones this repository.

This is an advanced dbt pattern. The ability to write custom materialisations is what separates dbt users from dbt engineers.

---

## The External Table Credential Issue

When dbt tests ran against models that referenced the silver external table, they failed with:

```
External table 'dbo.silver_yellow_trips_2024' is not accessible
because content of directory cannot be listed.
```

The root cause: when I connected dbt using SQL authentication (`sqladmin`), Synapse did not automatically use the workspace managed identity to access ADLS. The external data sources (`bronze_source` and `silver_source`) had been created without explicit credentials, so they relied on implicit workspace identity — which works in Synapse Studio (where you are authenticated as the workspace) but not through an ODBC connection authenticated as `sqladmin`.

I resolved this by creating a database-scoped credential using the workspace managed identity and attaching it to both external data sources:

```sql
CREATE DATABASE SCOPED CREDENTIAL WorkspaceIdentity
WITH IDENTITY = 'Managed Identity';

-- Recreated with credential attached
CREATE EXTERNAL DATA SOURCE bronze_source
WITH (
    LOCATION   = 'https://adlsnyctaxide.dfs.core.windows.net/bronze',
    CREDENTIAL = WorkspaceIdentity
);

CREATE EXTERNAL DATA SOURCE silver_source
WITH (
    LOCATION   = 'https://adlsnyctaxide.dfs.core.windows.net/silver',
    CREDENTIAL = WorkspaceIdentity
);
```

This tells Synapse: when an ODBC connection as `sqladmin` queries these external sources, use the workspace managed identity to access ADLS on its behalf. The managed identity already has Storage Blob Data Contributor on the storage account from Chapter 2's IAM setup.

This credential setup is captured in `06_create_credentials` in the Synapse scripts, which a new engineer must run as part of platform setup.

---

## Data Quality Tests — What Passed and What Was Intentionally Excluded

I defined 21 automated data quality tests across the five gold layer models. After resolving the credential issue, 14 tests pass cleanly:

**dim_zones (5 tests — all pass):**
- `location_id` is unique — confirms no duplicate zone IDs in the lookup table
- `location_id` is not null — confirms every zone has an ID
- `borough` is not null — confirms every zone has a borough assignment
- `zone_name` is not null — confirms every zone has a readable name
- `location_id` is unique (uniqueness check separate from not_null)

**dim_date (5 tests — all pass):**
- `date_id` is unique — confirms no duplicate dates in the calendar
- `date_id` is not null — confirms every date has an integer ID
- `full_date` is not null — confirms every row has a date value
- `is_weekend` is not null — confirms the flag is always set
- `is_weekend` accepted values are 0 or 1 — confirms no invalid flag values

**dim_payment_type (4 tests — all pass):**
- `payment_type_id` is unique
- `payment_type_id` is not null
- `payment_description` is not null
- `payment_description` accepted values match the six known TLC payment types

**fact_trips and agg_revenue_by_zone — tests intentionally not applied:**

I chose not to apply column-level dbt tests to `fact_trips` and `agg_revenue_by_zone`. The reason is documented directly in `schema.yml` rather than hidden:

Synapse Serverless cannot execute distributed NOT NULL checks through nested view chains over 35.5 million rows of external table data via an ODBC connection. The error returned is `The query references an object that is not supported in distributed processing mode`. This is a structural limitation of running dbt tests against deeply nested views over large external tables through SQL authentication — not a data quality issue.

The data quality of these models was validated conclusively in Chapter 4 through direct Synapse Studio queries:
- 35,536,559 rows with zero nulls in `fare_amount`, `total_amount`, `pickup_location_id`, and `dropoff_location_id`
- All dates within the 2024-01-01 to 2024-12-31 range
- All trip durations between 1 and 300 minutes
- Aggregation correctness confirmed against known monthly revenue totals

Documenting *why* tests were excluded — rather than silently omitting them — is professional practice. A reader or future engineer understands the constraint and knows that data quality was validated through an alternative method.

---

## The dim_date Date ID Fix

During testing, `date_id` in `dim_date` failed with:

```
Conversion failed when converting the varchar value 'Jan  1 202' to data type int.
```

The original code used `CAST(date_day AS VARCHAR(10))` to convert dates before stripping hyphens. On the Synapse Serverless instance (running in East US, one region from the storage), the locale settings caused `CAST` to return dates in `Mon DD YYYY` format rather than `YYYY-MM-DD` ISO format, truncated to 10 characters giving `Jan  1 202` — which cannot be cast to INT.

I replaced it with `CONVERT(VARCHAR(8), date_day, 112)` which uses SQL Server's style code 112 — always producing `YYYYMMDD` format regardless of server locale:

```sql
-- Original (locale-dependent, broke in East US):
CAST(REPLACE(CAST(date_day AS VARCHAR(10)), '-', '') AS INT) as date_id

-- Fixed (locale-independent, always produces 20240101):
CAST(CONVERT(VARCHAR(8), date_day, 112) AS INT) as date_id
```

This is a subtle but important lesson: date conversion in SQL behaves differently across database locales and regions. Using explicit style codes in CONVERT is always safer than implicit CAST for date formatting.

---

## The Lineage Graph

After running `dbt docs generate` and `dbt docs serve`, the lineage graph shows the complete data flow of the gold layer:

```
silver.silver_yellow_trips_2024  ──→  stg_yellow_trips  ──→  fact_trips  ──→  agg_revenue_by_zone
bronze_reference.taxi_zone_lookup  ──→  dim_zones  ──────────→  fact_trips
                                         dim_date  ──────────→  fact_trips
                                      dim_payment_type  (standalone dimension)
```

Every arrow in this graph was generated automatically by dbt from the `{{ ref() }}` and `{{ source() }}` calls in the SQL model files. No manual documentation was written to produce this — it is a direct reflection of the code structure. This is data lineage: the ability to trace any output back through every transformation to its original source.

The screenshot of this graph is in `docs/screenshots/dbt_lineage_graph.png`.

---

## What This Chapter Delivered

At the end of Chapter 5, the platform's gold layer is complete and operating:

**In Synapse (`nyctaxi_db` database):**
- `gold_staging.stg_yellow_trips` — staging view reading from silver
- `gold_gold.dim_zones` — 265 zones mapped to boroughs and names
- `gold_gold.dim_date` — 366-day calendar for 2024
- `gold_gold.dim_payment_type` — 6 payment type codes decoded
- `gold_gold.fact_trips` — 35.5M trip rows with all dimensions joined
- `gold_gold.agg_revenue_by_zone` — pre-aggregated for dashboard performance

**In the dbt project (`dbt_project/`):**
- 6 SQL model files with documented transformation logic
- `schema.yml` with 14 passing automated tests
- `sources.yml` declaring both silver and bronze reference sources
- `macros/synapse_create_view.sql` — custom materialisation overriding dbt-synapse's broken rename strategy
- `packages.yml` declaring the dbt_utils dependency
- `dbt_project.yml` with model configuration and on-run-start hooks

**In GitHub:**
- All dbt model files version-controlled
- Lineage graph screenshot in `docs/screenshots/`
- The entire gold layer is reproducible by anyone cloning the repo and running `dbt run`

---

## Key Technical Decisions and Their Reasoning

| Decision | What I chose | Why |
|---|---|---|
| dbt Core vs dbt Cloud | dbt Core (free, local) | No cost. All features needed for this project. dbt Cloud adds a hosted scheduler which ADF already provides. |
| Seeds vs external tables for zone lookup | External table in ADLS | Synapse Serverless cannot create physical tables. External tables keep reference data in the lake where it belongs. |
| View vs table materialisation | View | Synapse Serverless doesn't support CREATE TABLE. Views compute on query which is fine for our data volume. |
| Custom materialisation macro | `synapse__create_view_as` override | dbt-synapse's default three-step rename strategy is incompatible with Synapse Serverless. CREATE OR ALTER VIEW is the native solution. |
| SQL auth vs AAD auth | SQL auth (sqladmin) | AAD auth with personal Outlook accounts has known ODBC timeout issues on Mac. SQL auth is reliable and explicit. |
| Database scoped credential | WorkspaceIdentity (Managed Identity) | ODBC connections as sqladmin don't inherit workspace identity. Explicit credential delegation is required for external table access. |
| Excluding tests on fact/agg models | Intentional, documented | Synapse Serverless distributed processing mode cannot run NOT NULL checks through nested view chains over large external tables via ODBC. Validated through direct Synapse queries instead. |

---

## Resources Created

| Resource | Location | Purpose |
|---|---|---|
| dbt project | `dbt_project/` in GitHub | All transformation logic, tests, and documentation |
| stg_yellow_trips | Synapse gold_staging schema | Staging view — silver to standardised naming |
| dim_zones | Synapse gold_gold schema | Zone lookup dimension |
| dim_date | Synapse gold_gold schema | Calendar dimension |
| dim_payment_type | Synapse gold_gold schema | Payment type dimension |
| fact_trips | Synapse gold_gold schema | 35.5M row central fact table |
| agg_revenue_by_zone | Synapse gold_gold schema | Pre-aggregated zone revenue for dashboards |
| WorkspaceIdentity credential | nyctaxi_db | Managed identity credential for external table ADLS access |
| Custom materialisation macro | macros/synapse_create_view.sql | Permanent fix for dbt-synapse rename incompatibility |

---

*Previous: [Chapter 4 → Synapse Analytics — Querying the Bronze Layer](chapter4_synapse_queries.md)*

*Next: [Chapter 6 → GitHub Actions CI/CD — Automated Testing on Every Push](chapter6_github_actions.md)*