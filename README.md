# Cricket Data Engineering Pipeline — Snowflake

An end-to-end data engineering project built on real IPL (Indian Premier League) match data. Raw JSON files are ingested, transformed through a layered architecture, and served as a star schema for analytics and reporting.

---

## Table of Contents

- [Project Overview](#project-overview)
- [Tech Stack](#tech-stack)
- [Architecture](#architecture)
- [Pipeline Layers](#pipeline-layers)
- [Star Schema](#star-schema)
- [Ingestion Methods](#ingestion-methods)
- [Automation — Streams and Tasks](#automation--streams-and-tasks)
- [Project Structure](#project-structure)
- [How to Run](#how-to-run)
- [Data Source](##Data-Source)

---

## Project Overview

This project demonstrates a production-style data pipeline built entirely inside Snowflake. The source data consists of JSON match files from IPL cricket tournaments. Each file contains nested structures — match metadata, player lists, and ball-by-ball delivery data — that are extracted, cleaned, and modelled into a star schema ready for analytics.

The project showcases two separate ingestion paths running in parallel:
- An **internal stage with a scheduled Task** for manual file uploads
- An **AWS S3 external stage with Snowpipe** for event-driven auto-ingestion

Both paths load into the same raw table, so all downstream transformations work identically regardless of which path brought the data in.

---

## Tech Stack

| Tool | Purpose |
|------|---------|
| Snowflake | Cloud data warehouse — all processing and storage |
| SQL | All transformations written in Snowflake SQL |
| AWS S3 | External storage for the Snowpipe ingestion path |
| AWS IAM | Role-based access control for Snowflake ↔ S3 trust |
| Snowpipe | Event-driven auto-ingestion from S3 |
| Snowflake Tasks | Scheduled automation of the transformation pipeline |
| Snowflake Streams | Change data capture — tracks new rows between pipeline runs |
| Power BI | Connected to consumption layer for dashboards |

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      DATA SOURCES                       │
│              IPL match JSON files (48 matches)          │
└───────────────┬─────────────────────┬───────────────────┘
                │                     │
                ▼                     ▼
   ┌────────────────────┐   ┌──────────────────────┐
   │   Internal Stage   │   │      AWS S3 Bucket    │
   │      (my_stg)      │   │   (snow-bucket123)    │
   └────────┬───────────┘   └──────────┬────────────┘
            │                          │
            │  Task (every 5 min)      │  Snowpipe (instant)
            │                          │  Storage Integration
            ▼                          ▼  IAM Role
┌───────────────────────────────────────────────────────┐
│                    LAND SCHEMA                        │
│         File Format · Internal Stage · External Stage │
└───────────────────────────┬───────────────────────────┘
                            │  COPY INTO
                            ▼
┌───────────────────────────────────────────────────────┐
│                     RAW SCHEMA                        │
│                   match_raw_tbl                       │
│         (meta | info | innings — as VARIANT)          │
│              + 3 Streams (append only)                │
└───────┬───────────────┬───────────────┬───────────────┘
        │               │               │
        ▼               ▼               ▼
┌────────────┐  ┌──────────────┐  ┌──────────────────┐
│match_detail│  │ player_clean │  │ delivery_clean   │
│   _clean   │  │    _tbl      │  │     _tbl         │
└────────────┘  └──────────────┘  └──────────────────┘
        │               │               │
        └───────────────┴───────────────┘
                        │  Tasks (chained)
                        ▼
┌───────────────────────────────────────────────────────┐
│                 CONSUMPTION SCHEMA                    │
│                                                       │
│  date_dim    team_dim    venue_dim   match_type_dim   │
│  player_dim  referee_dim                              │
│                                                       │
│         match_fact    delivery_fact                   │
│         (Fact Constellation / Galaxy Schema)          │
└───────────────────────────────────────────────────────┘
                        │
                        ▼ live connection
                    Power BI Dashboard
```

---

## Pipeline Layers

### LAND schema
The entry point. No data transformation happens here — this layer only defines the infrastructure for receiving files.

- `my_json_format` — file format object telling Snowflake how to parse the JSON (strip outer array, handle nulls)
- `my_stg` — internal named stage where files are uploaded manually via Snowflake UI or SnowSQL
- `my_s3_cricket_stage` — external stage pointing to the S3 bucket via Storage Integration

### RAW schema
Data is loaded exactly as it arrives — no flattening, no type casting. The three root keys of each JSON file (`meta`, `info`, `innings`) are extracted into separate columns but kept as Snowflake semi-structured types (OBJECT, VARIANT, ARRAY).

```sql
CREATE OR REPLACE TRANSIENT TABLE cricket.raw.match_raw_tbl (
    meta                OBJECT    NOT NULL,
    info                VARIANT   NOT NULL,
    innings             ARRAY     NOT NULL,
    stg_file_name       TEXT      NOT NULL,
    stg_file_row_number INT       NOT NULL,
    stg_file_hashkey    TEXT      NOT NULL,
    stg_modified_ts     TIMESTAMP NOT NULL
);
```

Three append-only streams sit on this table — one per downstream process — so each transformation path independently tracks which rows it has and has not yet processed.

### CLEAN schema
Each JSON field is extracted, cast to a proper data type, and written into flat relational tables. Three clean tables are produced:

- `match_detail_clean` — one row per match with all match-level fields (teams, venue, date, toss, result, season)
- `player_clean_tbl` — one row per player per match, produced using `LATERAL FLATTEN` on the nested players object
- `delivery_clean_tbl` — one row per ball bowled, produced using three levels of `LATERAL FLATTEN` (innings → overs → deliveries), including extras and wickets

### CONSUMPTION schema
The final star schema layer. Dimension tables are populated first, then fact tables are built by joining the clean tables to the dimensions. Only new rows are inserted on each run (anti-join pattern using `LEFT JOIN ... WHERE b.id IS NULL`).

---

## Star Schema

```
                        date_dim
                           │
         venue_dim ────────┤
                           │
         team_dim ─────────┼──── match_fact ──── delivery_fact ──── player_dim
         (x4 FKs)          │         │
                           │         └──── team_dim
    match_type_dim ────────┤
                           │
         referee_dim ──────┘
```

**match_fact** — grain: one row per match
Stores team scores, wickets lost, overs played, toss result, match result, and foreign keys to all six dimension tables.

**delivery_fact** — grain: one row per ball bowled
Stores individual delivery details: runs, extras, dismissal type, and foreign keys to player_dim (bowler, batter, non-striker) and team_dim.

This is a **Fact Constellation** (Galaxy Schema) — two fact tables at different grains sharing common dimension tables.

---

## Ingestion Methods

### Path 1 — Internal Stage + Scheduled Task

```
JSON files → Snowflake UI upload → my_stg → Task (5 min) → COPY INTO → match_raw_tbl
```

A Snowflake Task runs every 5 minutes and executes a `COPY INTO` statement. Snowflake internally tracks which files have already been loaded using the file content hash (`metadata$file_content_key`), so re-running never creates duplicates.

### Path 2 — AWS S3 + Snowpipe (Event-driven)

```
JSON files → S3 bucket → SQS notification → Snowpipe → COPY INTO → match_raw_tbl
```

Steps to set up:
1. Create an IAM Role in AWS with S3 read permissions
2. Create a Storage Integration in Snowflake (`cricket_s3_integration`)
3. Run `DESC INTEGRATION` to get Snowflake's IAM identity
4. Update the IAM Role trust policy with Snowflake's identity
5. Create an External Stage pointing to the S3 bucket
6. Create a Snowpipe with `AUTO_INGEST = TRUE`
7. Copy the SQS ARN from `SHOW PIPES` and configure S3 Event Notifications

```sql
CREATE OR REPLACE STORAGE INTEGRATION cricket_s3_integration
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::YOUR_ACCOUNT_ID:role/snowflake_cricket_role'
    STORAGE_ALLOWED_LOCATIONS = ('s3://YOUR_BUCKET_NAME/cricket/');
```

Both paths load into the same `match_raw_tbl`. All downstream processing is identical regardless of which path was used.

---

## Automation — Streams and Tasks

The entire pipeline from raw → clean → consumption runs automatically via a chained task tree.

```
load_json_to_raw              ← root task, runs every 5 min
        │
        ▼ (when for_match_stream has data)
load_to_clean_match
        │
        ▼ (when for_player_stream has data)
load_to_clean_player
        │
        ▼ (when for_delivery_stream has data)
load_to_clean_delivery
        │
        ├──────────────────┬──────────────────┐
        ▼                  ▼                  ▼
load_to_team_dim   load_to_player_dim  load_to_venue_dim
        │                  │                  │
        └──────────────────┴──────────────────┘
                           │
                           ▼
                   load_match_fact
                           │
                           ▼
                  load_delivery_fact
```

Each task only runs when its upstream stream contains new data (`SYSTEM$STREAM_HAS_DATA`), so the pipeline is completely idle-safe — no wasted compute when there are no new files.

---

## Project Structure

```
snowflake-cricket-data-engineering/
│
├── 01_setup/
│   └── database_schema_setup.sql      # database, schemas, warehouse
│
├── 02_land/
│   ├── file_format.sql                # JSON file format definition
│   ├── stage_internal.sql             # internal named stage
│   └── stage_external_s3.sql          # storage integration + external stage + Snowpipe
│
├── 03_raw/
│   ├── match_raw_table.sql            # transient table + COPY INTO
│   ├── task_load.sql                  # all 9 tasks + 3 streams
│   └── snowpipe.sql                   # Snowpipe setup and verification
│
├── 04_clean/
│   ├── match_detail_clean.sql         # flatten match info JSON
│   ├── player_clean.sql               # LATERAL FLATTEN on players
│   └── delivery_clean.sql             # 3-level LATERAL FLATTEN on innings
│
├── 05_consumption/
│   ├── dimensions.sql                 # all 6 dimension tables + inserts
│   ├── match_fact_table.sql           # match-level fact table
│   └── delivery_fact.sql              # ball-level fact table
│
├── architecture/
│   ├── pipeline_architecture.png      # end-to-end pipeline diagram
│   └── star_schema.png                # consumption layer schema diagram
│
└── README.md
```

---

## How to Run

Run the SQL files in this exact order inside Snowflake:

```
1. 01_setup/database_schema_setup.sql
2. 02_land/file_format.sql
3. 02_land/stage_internal.sql
4. Upload JSON files to the internal stage via Snowflake UI
5. 03_raw/match_raw_table.sql
6. 04_clean/match_detail_clean.sql
7. 04_clean/player_clean.sql
8. 04_clean/delivery_clean.sql
9. 05_consumption/dimensions.sql
10. 05_consumption/match_fact_table.sql
11. 05_consumption/delivery_fact.sql
12. 03_raw/task_load.sql               (for automation)
13. 02_land/stage_external_s3.sql      (for S3 + Snowpipe path)
```

> **Note:** For the S3 path, replace `YOUR_AWS_ACCOUNT_ID` and `YOUR_BUCKET_NAME` with your actual values before running `stage_external_s3.sql`.

---

## Key Concepts Demonstrated

- **Layered architecture** — LAND → RAW → CLEAN → CONSUMPTION separation of concerns
- **Semi-structured data** — JSON parsing using `VARIANT`, `OBJECT`, `ARRAY` and the `:` notation
- **LATERAL FLATTEN** — unpacking nested arrays (players, innings, overs, deliveries) into rows
- **COPY INTO** — bulk loading with automatic duplicate detection via file hash
- **Streams** — append-only change tracking for incremental processing
- **Tasks** — chained scheduled automation with conditional execution
- **Storage Integration** — secure Snowflake ↔ AWS trust without hardcoded credentials
- **Snowpipe** — event-driven ingestion triggered by S3 object creation
- **Star schema** — surrogate keys, foreign key constraints, fact constellation pattern
- **Anti-join insert pattern** — idempotent inserts that never create duplicates

## Data Source

Raw match data sourced from **[Cricsheet](https://cricsheet.org)** — the most widely 
used open source cricket data archive in the world.

- **Format:** JSON, one file per match
- **Match type:** Men's One Day Internationals (ODI)
- **Direct download:** https://cricsheet.org/downloads/odis_json.zip
- **Full dataset:** 2,538 Men's ODI matches
- **Matches used in this project:** 33 JSON files as a sample subset
