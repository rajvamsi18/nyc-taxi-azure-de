# Chapter 4 — Synapse Analytics: Querying the Bronze Layer and Building Silver

## The Problem I Was Solving

At the end of Chapter 3, my bronze container held 41 million NYC taxi trip records across 12 parquet files. The data existed, but it was completely inaccessible to the business. No analyst could answer "which month had the most revenue?" without downloading gigabytes of files to their laptop and running Python locally, which defeats the entire purpose of building a cloud platform.

I needed a query engine that could run SQL **directly against files sitting in ADLS Gen2** — without provisioning a dedicated database server, without copying data anywhere, and without paying for compute that sits idle between queries.

Azure Synapse Analytics Serverless SQL is exactly that engine. This chapter covers how I set it up, what I discovered about the data when I queried it at full scale, how I built the Silver cleaning layer, and how I connected Synapse directly to GitHub so every SQL script is automatically version-controlled.

---

## Why Serverless SQL — and Not the Other Synapse Engines

Azure Synapse Analytics is marketed as a single product but actually contains three distinct compute engines sharing one workspace. Understanding which engine to use and why is something I get asked about in interviews, so I want to document the decision clearly.

**Serverless SQL Pool** — what I chose. No cluster to provision, no idle cost, standard SQL syntax, billed at $5 per terabyte scanned. For our ~600MB silver dataset, querying costs fractions of a cent per run. Starts instantly with zero warmup time. Perfect for ad-hoc exploration and batch transformation workloads like ours.

**Dedicated SQL Pool** — a pre-provisioned data warehouse cluster. Costs approximately $700/month minimum whether used or not. The right choice for high-concurrency production BI workloads serving hundreds of simultaneous users. Completely wrong for a learning project or exploratory work at any scale.

**Apache Spark Pool** — distributed compute for Python and PySpark workloads. Appropriate for datasets over 100GB or for machine learning training jobs. Costs $2–5/hour while running. Unnecessary given our SQL-based transformation approach and dataset size.

Serverless SQL matches our workload perfectly: batch SQL queries against parquet files, moderate data volume (~600MB), no concurrency requirements, and zero tolerance for idle cost.

---

## How Serverless SQL Works — the Key Concept

Serverless SQL does not store data in a traditional database. There are no tables in the conventional sense. Instead, it reads parquet files **on demand at query time** using a function called `OPENROWSET`. You give it a path in ADLS and tell it the file format, it returns the file contents as a virtual table you can `SELECT` from. No loading, no copying, no importing.

This is what makes it cost-effective: compute only runs while a query is actively executing. The moment a query finishes, nothing is running and nothing is being charged.

For structured, repeatable access I also created **External Tables** named objects that point at a folder in ADLS and behave like regular database tables from a query perspective, while the actual data stays in parquet files in the lake.

---

## Deployment — Regional Provisioning Issue and Resolution

During workspace creation I encountered this error:

```
SqlServerRegionDoesNotAllowProvisioning
Location 'eastus2' is not accepting creation of new Windows Azure
SQL Database servers for this subscription at this time.
```

This is a Microsoft-side capacity restriction on free/new subscriptions in the East US 2 region, not a configuration error on my part. I resolved it by deploying the Synapse workspace in **East US** (one region away from the ADLS storage account in East US 2).

For our dataset size of ~600MB, the cross-region data transfer costs less than $0.01. In a production environment I would ensure both services share the same region to eliminate this cost and reduce latency entirely. I document this constraint rather than hiding it, real engineering involves real constraints and real trade-offs, and acknowledging them demonstrates understanding of the architecture.

I also needed to register the Synapse resource provider before deployment would succeed:

```bash
az provider register --namespace Microsoft.Synapse
az provider register --namespace Microsoft.Sql
az provider register --namespace Microsoft.Network
```

Resource providers are Azure's mechanism for tracking which services a subscription is actively using. On a fresh or long-dormant subscription, services like Synapse are not pre-registered. This is a one-time step per subscription.

---

## Workspace Setup and Database Organisation

