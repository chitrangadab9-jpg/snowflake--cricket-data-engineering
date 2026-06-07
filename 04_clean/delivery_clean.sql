-- ============================================================
-- FILE: delivery_clean.sql
-- PURPOSE: Extract ball-by-ball delivery data from nested innings JSON
-- Layer: CLEAN
-- Source: cricket.raw.match_raw_tbl
-- Target: cricket.clean.delivery_clean_tbl
-- ============================================================

-- WHY three levels of LATERAL FLATTEN:
-- innings is an ARRAY of innings objects
--   each innings has an overs ARRAY
--     each over has a deliveries ARRAY
-- You need one FLATTEN per level to unpack all the way down to one row per ball.

use database cricket;
use schema clean;

-- Explore structure step by step (development queries)

-- Level 1: see innings
select
    m.info:match_type_number::int as match_type_number,
    i.value:team::text as team_name,
    i.*
from cricket.raw.match_raw_tbl m,
    lateral flatten (input => m.innings) i
where m.info:match_type_number = 4680;

-- Level 2: see overs
select
    m.info:match_type_number::int as match_type_number,
    i.value:team::text as team_name,
    o.*
from cricket.raw.match_raw_tbl m,
    lateral flatten (input => m.innings) i,
    lateral flatten (input => i.value:overs) o
where m.info:match_type_number = 4680;

-- Level 3: see individual deliveries with extras
select
    m.info:match_type_number::int as match_type_number,
    i.value:team::text as team_name,
    o.value:over::int as over,
    d.value:bowler::text as bowler,
    d.value:batter::text as batter,
    d.value:non_striker::text as non_striker,
    d.value:runs.batter::text as runs,
    d.value:runs.extras::text as extras,
    d.value:runs.total::text as total,
    e.key::text as extra_type,
    e.value::number as extra_runs
from cricket.raw.match_raw_tbl m,
    lateral flatten (input => m.innings) i,
    lateral flatten (input => i.value:overs) o,
    lateral flatten (input => o.value:deliveries) d,
    lateral flatten (input => d.value:extras, outer => true) e   -- outer=true keeps rows even if no extras
where m.info:match_type_number = 4680;

-- Create the clean delivery table for all matches (includes wickets too)
create or replace transient table cricket.clean.delivery_clean_tbl as
select
    m.info:match_type_number::int as match_type_number,
    i.value:team::text as team_name,
    o.value:over::int as over,
    d.value:bowler::text as bowler,
    d.value:batter::text as batter,
    d.value:non_striker::text as non_striker,
    d.value:runs.batter::text as runs,
    d.value:runs.extras::text as extras,
    d.value:runs.total::text as total,
    e.key::text as extra_type,
    e.value::number as extra_runs,
    w.value:player_out::text as player_out,         -- who got out
    w.value:kind::text as player_out_kind,           -- how they got out (caught, bowled etc.)
    w.value:fielders::variant as player_out_fielders,
    m.stg_file_name,
    m.stg_file_row_number,
    m.stg_file_hashkey,
    m.stg_modified_ts
from cricket.raw.match_raw_tbl m,
    lateral flatten (input => m.innings) i,
    lateral flatten (input => i.value:overs) o,
    lateral flatten (input => o.value:deliveries) d,
    lateral flatten (input => d.value:extras, outer => true) e,
    lateral flatten (input => d.value:wickets, outer => true) w;  -- outer=true keeps non-wicket balls

-- Add NOT NULL constraints
alter table cricket.clean.delivery_clean_tbl modify column match_type_number set not null;
alter table cricket.clean.delivery_clean_tbl modify column team_name set not null;
alter table cricket.clean.delivery_clean_tbl modify column over set not null;
alter table cricket.clean.delivery_clean_tbl modify column bowler set not null;
alter table cricket.clean.delivery_clean_tbl modify column batter set not null;

-- Add foreign key back to match_detail_clean
alter table cricket.clean.delivery_clean_tbl
    add constraint fk_delivery_match_id foreign key (match_type_number)
    references cricket.clean.match_detail_clean (match_type_number);

-- Verify and explore
select * from delivery_clean_tbl;
desc table cricket.clean.delivery_clean_tbl;

-- Sample analysis query — runs and wickets per team for one match
select team_name, batter, sum(runs)
from delivery_clean_tbl
where match_type_number = 4686
group by team_name, batter
order by 1, 2, 3 desc;

select team_name, sum(runs) + sum(extra_runs)
from delivery_clean_tbl
where match_type_number = 4686
group by team_name
order by 1, 2 desc;
