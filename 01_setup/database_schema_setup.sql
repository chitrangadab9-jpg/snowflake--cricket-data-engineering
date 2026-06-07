-- ============================================================
-- FILE: database_schema_setup.sql
-- PURPOSE: Create the database, schemas, and set the context
-- RUN THIS FIRST before any other file
-- ============================================================

use role accountadmin;

use warehouse compute_wh;

-- Create the main database
create or replace database cricket;

-- Create the 4 schema layers
-- Each schema = one stage in the data pipeline
create or replace schema land;          -- where files are staged
create or replace schema raw;           -- raw JSON loaded into tables
create or replace schema cricket.clean;         -- flattened and typed data
create or replace schema cricket.consumption;   -- final star schema for analytics

use schema cricket.land;

-- Verify all schemas are created
show schemas;
