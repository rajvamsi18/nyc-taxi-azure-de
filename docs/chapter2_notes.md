# Chapter 2 — ADLS Gen2 Data Lake Setup

## What was built
- Storage account: adlsnyctaxide (ADLS Gen2, HNS enabled, East US 2, LRS)
- Resource group: rg-nyctaxi-de
- Containers: bronze, silver, gold (all private access)
- Medallion architecture implemented
- First dataset uploaded: NYC Yellow Taxi Jan 2024 (2.9M rows)

## Folder structure
bronze/yellow_taxi/year=2024/month=01/ — raw parquet files
silver/trips/ — cleaned files (Chapter 3 onwards)
gold/fact_trips/, gold/dim_zones/ — business layer (Chapter 5 onwards)

## Key concepts
- Hierarchical Namespace enabled = true ADLS Gen2
- Hive partitioning (year=/month=) for query performance
- Bronze = never modified, Silver = cleaned, Gold = business-ready
