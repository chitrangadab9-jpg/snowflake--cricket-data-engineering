-- ============================================================
-- FILE: stage_internal.sql
-- PURPOSE: Create internal named stage to hold uploaded JSON files
-- Layer: LAND
-- ============================================================

-- An internal stage is Snowflake-managed storage
-- You upload JSON files directly into Snowflake (no AWS needed)
-- This was the PRIMARY loading method in this project

create or replace stage cricket.land.my_stg;

-- After uploading files via Snowflake UI, verify they are visible:
list @my_stage;
list @my_stage/cricket/json;

-- Preview raw content of files before loading into a table
-- t.$1 = the entire JSON document loaded into one column
-- :meta, :info, :innings = drilling into specific JSON keys
select
    t.$1:meta::variant as meta,
    t.$1:info::variant as info,
    t.$1:innings::array as innings,
    metadata$filename as file_name,
    metadata$file_row_number int,
    metadata$file_content_key text,
    metadata$file_last_modified stg_modified_ts
from @my_stage/cricket/json (file_format => 'my_json_format') t;
