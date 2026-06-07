-- ============================================================
-- FILE: file_format.sql
-- PURPOSE: Define how Snowflake should parse the cricket JSON files
-- Layer: LAND
-- ============================================================

-- A File Format is a reusable object that tells Snowflake the rules
-- for reading a file. We create it once here and reuse it in:
--   the internal stage, external S3 stage, Snowpipe, and COPY INTO

create or replace file format cricket.land.my_json_format
  type = json
  null_if = ('\\n', 'null', '')
  strip_outer_array = true;  -- removes outer [ ] if the file is a JSON array

-- Verify it was created
show file formats in schema cricket.land;
