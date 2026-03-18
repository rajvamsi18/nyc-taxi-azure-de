# Chapter 3 — Ingestion Pipeline: Azure Data Factory

## The Problem I Was Solving

In Chapter 2, I uploaded January 2024's taxi data manually using the Azure CLI one file, one command, one month. It worked. But the business requirement is 12 months of 2024 data, with new months arriving automatically going forward.

Running 12 separate curl commands by hand is not engineering, it is copying and pasting. More importantly, it does not scale, it cannot recover from failures automatically, and it leaves no audit trail of what ran and when. I needed a **pipeline**: a repeatable, scheduled, monitored process that moves data from the source to my data lake without manual intervention.

This is precisely what Azure Data Factory is built for.

---

## What Azure Data Factory Is — and What It Is Not

ADF is a **data movement and orchestration service**. Its job is to move data reliably from one place to another, on a schedule, and to tell you clearly when something goes wrong.

It is important to understand what ADF does *not* do. It does not transform or clean data (that is Synapse SQL and dbt's job in Chapters 4 and 5). It does not store data (that is ADLS Gen2's job from Chapter 2). ADF is purely the logistics layer, the truck that picks up raw data and delivers it to the warehouse, unchanged.

This separation of concerns is deliberate. Each tool does one thing well. ADF moves data. Synapse queries it. dbt transforms it. This is why modern data platforms are built from composable services rather than one monolithic tool.

---

## The Four Building Blocks of ADF

Every ADF pipeline is assembled from four concepts. Understanding these before touching the UI makes everything click into place.

**Linked Service** — a saved connection to an external system. Think of it as a contact card that stores the address and credentials for a data source or destination. I created two: one pointing to the NYC TLC website (the source), and one pointing to my ADLS Gen2 storage account (the destination).

**Dataset** — a description of the data at a specific location. It references a Linked Service and adds detail about the file format and path. A dataset does not hold data, it describes where data is and what shape it has.

**Pipeline** — the workflow itself. A container that holds one or more Activities arranged in a sequence. This is what I build, run, and monitor. My pipeline is named `pl_ingest_nyc_taxi_bronze`.

**Trigger** — the mechanism that starts a pipeline. A pipeline never runs by itself. A trigger fires it either on a schedule, in response to an event (like a file arriving), or manually. For testing I used a manual trigger. For production I configured a monthly schedule trigger.

---

## How I Designed the Pipeline

Before opening ADF Studio I designed the pipeline logic on paper first. This is a habit worth keeping, building before thinking leads to rework.

The pipeline needed to:
1. Accept a `year` parameter so the same pipeline can be reused for 2025, 2026, and beyond without modification
2. Loop over all 12 months automatically rather than having 12 separate copy activities
3. Build the source URL dynamically per month using the parameter and loop variable
4. Write the file to the correct Hive-partitioned folder in bronze automatically
5. Continue processing remaining months if one month fails, rather than stopping entirely

This design translates directly into ADF's activity types: a **pipeline parameter** for the year, a **ForEach activity** for the loop, and a **Copy activity** inside the loop for the actual data movement.

---

## Source URL — How I Confirmed It Before Building

Before building any pipeline I verified the source URL was live and accessible. I ran this from my Terminal:

```bash
curl -I "https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_2024-01.parquet"
```

The response confirmed `HTTP/2 200` with `content-length: 49961641` (~50MB per file). Two additional details from the response were worth noting:

- `x-amz-cf-pop: HYD57-P5` — the file was served from a CloudFront edge node in Hyderabad, meaning low latency for my downloads
- `x-cache: Hit from cloudfront` — the dataset is actively cached at the CDN edge, confirming it is a maintained, frequently-accessed public dataset

I also considered using the Azure Open Datasets version of this data (`azureopendatastorage.blob.core.windows.net/nyctlc/`), which would have kept all data transfer within the Azure network. However, that source stores data in multi-file partitions with auto-generated filenames (e.g. `part-00000-tid-8898858832658823408...snappy.parquet`), making dynamic file path construction in ADF significantly more complex. The TLC CloudFront source gives one clean file per month with a fully predictable naming pattern, which is the right trade-off for this architecture.

---

## Pipeline Configuration

### Linked Service 1 — Source (NYC TLC website)

```
Type:         HTTP
Name:         ls_http_nyc_tlc
Base URL:     https://d37ci6vzurychx.cloudfront.net
Auth type:    Anonymous
```

The base URL is just the domain. ADF appends the file path dynamically per month through the Copy activity's relative URL expression. The server requires no authentication, this is a public dataset.

### Linked Service 2 — Sink (ADLS Gen2)

```
Type:              Azure Data Lake Storage Gen2
Name:              ls_adls_nyctaxi
Auth method:       System Managed Identity
Storage account:   adlsnyctaxide
```

I chose **System Managed Identity** over Account Key authentication for a specific reason. An account key is a static secret, if it leaks (in a GitHub commit, a log file, a screenshot), the entire storage account is compromised. A Managed Identity is a certificate-based identity that Azure manages automatically. There is no password to rotate, no secret to accidentally expose. This is the production-grade approach and the one I would use on any real project.