Once deployed, I opened Synapse Studio and created a dedicated database for the project:

```sql
CREATE DATABASE nyctaxi_db;
```

I never use the default `master` database for project work. `master` is a system database, putting project objects there makes them harder to find, harder to clean up, and creates confusion if the workspace is shared. Every SQL script I write begins with `USE nyctaxi_db;` to ensure it always runs in the correct context regardless of what the UI dropdown is set to.

I organised the work across five SQL scripts, each with a single clear purpose:

```
01_create_database          CREATE DATABASE nyctaxi_db
02_bronze_exploration       Validation queries against the full bronze dataset
03_create_data_sources      External data sources and file format definitions
04_build_silver_layer       CETAS — reads bronze, applies cleaning, writes silver
05_verify_silver            Row count and quality verification of silver output
```

The `01_`, `02_` numeric prefix forces scripts to display in execution order in both Synapse Studio's sidebar and in the GitHub repository, a reader immediately understands the sequence without any explanation.

---

## Synapse Git Integration — Version Control Done Properly

Before running any queries I connected Synapse Studio directly to my GitHub repository. This is the professional approach to script management, far better than manually downloading scripts or copy-pasting SQL into files.

**Configuration applied:**

```
Repository type:      GitHub
GitHub account:       rajvamsi18
Repository name:      nyc-taxi-azure-de
Collaboration branch: main
Publish branch:       workspace_publish
Root folder:          /synapse_scripts
```

After connecting, every time I click **Commit all** in Synapse Studio, all SQL scripts are automatically committed to GitHub under `synapse_scripts/sqlscript/` as version-controlled JSON files. The Synapse-native JSON format wraps the SQL inside metadata that allows the workspace to be fully recreated from the repository.

This means my GitHub repository contains two complementary representations of the same SQL work:

```
sql/                          ← human-readable plain .sql files
                                 for documentation and portfolio reading

synapse_scripts/sqlscript/    ← Synapse-native JSON files
                                 auto-committed on every Publish
                                 for workspace reproducibility
```

Having both is intentional. The `sql/` folder exists for anyone reading the GitHub repo who wants to understand the logic. The `synapse_scripts/` folder exists so the entire Synapse workspace can be recreated from the repository with no manual steps, which is what infrastructure-as-code means in practice.

The commit history on GitHub now shows `rajvamsi18` as the author of every script change, with timestamps and commit messages. This is the kind of traceable, auditable development practice that professional data engineering teams require.

---

## External Data Sources — Avoiding Repetition

Rather than typing the full ADLS URL in every query, I created reusable data source objects:

```sql
USE nyctaxi_db;

CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'NycTaxi@Master2024!';

CREATE EXTERNAL DATA SOURCE bronze_source
WITH (
    LOCATION = 'https://adlsnyctaxide.dfs.core.windows.net/bronze'
);

CREATE EXTERNAL DATA SOURCE silver_source
WITH (
    LOCATION = 'https://adlsnyctaxide.dfs.core.windows.net/silver'
);

CREATE EXTERNAL FILE FORMAT parquet_format
WITH (FORMAT_TYPE = PARQUET);
```

The master key is required once per database as a prerequisite for creating credentials and external objects. The data sources act as named shortcuts, downstream scripts reference `bronze_source` rather than the full storage URL, making them shorter, less error-prone, and easier to update if the storage account name ever changes.

A note on the master key password: Azure enforces a minimum complexity policy (uppercase, lowercase, number, symbol, minimum 8 characters). I learned this during setup when a shorter password was rejected. The error was clear and the fix immediate, I document it here so anyone reproducing this setup knows to use a strong password from the start.

---

## What the Bronze Exploration Revealed

Running three validation queries against the full 12-month bronze dataset at scale produced findings that confirmed and extended what I discovered during the single-month Python inspection in Chapter 2.

### Query 1 — Total dataset size

```sql
SELECT COUNT(*) AS total_trips
FROM OPENROWSET(
    BULK 'https://adlsnyctaxide.dfs.core.windows.net/bronze/yellow_taxi/year=2024/*/*.parquet',
    FORMAT = 'PARQUET'
) AS trips;
```

