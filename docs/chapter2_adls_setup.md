# Chapter 2 — Data Lake Setup: Azure Data Lake Storage Gen2

## The Problem I Was Solving

Before writing a single pipeline, I needed to answer a foundational question: **where does the data live, and how is it organised?**

This matters more than most beginners realise. A poorly designed storage layer causes problems that compound as the project grows, analysts accidentally overwriting raw data, no way to recover from a bad transformation, queries scanning entire datasets when they only need one month. I designed this storage layer to avoid all three of those failure modes from day one.

---

## Why Azure Data Lake Storage Gen2 (ADLS Gen2)?

When I looked at Azure storage options, there were two candidates: **Azure Blob Storage** and **ADLS Gen2**. Both store files. Both are cheap. The difference is one setting: **Hierarchical Namespace (HNS)**.

Without HNS, Azure Blob Storage simulates folders using long filenames with slashes. `bronze/2024/01/file.parquet` is not actually inside a folder, it is a single file with a very long name that includes slashes. This means renaming a "folder" requires rewriting every filename inside it, which is slow and expensive at scale.

With HNS enabled, **ADLS Gen2 creates real, true folders** at the filesystem level. Renaming a folder is instant. Deleting a folder is atomic. More importantly, tools like Apache Spark and Azure Synapse Analytics navigate true folder hierarchies far more efficiently, critical when you have thousands of parquet files partitioned by year and month.

I enabled HNS when creating the storage account. This single checkbox is what makes it ADLS Gen2 rather than basic Blob Storage. It cannot be changed after account creation, which is why this decision had to be made upfront.

**Configuration I used:**

| Setting | Value | Reason |
|---|---|---|
| Storage account name | `adlsnyctaxide` | Globally unique, all lowercase, no hyphens (Azure storage naming rule) |
| Region | East US 2 | One of Azure's cheapest regions with full service availability (Synapse, ADF) |
| Performance tier | Standard | Premium is for low-latency database workloads, not batch data processing |
| Redundancy | LRS (Locally Redundant Storage) | Replicates data 3× within one data centre. Sufficient for a project; in production I would evaluate ZRS or GRS based on recovery requirements |
| Hierarchical Namespace | **Enabled** | This is the setting that makes it ADLS Gen2. Without this it is basic Blob Storage. |

---

## Why the Medallion Architecture?

I designed the storage layer around the **Medallion Architecture**, an industry-standard pattern where data is organised into three progressive zones: Bronze, Silver, and Gold.

The restaurant analogy helps explain why this matters. A chef does not serve customers directly from unopened delivery boxes, and they do not throw away the raw ingredients once the dish is plated. Each stage of food preparation is separate and reversible. The medallion architecture applies the same logic to data.

### Bronze — the raw zone

I store the raw parquet files from the NYC TLC website here, exactly as downloaded. No modifications. No transformations. If I discover a bug in my cleaning logic three months from now, I can re-run the entire transformation from bronze and get a corrected result. Without a raw zone, a bug in transformation permanently destroys the original data.

**Rule I follow: nothing in bronze is ever modified or deleted. It is append-only.**

### Silver — the clean zone

This is where I apply cleaning logic: removing rows where `fare_amount` is null, filtering out trips with negative distances (which are data entry errors in the source), casting pickup and dropoff timestamps from string to proper TIMESTAMP types, and dropping duplicate trip records. The data in silver is still structured the same way as bronze — one row per trip — but it is trustworthy.

### Gold — the business zone

This is where I reshape cleaned data into a star schema that analysts can query efficiently. Instead of one wide table, I create a `fact_trips` table containing measurements (fare, distance, duration) and foreign keys, plus dimension tables (`dim_zones`, `dim_date`, `dim_payment_type`) containing descriptive attributes. Analysts join these to answer business questions. I build this layer using dbt (covered in Chapter 5).

---

## Folder Structure Design — Hive Partitioning

Inside the bronze container, I structured folders like this:

```
bronze/
└── yellow_taxi/
    └── year=2024/
        └── month=01/
            └── yellow_tripdata_2024-01.parquet
```

The `year=` and `month=` naming convention is called **Hive partitioning**. It is not just an organisational preference — it has a direct performance impact. When I run a Synapse query filtered by `WHERE year = 2024 AND month = 01`, the query engine reads only the files in that specific folder rather than scanning the entire dataset. For 12 months of data, this reduces query time and cost by up to 92%.

I chose this partition structure because taxi business questions are almost always time-based: "how did last month compare to the month before?" Partitioning by year and month aligns the storage structure with how the data will actually be queried.