**IAM role required:** When testing this connection I received a `Forbidden` error. This is the same two-layer Azure permission model I encountered in Chapter 2, being the account Owner does not automatically grant data access. I resolved this by assigning ADF's managed identity the **Storage Blob Data Contributor** role on `adlsnyctaxide` through Azure IAM. Once assigned (with ~60 seconds for propagation), the connection test returned green.

This is a pattern that repeats for every Azure service that touches data: each service identity must be explicitly granted the minimum role it needs. Documenting these assignments is part of good platform engineering.

### Pipeline Parameters

```
Parameter name:  p_year
Type:            String
Default value:   2024
```

By parameterising the year, the same pipeline can ingest 2025 data by simply passing `p_year = 2025` at trigger time, no modifications to the pipeline itself. This is the principle of **reusable, data-driven pipelines** rather than hardcoded ones.

### ForEach Activity

```
Name:      fe_loop_months
Items:     @createArray('01','02','03','04','05','06','07','08','09','10','11','12')
```

The `createArray` expression gives ADF a list of 12 items to loop over. For each item in that list, it runs the Copy activity inside it once. Zero-padded strings (`'01'` not `'1'`) match the file naming convention used by the TLC source.

### Copy Activity (inside the ForEach)

**Source — dynamic URL per month:**
```
Relative URL:
/trip-data/yellow_tripdata_@{pipeline().parameters.p_year}-@{item()}.parquet
```

For month `03`, this resolves to:
`/trip-data/yellow_tripdata_2024-03.parquet`

**Sink — dynamic path per month:**
```
Container:   bronze
Directory:   yellow_taxi/year=@{pipeline().parameters.p_year}/month=@{item()}
Filename:    yellow_tripdata_@{pipeline().parameters.p_year}-@{item()}.parquet
```

For month `03`, this writes to:
`bronze/yellow_taxi/year=2024/month=03/yellow_tripdata_2024-03.parquet`

This maintains the Hive-partitioned folder structure I established in Chapter 2, keeping the storage layer consistent and query-optimised.

---

## Running the Pipeline and What I Observed

I triggered the pipeline manually with `p_year = 2024` and monitored the run in ADF Studio's Monitor view. The pipeline processed all 12 months sequentially, taking approximately 10 minutes total. Each month's Copy activity showed the bytes transferred, rows read, and duration, ADF logs all of this automatically.

After the run completed, I verified in the Azure Portal that the bronze container contained 12 folders, each with one parquet file. The total ingested data was approximately 600MB across 12 files, consistent with the ~50MB per file I measured during the URL verification step.

---

## Infrastructure as Code — Exporting the Pipeline

One of the most important habits in data engineering is ensuring that infrastructure is reproducible from code, not from memory. After completing and testing the pipeline I exported it as an ARM (Azure Resource Manager) template from ADF Studio.

The export produced two files that I committed to this repository:

**`ingestion/adf_pipeline_arm_template.json`**, the complete pipeline definition. This JSON file describes every linked service, dataset, activity, and parameter in my ADF factory. Anyone with access to this repository can recreate the entire ingestion pipeline in a new Azure account with a single deployment command:

```bash
az deployment group create \
  --resource-group rg-nyctaxi-de \
  --template-file ingestion/adf_pipeline_arm_template.json \
  --parameters ingestion/adf_pipeline_parameters.json
```

**`ingestion/adf_pipeline_parameters.json`**, stores environment-specific values (like the storage account name) separately from the pipeline logic. This separation means the same template can be deployed to a development environment and a production environment by simply swapping the parameters file.

This approach — defining infrastructure as version-controlled JSON rather than as a set of manual Portal clicks, is called **Infrastructure as Code (IaC)**. It is a standard practice on professional data engineering teams because it makes platforms auditable, reproducible, and recoverable after disasters.

---

## What This Chapter Delivered

At the end of Chapter 3, my bronze container holds the complete 2024 NYC Yellow Taxi dataset — all 12 months, approximately 35 million trip records, stored in Hive-partitioned Parquet format. The data arrived there not through manual uploads but through a parameterised, reusable pipeline that can be re-triggered for any future year with no code changes.

The pipeline definition lives in GitHub. The data lives in ADLS Gen2. Azure needs to be running for the pipeline to execute, but the code that defines it is permanent.

---

## Resources Created

| Resource | Name | Purpose |
|---|---|---|
| ADF instance | adf-nyctaxi-de | Data factory — hosts all pipelines |
| Linked service | ls_http_nyc_tlc | Connection to NYC TLC CloudFront source |
| Linked service | ls_adls_nyctaxi | Connection to ADLS Gen2 bronze layer via Managed Identity |
| Dataset | ds_http_nyc_tlc_parquet | Describes the source parquet file shape and dynamic path |
| Dataset | ds_adls_bronze_parquet | Describes the sink parquet destination and dynamic path |
| Pipeline | pl_ingest_nyc_taxi_bronze | ForEach loop over 12 months with Copy activity |
| IAM role assignment | Storage Blob Data Contributor (ADF identity) | Grants ADF write access to adlsnyctaxide |

---

*Previous: [Chapter 2 → ADLS Gen2 Data Lake Setup](chapter2_adls_setup.md)*

*Next: [Chapter 4 → Synapse Analytics — Querying the Bronze Layer and Building Silver](chapter4_synapse_queries.md)*