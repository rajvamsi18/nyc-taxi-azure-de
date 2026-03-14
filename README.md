# NYC Taxi Analytics Platform — Azure Data Engineering Project

> An end-to-end data engineering pipeline built on Microsoft Azure, transforming 100M+ real NYC taxi trip records into a business-ready analytics platform that answers operational questions about revenue, demand, and driver allocation.

---

## Why I Built This

Data without infrastructure is just noise. This project exists because most data engineering portfolios show *what* tools were used — but not *why* decisions were made, *what* problems were solved, or *how* the data actually flows through a real system.

I built this platform to demonstrate that I can take a real, messy, publicly available dataset, design an architecture for it from scratch, implement it on Azure using industry-standard tools, and produce business value from it — the way a professional data engineer would on the job.

The business scenario I designed around: **UrbanMove**, a fictional taxi aggregator operating in New York City, needed answers to three operational questions their team could not answer because their data was scattered, uncleaned, and inaccessible:

1. **Which pickup zones generate the most revenue, and when?** — to optimise driver allocation
2. **What hours and days see peak demand?** — to inform surge pricing decisions
3. **How has average trip duration trended over 2024?** — to benchmark operational efficiency

These are not hypothetical questions. They are the kind of questions that data teams at Uber, Lyft, and Ola answer every day using exactly this kind of pipeline.

---

## Architecture

![Architecture Diagram](docs/architecture.png)

The platform is built on a **medallion architecture** — an industry-standard pattern where data passes through three progressively refined zones:

- **Bronze** — raw data, exactly as downloaded from the source. Never modified. My insurance policy.
- **Silver** — cleaned data. Nulls removed, data types enforced, outliers filtered.
- **Gold** — business-ready tables. Star schema modelled with dbt, ready for analysts to query.

---

## Tech Stack and Why I Chose Each Tool

| Layer | Tool | Why I chose it |
|---|---|---|
| Storage | Azure Data Lake Storage Gen2 | Industry standard for Azure-based data lakes. Hierarchical namespace enables true folder semantics, critical for Hive-style partitioning at scale. |
| Ingestion | Azure Data Factory | Native Azure orchestration tool. Most commonly asked about in Azure DE interviews. Handles HTTP connectors, scheduling, and retry logic without writing server code. |
| Transformation | dbt Core (open source) | The current industry standard for SQL-based data transformation. Brings software engineering practices (version control, testing, documentation) to SQL. Free and widely adopted. |
| Query engine | Azure Synapse Analytics (serverless) | Lets me run SQL directly against parquet files in my data lake without provisioning a dedicated cluster. At our data volume, costs pennies per query — far cheaper than a dedicated Databricks cluster. |
| Visualisation | Power BI Desktop | Free, integrates natively with Synapse and Azure, produces professional dashboards. |
| Orchestration | ADF Triggers + GitHub Actions | ADF handles pipeline scheduling. GitHub Actions runs dbt tests automatically on every code push — this is CI/CD for data. |
| Version control | Git + GitHub | Every pipeline config, SQL model, and transformation is version-controlled. The platform is fully reproducible from this repo alone. |

---

## Dataset

**Source:** NYC Taxi & Limousine Commission (TLC) Trip Record Data
**URL:** https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page
**Scope:** Yellow taxi trips, full year 2024 (12 months)
**Volume:** ~30 million rows, ~1.5GB in Parquet format
**License:** Publicly available, free to use

Each row represents one taxi trip and contains: pickup/dropoff timestamps, pickup/dropoff location zone IDs, trip distance, fare amount, tip amount, total amount, payment type, and passenger count.

---

## Project Structure

```
nyc-taxi-azure-de/
├── README.md                          ← you are here
├── docs/
│   ├── architecture.png               ← system architecture diagram
│   ├── chapter2_adls_setup.md         ← data lake design decisions
│   ├── chapter3_adf_pipeline.md       ← ingestion pipeline decisions
│   ├── chapter4_synapse_queries.md    ← transformation decisions
│   ├── chapter5_dbt_models.md        ← data modeling decisions
│   └── screenshots/                   ← ADF run history, query results, dashboards
├── ingestion/
│   └── adf_pipeline.json              ← exported ADF pipeline definition
├── transformation/
│   └── dbt_project/
│       ├── dbt_project.yml
│       ├── models/
│       │   ├── staging/               ← bronze → silver models
│       │   └── marts/                 ← silver → gold models
│       └── tests/                     ← data quality tests
├── sql/
│   └── synapse_queries.sql            ← analytical queries against gold layer
└── .github/
    └── workflows/
        └── dbt_ci.yml                 ← runs dbt tests on every push to main
```

---

## How to Reproduce This Project

All Azure infrastructure can be recreated from scratch using the configurations in this repo. The data pipeline is fully code-defined — nothing was built by clicking buttons that isn't also captured as code here.

**Prerequisites:** Azure account (Pay-As-You-Go, ~$3 estimated total cost), Python 3.9+, dbt Core, Azure CLI

**Step 1 — Clone this repo**
```bash
git clone https://github.com/YOUR_USERNAME/nyc-taxi-azure-de.git
cd nyc-taxi-azure-de
```

**Step 2 — Create the Azure resource group**
```bash
az login
az group create --name rg-nyctaxi-de --location eastus2
```

**Step 3 — Create the storage account and containers**
```bash
az storage account create \
  --name adlsnyctaxide \
  --resource-group rg-nyctaxi-de \
  --location eastus2 \
  --sku Standard_LRS \
  --enable-hierarchical-namespace true
```

**Step 4 — Follow the chapter docs** in `/docs` for the remaining setup steps.

---

## Results and Business Insights

*(This section will be populated at the end of the project with dashboard screenshots and key findings)*

---

## What I Learned

*(To be written at project completion)*

---

## Acknowledgements

This project was built as a self-directed learning exercise in Azure Data Engineering. Throughout the build, I used **Claude (by Anthropic)** as a learning tutor and technical guide — helping me understand concepts from first principles, debug Azure CLI issues, and think through architectural decisions.

The learning approach, architectural choices, hands-on implementation, and all code in this repository are my own work. Claude served the same role a senior engineer or technical mentor would in a real team — explaining the *why* behind decisions, not making them for me.

---

*Built by Rajvamsi Chenna · March 2026*