**Result: 41,169,720 trips**

This is higher than my earlier estimate of ~35 million. The estimate was based on scaling January's 2.96M rows by 12 months, assuming uniform monthly distribution. The real data shows significantly higher volume in spring and autumn months, a seasonal pattern that became clear in the monthly breakdown below.

### Query 2 — Data quality audit

```sql
SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN passenger_count IS NULL THEN 1 ELSE 0 END) AS null_passenger_count,
    SUM(CASE WHEN fare_amount IS NULL THEN 1 ELSE 0 END)     AS null_fare_amount,
    SUM(CASE WHEN trip_distance <= 0 THEN 1 ELSE 0 END)      AS invalid_distance,
    SUM(CASE WHEN fare_amount <= 0 THEN 1 ELSE 0 END)        AS invalid_fare
FROM OPENROWSET(
    BULK 'https://adlsnyctaxide.dfs.core.windows.net/bronze/yellow_taxi/year=2024/*/*.parquet',
    FORMAT = 'PARQUET'
) AS trips;
```

**Results:**

| Metric | Count | Percentage | Decision |
|---|---|---|---|
| Total bronze rows | 41,169,720 | 100% | Baseline |
| Null passenger_count | 4,091,232 | 9.9% | Remove — vendor-level gap |
| Null fare_amount | 0 | 0.0% | No action — critical column clean |
| Invalid distance (≤0) | 776,305 | 1.9% | Remove — physically impossible |
| Invalid fare (≤0) | 748,284 | 1.8% | Remove — data entry errors |

The null passenger_count of 4,091,232 is exactly 14.2× January's 140,162, perfectly consistent with the same vendor systematically omitting this field across all 12 months. This confirmed my Chapter 2 hypothesis that it is a structural vendor-level gap, not random missing data. Because the nulls are structural rather than random, removing rows where `passenger_count IS NULL` cleanly eliminates all five affected columns simultaneously, since they always belong to the same rows.

The zero null count on `fare_amount` across 41 million rows is significant. The most critical financial column in the dataset is completely clean, every trip has a recorded fare. This means revenue analysis is based on complete data.

### Query 3 — Monthly revenue breakdown

```sql
SELECT
    MONTH(tpep_pickup_datetime)      AS pickup_month,
    COUNT(*)                          AS total_trips,
    ROUND(SUM(fare_amount), 2)        AS total_fare_revenue,
    ROUND(AVG(fare_amount), 2)        AS avg_fare,
    ROUND(AVG(trip_distance), 2)      AS avg_distance_miles
FROM OPENROWSET(
    BULK 'https://adlsnyctaxide.dfs.core.windows.net/bronze/yellow_taxi/year=2024/*/*.parquet',
    FORMAT = 'PARQUET'
) AS trips
WHERE fare_amount > 0 AND trip_distance > 0
GROUP BY MONTH(tpep_pickup_datetime)
ORDER BY pickup_month;
```

**Full results — all 12 months:**

| Month | Total trips | Total fare revenue | Avg fare | Avg distance |
|---|---|---|---|---|
| January | 2,869,727 | $53,088,137 | $18.50 | 3.73 mi |
| February | 2,901,482 | $53,447,405 | $18.42 | 3.96 mi |
| March | 3,440,050 | $65,904,417 | $19.16 | 4.62 mi |
| April | 3,414,215 | $66,438,906 | $19.46 | 5.24 mi |
| May | 3,616,389 | $72,870,831 | $20.15 | 5.36 mi |
| June | 3,428,111 | $68,399,909 | $19.95 | 5.28 mi |
| July | 2,973,836 | $59,965,475 | $20.16 | 5.17 mi |
| August | 2,867,297 | $58,446,397 | $20.38 | 5.03 mi |
| September | 3,483,778 | $71,969,489 | $20.66 | 5.79 mi |
| **October** | **3,681,795** | **$75,011,161** | **$20.37** | **5.21 mi** |
| November | 3,510,955 | $69,665,904 | $19.84 | 5.27 mi |
| December | 3,519,017 | $71,776,249 | $20.40 | 5.14 mi |

