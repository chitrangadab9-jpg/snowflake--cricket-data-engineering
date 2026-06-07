-- ============================================================
-- FILE: match_detail_clean.sql
-- PURPOSE: Flatten the nested JSON info field into typed columns
-- Layer: CLEAN
-- Source: cricket.raw.match_raw_tbl
-- Target: cricket.clean.match_detail_clean
-- ============================================================

-- WHY this layer exists:
-- In the RAW table, all match info sits inside one VARIANT column called "info".
-- To filter by city, group by season, or join to dimensions, we need
-- each field extracted as its own properly typed column.
-- CTAS (Create Table As Select) = creates table and fills it in one shot.

use database cricket;
use schema clean;

create or replace transient table cricket.clean.match_detail_clean as
select
    info:match_type_number::int as match_type_number,
    info:event.name::text as event_name,

    -- match_stage: some matches have a "stage" (e.g. Final, Semi Final)
    -- others only have a match_number. Pick whichever is present.
    case
        when info:event.match_number::text is not null then info:event.match_number::text
        when info:event.stage::text is not null then info:event.stage::text
        else 'NA'
    end as match_stage,

    -- dates[0] = first date (some matches span multiple days)
    info:dates[0]::date as event_date,
    date_part('year',info:dates[0]::date) as event_year,
    date_part('month',info:dates[0]::date) as event_month,
    date_part('day',info:dates[0]::date) as event_day,

    info:match_type::text as match_type,       -- T20, ODI, Test etc.
    info:season::text as season,
    info:team_type::text as team_type,         -- international or domestic
    info:overs::text as overs,
    info:city::text as city,
    info:venue::text as venue,
    info:gender::text as gender,

    info:teams[0]::text as first_team,         -- teams[0] and [1] = two playing teams
    info:teams[1]::text as second_team,

    -- Classify the result into a clean readable label
    case
        when info:outcome.winner is not null then 'Result Declared'
        when info:outcome.result = 'tie' then 'Tie'
        when info:outcome.result = 'no result' then 'No Result'
        else info:outcome.result
    end as match_result,

    -- Winner is team name, or 'NA' if no result
    case
        when info:outcome.winner is not null then info:outcome.winner
        else 'NA'
    end as winner,

    info:toss.winner::text as toss_winner,
    initcap(info:toss.decision::text) as toss_decision,  -- INITCAP capitalises first letter

    -- Carry stage metadata forward for lineage tracking
    stg_file_name,
    stg_file_row_number,
    stg_file_hashkey,
    stg_modified_ts

from cricket.raw.match_raw_tbl;

-- Add primary key constraint
alter table cricket.clean.match_detail_clean
    add constraint pk_match_type_number primary key (match_type_number);

-- Verify
select * from cricket.clean.match_detail_clean;
