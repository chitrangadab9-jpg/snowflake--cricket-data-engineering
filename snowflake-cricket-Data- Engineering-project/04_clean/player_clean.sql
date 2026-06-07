-- ============================================================
-- FILE: player_clean.sql
-- PURPOSE: Extract player names from nested JSON into a flat table
-- Layer: CLEAN
-- Source: cricket.raw.match_raw_tbl
-- Target: cricket.clean.player_clean_tbl
-- ============================================================

-- WHY LATERAL FLATTEN is needed:
-- info:players in the JSON looks like this:
--   { "India": ["Rohit", "Kohli", ...], "Australia": ["Smith", "Warner", ...] }
-- That is a nested structure — an outer object (teams) containing arrays (players).
-- LATERAL FLATTEN explodes it into one row per player per match.
-- First flatten unpacks the teams, second flatten unpacks each team's player list.

-- Step 1: Explore structure for one match (development query)
select
    raw.info:match_type_number::int as match_type_number,
    p.key::text as country,
    team.value::text as player_name
from cricket.raw.match_raw_tbl raw,
    lateral flatten (input => raw.info:players) p,
    lateral flatten (input => p.value) team
where raw.info:match_type_number = 4688;

-- Step 2: Create the clean player table for all matches
create or replace table cricket.clean.player_clean_tbl as
select
    raw.info:match_type_number::int as match_type_number,
    p.key::text as country,           -- team name (the outer JSON key)
    team.value::text as player_name,  -- each player inside the team array
    stg_file_name,
    stg_file_row_number,
    stg_file_hashkey,
    stg_modified_ts
from cricket.raw.match_raw_tbl raw,
    lateral flatten (input => raw.info:players) p,
    lateral flatten (input => p.value) team;

-- Add NOT NULL constraints
alter table cricket.clean.player_clean_tbl modify column match_type_number set not null;
alter table cricket.clean.player_clean_tbl modify column country set not null;
alter table cricket.clean.player_clean_tbl modify column player_name set not null;

-- Add foreign key back to match_detail_clean
alter table cricket.clean.player_clean_tbl
    add constraint fk_match_id foreign key (match_type_number)
    references cricket.clean.match_detail_clean (match_type_number);

-- Verify
select * from player_clean_tbl;