**Business insights surfaced directly from this query:**

**October was the highest revenue month** at $75,011,161, generating 28% more revenue than August's low of $58,446,397. For UrbanMove's operations team, this is an actionable finding: October requires significantly more drivers available to capture peak demand. Under-staffing in October directly costs revenue.

**The summer paradox** — July and August have the fewest trips of the entire year, yet some of the highest average fares ($20.16–$20.38). New Yorkers take fewer taxi trips in summer but those trips cover greater distances and cost more. This likely reflects a seasonal shift from short commuting trips to longer leisure and airport trips. A driver working in August earns more per trip but handles fewer total trips than in May.

**Trip distance grows dramatically from winter to spring** — from 3.73 miles in January to 5.79 miles in September, a 55% increase over the year. Combined with the fare trend, this suggests that as weather improves, the nature of taxi usage shifts from short urban hops to longer destination-oriented journeys.

**January and August have almost identical trip volumes** (2.87M each) despite being opposite seasons — suggesting different suppression mechanisms (winter weather vs summer holidays) produce similar total demand reduction.

These insights come from the bronze layer - raw, uncleaned data. The silver layer will refine these numbers by removing the invalid records, giving the business accurate final figures.

---

## Building the Silver Layer — CETAS

CETAS (CREATE EXTERNAL TABLE AS SELECT) is Synapse's pattern for materialising transformation output. It reads from one location, applies logic, and writes the result as parquet files to a new destination, all in a single SQL statement. I used it to build the silver layer from bronze.

### Why each cleaning rule exists

Every condition in the WHERE clause maps directly to a finding from the data quality audit above. There are no arbitrary filters.

```sql
WHERE passenger_count > 0
```
Removes the 4,091,232 vendor-gap rows. Also removes the small number of trips where a driver recorded 0 passengers, incomplete records with no business value.

```sql
AND trip_distance > 0
```
Removes 776,305 rows with zero or negative distances. A taxi trip cannot cover zero or negative miles. These are recording errors at the vendor's system.

```sql
AND fare_amount > 0
```
Removes 748,284 rows with zero or negative fares. Every legitimate trip produces a positive fare. Zero-fare records are voided transactions, test trips, or recording errors.

```sql
AND tpep_pickup_datetime >= '2024-01-01'
AND tpep_pickup_datetime <  '2025-01-01'
```
Removes trips with pickup times outside the 2024 calendar year. The TLC source occasionally contains records with incorrect timestamps, trips from 2023 or timestamped far in the future appear in 2024 files. These are out of scope for this project's annual analysis.

```sql
AND DATEDIFF(MINUTE, tpep_pickup_datetime, tpep_dropoff_datetime) BETWEEN 1 AND 300
```
Removes trips shorter than 1 minute (no taxi fare can be legitimately completed that quickly) and longer than 5 hours. Trips over 300 minutes are extreme outliers that would distort averages, likely unreturned vehicles or meter-running errors.

### The computed column I added

```sql
DATEDIFF(MINUTE, tpep_pickup_datetime, tpep_dropoff_datetime) AS trip_duration_mins
```

Trip duration does not exist in the source data. I calculate and persist it in silver so that every downstream consumer - dbt models, analyst queries, Power BI gets it without recomputing it. This is a small but meaningful optimisation: calculating DATEDIFF on 35 million rows repeatedly in every downstream query wastes compute. Persisting it once in silver pays dividends at scale.

### Silver output — parallel files explained

When the CETAS completed (approximately 3 minutes for 41 million input rows), the silver container showed 5 parquet files rather than one:

```
silver/yellow_taxi/year=2024/
├── 5EFEF2AF-..._26_0-...parquet   253 MB
├── 5EFEF2AF-..._26_1-...parquet   165 MB
├── 5EFEF2AF-..._26_2-...parquet   164 MB
├── 5EFEF2AF-..._26_3-...parquet   249 MB
├── 5EFEF2AF-..._26_4-...parquet   172 MB
└── _                               0 bytes (success marker)
```