---

## Access Control — Why I Assigned a RBAC Role

When I first attempted to upload data using the Azure CLI, the upload was rejected with a permissions error despite being logged in as the account Owner. This is by design.

Azure separates **management permissions** (the ability to create and configure resources) from **data permissions** (the ability to read and write actual data). Being a subscription Owner grants management permissions but not data access by default. This two-layer permission model is called the Azure RBAC (Role-Based Access Control) system.

I resolved this by assigning myself the **Storage Blob Data Contributor** role on the storage account through Azure IAM (Identity and Access Management). This follows the principle of least privilege, rather than granting blanket access, I assigned only the specific role needed for the specific resource.

In a production environment, I would assign this role to a **service principal** (a non-human identity used by pipelines and automation) rather than my personal account, so that credentials can be rotated without affecting personal logins.

I encountered this same permission requirement again in Chapter 3 when connecting Azure Data Factory to this storage account, ADF's managed identity also needed the Storage Blob Data Contributor role assigned explicitly before it could write data. This is a pattern that repeats for every service that needs data access.

---

## What Is Actually in the Dataset

After downloading and inspecting the January 2024 Yellow Taxi parquet file using Python (pandas + pyarrow), I found the following. These findings directly informed the cleaning logic I designed for the Silver layer.

**File:** `yellow_tripdata_2024-01.parquet`
**Rows:** 2,964,624 trips
**Columns:** 19

| Column | Type | Null count | Notes |
|---|---|---|---|
| VendorID | int32 | 0 | Always present |
| tpep_pickup_datetime | datetime64 | 0 | Already proper timestamp — no casting needed |
| tpep_dropoff_datetime | datetime64 | 0 | Already proper timestamp — no casting needed |
| passenger_count | float64 | **140,162** | Vendor-level gap — see below |
| trip_distance | float64 | 0 | Critical business column — clean |
| RatecodeID | float64 | **140,162** | Vendor-level gap — same 140,162 rows |
| store_and_fwd_flag | object | **140,162** | Vendor-level gap — same 140,162 rows |
| PULocationID | int32 | 0 | Critical business column — clean |
| DOLocationID | int32 | 0 | Critical business column — clean |
| payment_type | int64 | 0 | Clean |
| fare_amount | float64 | 0 | Critical business column — clean |
| tip_amount | float64 | 0 | Clean |
| total_amount | float64 | 0 | Critical business column — clean |
| congestion_surcharge | float64 | **140,162** | Vendor-level gap — same 140,162 rows |
| Airport_fee | float64 | **140,162** | Vendor-level gap — same 140,162 rows |

### Key finding — the 140,162 null pattern

The fact that five completely different columns all have the exact same null count (140,162) is not a coincidence. This means one specific taxi vendor simply does not report these fields at all. It is a **vendor-level data gap**, not random missing data scattered across the dataset.

This is a meaningful distinction. If nulls were random (sensor failures, intermittent errors), I would need to decide whether to drop or impute each row individually. Because the nulls are structural (one vendor never sends these fields), I can safely drop these rows in the Silver layer without losing data from the other vendor — or I can choose to keep them and simply mark them as vendor-type-2 trips with known missing fields.

I chose to **drop rows where passenger_count is null** in my Silver cleaning logic, which cleanly removes all 140,162 affected rows at once and addresses all five null columns simultaneously — since they all belong to the same rows.

### Additional data quality issues found

Beyond the vendor gap, I also identified:
- Negative values in `trip_distance` and `fare_amount` — physically impossible, these are data entry errors that I filter out in Silver
- Some `tpep_pickup_datetime` values outside the expected January 2024 range, trips that were recorded in the wrong month, filtered in Silver
- `passenger_count` values of 0, a driver forgot to enter the count, also filtered in Silver

---

## Resources Created

| Resource | Name | Purpose |
|---|---|---|
| Storage account | adlsnyctaxide | ADLS Gen2 data lake with HNS enabled |
| Container | bronze | Raw, unmodified source files — append only |
| Container | silver | Cleaned and typed data |
| Container | gold | Business-ready star schema tables |
| IAM role assignment | Storage Blob Data Contributor (my account) | Grants my personal account data read/write access |
| IAM role assignment | Storage Blob Data Contributor (ADF identity) | Grants ADF pipeline data write access — added in Chapter 3 |

---

*Next: [Chapter 3 → Azure Data Factory — Building the Ingestion Pipeline](chapter3_adf_pipeline.md)*