-- ============================================================
-- FILE: match_raw_table.sql
-- PURPOSE: Create raw landing table and load JSON files into it
-- Layer: RAW
-- ============================================================

-- TRANSIENT: No fail-safe storage — saves cost.
-- Raw data can always be reloaded from the stage files.
-- The 3 JSON columns store the entire nested structure as-is.
-- No flattening here — that happens in the CLEAN layer.

create or replace transient table cricket.raw.match_raw_tbl (
    meta                object    not null,   -- { } JSON object e.g. version info
    info                variant   not null,   -- all match details: teams, venue, toss, result
    innings             array     not null,   -- ball-by-ball data for all innings
    stg_file_name       text      not null,   -- source file path (for lineage)
    stg_file_row_number int       not null,   -- row position within the file
    stg_file_hashkey    text      not null,   -- file fingerprint (COPY INTO uses this to avoid reloading)
    stg_modified_ts     timestamp not null    -- when the file was last modified on stage
);

-- Load all JSON files from internal stage into the raw table.
-- COPY INTO is smart: uses stg_file_hashkey to track already-loaded files.
-- Running this again will NOT create duplicates — it skips loaded files.
-- ON_ERROR = CONTINUE: if one bad file fails, skip it and keep loading the rest.
-- Positional mapping: left column must match right SELECT value by position.

COPY INTO cricket.raw.match_raw_tbl (
    meta,
    info,
    innings,
    stg_file_name,
    stg_file_row_number,
    stg_file_hashkey,
    stg_modified_ts
)
FROM (
    SELECT
        t.$1:meta::variant,
        t.$1:info::variant,
        t.$1:innings::array,
        metadata$filename,
        metadata$file_row_number,
        metadata$file_content_key,
        metadata$file_last_modified
    FROM @my_stage/cricket/json (file_format => 'my_json_format') t
);

-- Verify the load
select count(*) from cricket.raw.match_raw_tbl;
select * from cricket.raw.match_raw_tbl;

-- Explore the raw JSON fields (used during development)
select
    meta['data_version']::text as data_version,
    meta['created']::date as created,
    meta['revision']::number as revision
from cricket.raw.match_raw_tbl;

select
    info:match_type_number::int as match_type_number,
    info:match_type::text as match_type,
    info:season::text as season,
    info:team_type::text as team_type,
    info:overs::text as overs,
    info:city::text as city,
    info:venue::text as venue
from cricket.raw.match_raw_tbl;