This is expected and correct, not a problem to fix. Synapse processes large datasets across multiple parallel threads to finish faster, with each thread writing its output to a separate file. The zero-byte `_` file is a success marker that Synapse writes to indicate the CETAS completed without errors.

All downstream tools read the folder using a wildcard path (`silver/yellow_taxi/year=2024/*.parquet`) and treat all 5 files as one logical table automatically. The filenames are irrelevant, the folder structure is what matters. This is the same pattern used by Apache Spark, Databricks, and every modern distributed processing system.

Total silver size on disk: approximately 1GB of clean, compressed parquet data representing 35.5 million valid trips.

---

## Silver Layer Verification Results

```sql
SELECT
    COUNT(*)                          AS silver_row_count,
    MIN(pickup_datetime)              AS earliest_trip,
    MAX(pickup_datetime)              AS latest_trip,
    ROUND(AVG(fare_amount), 2)        AS avg_fare,
    ROUND(AVG(trip_duration_mins), 1) AS avg_duration_mins
FROM silver_yellow_trips_2024;
```

**Results:**

| Metric | Value |
|---|---|
| Silver row count | 35,536,559 |
| Rows removed from bronze | 5,633,161 (13.7%) |
| Earliest trip | 2024-01-01 00:00:00 |
| Latest trip | 2024-12-31 23:59:59 |
| Average fare | $19.73 |
| Average trip duration | 16 minutes |

**13.7% of all bronze records were removed as invalid.** More than 1 in 8 rows failed at least one quality check. Without a Silver layer, every downstream analysis would have been silently distorted by these records. The average fare on the full bronze dataset would have been pulled down by zero-fare records. Duration averages would have been skewed by impossible 0-minute and multi-day trips.

The bronze layer is preserved exactly as received from the source, it is the permanent record of what the TLC delivered. The silver layer is what the business actually uses for analysis.

The date range of 2024-01-01 to 2024-12-31 confirms the date filter worked correctly, no out-of-range records reached silver.

---

## What This Chapter Delivered

At the end of Chapter 4 the platform has the following state:

**In Azure:**
- Synapse Analytics workspace running in East US (Serverless SQL pool)
- `nyctaxi_db` database with external data sources for bronze and silver
- `silver_yellow_trips_2024` external table pointing at 35.5M clean trip records

**In ADLS Gen2:**
- Bronze layer: 41,169,720 raw records across 12 parquet files — untouched
- Silver layer: 35,536,559 clean records across 5 parquet files — ready for modeling

**In GitHub:**
- `synapse_scripts/sqlscript/` — all 5 SQL scripts auto-committed by Synapse Git Integration
- `sql/` — human-readable plain SQL versions for documentation purposes
- `docs/chapter4_synapse_queries.md` — this document

The first real business insight is already visible: October 2024 was the highest revenue month at $75M, summer months show a demand paradox, and trip distances grow 55% from winter to summer. These findings will become the foundation of the Gold layer dashboards built in Chapters 5 and 6.

---

## Resources Created

| Resource | Name | Purpose |
|---|---|---|
| Synapse workspace | synapse-nyctaxi-de | Serverless SQL query engine, East US region |
| Synapse database | nyctaxi_db | Logical container for all project objects |
| External data source | bronze_source | Reusable pointer to bronze ADLS container |
| External data source | silver_source | Reusable pointer to silver ADLS container |
| External file format | parquet_format | Parquet format definition used by CETAS |
| External table | silver_yellow_trips_2024 | Clean 35.5M-row silver dataset |
| GitHub integration | synapse_scripts/ folder | Auto-commits all SQL scripts on every Publish |

---

*Previous: [Chapter 3 → Azure Data Factory — Ingestion Pipeline](chapter3_adf_pipeline.md)*

*Next: [Chapter 5 → dbt Core — Data Modeling and the Gold Layer](chapter5_dbt_models.md)*v