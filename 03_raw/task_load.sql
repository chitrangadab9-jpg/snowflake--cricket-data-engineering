-- ============================================================
-- FILE: task_load.sql
-- PURPOSE: Automate the full pipeline using Streams and Tasks
-- Layer: RAW → CLEAN → CONSUMPTION
-- ============================================================

-- ---------------------------------------------------------------
-- STREAMS — Change trackers on the raw table
-- ---------------------------------------------------------------
-- A Stream sits on a table and tracks which rows are NEW.
-- It is like an "unread" marker on emails — once rows are processed,
-- the stream clears those marks. Next new rows get marked again.
-- We need 3 separate streams because 3 independent processes read
-- from the same raw table — each reads at its own pace.
-- APPEND_ONLY = TRUE: only track new inserts, not updates or deletes.

create or replace stream cricket.raw.for_match_stream
    on table cricket.raw.match_raw_tbl
    append_only = true;

create or replace stream cricket.raw.for_player_stream
    on table cricket.raw.match_raw_tbl
    append_only = true;

create or replace stream cricket.raw.for_delivery_stream
    on table cricket.raw.match_raw_tbl
    append_only = true;

-- ---------------------------------------------------------------
-- TASK 1: Load raw JSON from stage into match_raw_tbl (root task)
-- ---------------------------------------------------------------
-- Runs every 5 minutes automatically.
-- COPY INTO already tracks loaded files via hash — no duplicates.
-- No stream needed here because COPY INTO handles "what is new" itself.

create or replace task cricket.raw.load_json_to_raw
    warehouse = 'COMPUTE_WH'
    schedule = '5 minute'
as
copy into cricket.raw.match_raw_tbl
from (
    select
        t.$1:meta::object as meta,
        t.$1:info::variant as info,
        t.$1:innings::array as innings,
        metadata$filename,
        metadata$file_row_number,
        metadata$file_content_key,
        metadata$file_last_modified
    from @cricket.land.my_stg/cricket/json (file_format => 'cricket.land.my_json_format') t
)
on_error = continue;

-- ---------------------------------------------------------------
-- TASK 2: Load new raw rows into match_detail_clean
-- ---------------------------------------------------------------
-- Runs AFTER task 1. Only runs if for_match_stream has new rows.
-- Reads from the stream (not the full table) to get only new rows.

create or replace task cricket.raw.load_to_clean_match
    warehouse = 'COMPUTE_WH'
    after cricket.raw.load_json_to_raw
    when system$stream_has_data('cricket.raw.for_match_stream')
as
insert into cricket.clean.match_detail_clean
select
    info:match_type_number::int as match_type_number,
    info:event.name::text as event_name,
    case
        when info:event.match_number::text is not null then info:event.match_number::text
        when info:event.stage::text is not null then info:event.stage::text
        else 'NA'
    end as match_stage,
    info:dates[0]::date as event_date,
    date_part('year',info:dates[0]::date) as event_year,
    date_part('month',info:dates[0]::date) as event_month,
    date_part('day',info:dates[0]::date) as event_day,
    info:match_type::text as match_type,
    info:season::text as season,
    info:team_type::text as team_type,
    info:overs::text as overs,
    info:city::text as city,
    info:venue::text as venue,
    info:gender::text as gender,
    info:teams[0]::text as first_team,
    info:teams[1]::text as second_team,
    case
        when info:outcome.winner is not null then 'Result Declared'
        when info:outcome.result = 'tie' then 'Tie'
        when info:outcome.result = 'no result' then 'No Result'
        else info:outcome.result
    end as match_result,
    case
        when info:outcome.winner is not null then info:outcome.winner
        else 'NA'
    end as winner,
    info:toss.winner::text as toss_winner,
    initcap(info:toss.decision::text) as toss_decision,
    stg_file_name,
    stg_file_row_number,
    stg_file_hashkey,
    stg_modified_ts
from cricket.raw.for_match_stream;

-- ---------------------------------------------------------------
-- TASK 3: Load new raw rows into player_clean_tbl
-- ---------------------------------------------------------------

create or replace task cricket.raw.load_to_clean_player
    warehouse = 'COMPUTE_WH'
    after cricket.raw.load_to_clean_match
    when system$stream_has_data('cricket.raw.for_player_stream')
as
insert into cricket.clean.player_clean_tbl
select
    rcm.info:match_type_number::int as match_type_number,
    p.path::text as country,
    team.value::text as player_name,
    stg_file_name,
    stg_file_row_number,
    stg_file_hashkey,
    stg_modified_ts
from cricket.raw.for_player_stream rcm,
    lateral flatten (input => rcm.info:players) p,
    lateral flatten (input => p.value) team;

-- ---------------------------------------------------------------
-- TASK 4: Load new raw rows into delivery_clean_tbl
-- ---------------------------------------------------------------

create or replace task cricket.raw.load_to_clean_delivery
    warehouse = 'COMPUTE_WH'
    after cricket.raw.load_to_clean_player
    when system$stream_has_data('cricket.raw.for_delivery_stream')
as
insert into cricket.clean.delivery_clean_tbl
select
    m.info:match_type_number::int as match_type_number,
    i.value:team::text as team_name,
    o.value:over::int+1 as over,
    d.value:bowler::text as bowler,
    d.value:batter::text as batter,
    d.value:non_striker::text as non_striker,
    d.value:runs.batter::text as runs,
    d.value:runs.extras::text as extras,
    d.value:runs.total::text as total,
    e.key::text as extra_type,
    e.value::number as extra_runs,
    w.value:player_out::text as player_out,
    w.value:kind::text as player_out_kind,
    w.value:fielders::variant as player_out_fielders,
    m.stg_file_name,
    m.stg_file_row_number,
    m.stg_file_hashkey,
    m.stg_modified_ts
from cricket.raw.for_delivery_stream m,
    lateral flatten (input => m.innings) i,
    lateral flatten (input => i.value:overs) o,
    lateral flatten (input => o.value:deliveries) d,
    lateral flatten (input => d.value:extras, outer => true) e,
    lateral flatten (input => d.value:wickets, outer => true) w;

-- ---------------------------------------------------------------
-- TASK 5: Load new teams into team_dim
-- ---------------------------------------------------------------
-- MINUS = only insert teams that don't already exist in team_dim

create or replace task cricket.raw.load_to_team_dim
    warehouse = 'COMPUTE_WH'
    after cricket.raw.load_to_clean_delivery
as
insert into cricket.consumption.team_dim (team_name) (
    select distinct team_name from (
        select first_team as team_name from cricket.clean.match_detail_clean
        union all
        select second_team as team_name from cricket.clean.match_detail_clean
    )
    minus
    select team_name from cricket.consumption.team_dim
);

-- ---------------------------------------------------------------
-- TASK 6: Load new players into player_dim
-- ---------------------------------------------------------------

create or replace task cricket.raw.load_to_player_dim
    warehouse = 'COMPUTE_WH'
    after cricket.raw.load_to_clean_delivery
as
insert into cricket.consumption.player_dim (team_id, player_name) (
    select b.team_id, a.player_name
    from cricket.clean.player_clean_tbl a
    join cricket.consumption.team_dim b on a.country = b.team_name
    group by b.team_id, a.player_name
    minus
    select team_id, player_name from cricket.consumption.player_dim
);

-- ---------------------------------------------------------------
-- TASK 7: Load new venues into venue_dim
-- ---------------------------------------------------------------

create or replace task cricket.raw.load_to_venue_dim
    warehouse = 'COMPUTE_WH'
    after cricket.raw.load_to_clean_delivery
as
insert into cricket.consumption.venue_dim (venue_name, city) (
    select venue, city from (
        select
            venue,
            case when city is null then 'NA' else city end as city
        from cricket.clean.match_detail_clean
    )
    group by venue, city
    minus
    select venue_name, city from cricket.consumption.venue_dim
);

-- ---------------------------------------------------------------
-- TASK 8: Load match fact table
-- ---------------------------------------------------------------

CREATE OR REPLACE TASK cricket.raw.load_match_fact
    WAREHOUSE = 'COMPUTE_WH'
    AFTER cricket.raw.load_to_team_dim, cricket.raw.load_to_player_dim, cricket.raw.load_to_venue_dim
AS
INSERT INTO cricket.consumption.match_fact
SELECT a.* FROM (
    SELECT
        m.match_type_number as match_id,
        dd.date_id,
        rd.referee_id,
        ftd.team_id as first_team_id,
        std.team_id as second_team_id,
        mtd.match_type_id,
        vd.venue_id,
        50 as total_overs,
        6 as balls_per_overs,
        MAX(CASE WHEN d.team_name = m.first_team THEN d.over ELSE 0 END) as overs_played_by_team_a,
        SUM(CASE WHEN d.team_name = m.first_team THEN 1 ELSE 0 END) as balls_played_by_team_a,
        SUM(CASE WHEN d.team_name = m.first_team THEN d.extras ELSE 0 END) as extra_balls_played_by_team_a,
        SUM(CASE WHEN d.team_name = m.first_team THEN d.extra_runs ELSE 0 END) as extra_runs_scored_by_team_a,
        0 as fours_by_team_a,
        0 as sixes_by_team_a,
        (SUM(CASE WHEN d.team_name = m.first_team THEN d.runs ELSE 0 END) +
         SUM(CASE WHEN d.team_name = m.first_team THEN d.extra_runs ELSE 0 END)) as total_runs_scored_by_team_a,
        SUM(CASE WHEN d.team_name = m.first_team AND player_out IS NOT NULL THEN 1 ELSE 0 END) as wicket_lost_by_team_a,
        MAX(CASE WHEN d.team_name = m.second_team THEN d.over ELSE 0 END) as overs_played_by_team_b,
        SUM(CASE WHEN d.team_name = m.second_team THEN 1 ELSE 0 END) as balls_played_by_team_b,
        SUM(CASE WHEN d.team_name = m.second_team THEN d.extras ELSE 0 END) as extra_balls_played_by_team_b,
        SUM(CASE WHEN d.team_name = m.second_team THEN d.extra_runs ELSE 0 END) as extra_runs_scored_by_team_b,
        0 as fours_by_team_b,
        0 as sixes_by_team_b,
        (SUM(CASE WHEN d.team_name = m.second_team THEN d.runs ELSE 0 END) +
         SUM(CASE WHEN d.team_name = m.second_team THEN d.extra_runs ELSE 0 END)) as total_runs_scored_by_team_b,
        SUM(CASE WHEN d.team_name = m.second_team AND player_out IS NOT NULL THEN 1 ELSE 0 END) as wicket_lost_by_team_b,
        tw.team_id as toss_winner_team_id,
        m.toss_decision,
        m.match_result,
        mw.team_id as winner_team_id
    FROM cricket.clean.match_detail_clean m
    JOIN cricket.raw.match_raw_tbl mr ON m.match_type_number = mr.info:match_type_number::int
    JOIN cricket.consumption.referee_dim rd ON mr.info:officials.match_referees[0]::text = rd.referee_name
    JOIN cricket.consumption.date_dim dd ON m.event_date = dd.full_dt
    JOIN cricket.consumption.team_dim ftd ON m.first_team = ftd.team_name
    JOIN cricket.consumption.team_dim std ON m.second_team = std.team_name
    JOIN cricket.consumption.match_type_dim mtd ON m.match_type = mtd.match_type
    JOIN cricket.consumption.venue_dim vd ON m.venue = vd.venue_name AND m.city = vd.city
    JOIN cricket.clean.delivery_clean_tbl d ON d.match_type_number = m.match_type_number
    JOIN cricket.consumption.team_dim tw ON m.toss_winner = tw.team_name
    JOIN cricket.consumption.team_dim mw ON m.winner = mw.team_name
    GROUP BY
        m.match_type_number, dd.date_id, rd.referee_id,
        first_team_id, second_team_id, mtd.match_type_id, vd.venue_id,
        total_overs, toss_winner_team_id, m.toss_decision, m.match_result, winner_team_id
) a
LEFT JOIN cricket.consumption.match_fact b ON a.match_id = b.match_id
WHERE b.match_id IS NULL;

-- ---------------------------------------------------------------
-- TASK 9: Load delivery fact table
-- ---------------------------------------------------------------

create or replace task cricket.raw.load_delivery_fact
    warehouse = 'COMPUTE_WH'
    after cricket.raw.load_match_fact
as
insert into cricket.consumption.delivery_fact
select a.* from (
    select
        d.match_type_number as match_id,
        td.team_id,
        bpd.player_id as bowler_id,
        spd.player_id as batter_id,
        nspd.player_id as non_striker_id,
        d.over,
        d.runs,
        case when d.extra_runs is null then 0 else d.extra_runs end as extra_runs,
        case when d.extra_type is null then 'None' else d.extra_type end as extra_type,
        case when d.player_out is null then 'None' else d.player_out end as player_out,
        case when d.player_out_kind is null then 'None' else d.player_out_kind end as player_out_kind
    from cricket.clean.delivery_clean_tbl d
    join cricket.consumption.team_dim td on d.team_name = td.team_name
    join cricket.consumption.player_dim bpd on d.bowler = bpd.player_name
    join cricket.consumption.player_dim spd on d.batter = spd.player_name
    join cricket.consumption.player_dim nspd on d.non_striker = nspd.player_name
) a
left join cricket.consumption.delivery_fact b on a.match_id = b.match_id
where b.match_id is null;

-- ---------------------------------------------------------------
-- IMPORTANT: Resume all tasks (tasks are SUSPENDED by default)
-- Run these in order — child tasks first, root task last
-- ---------------------------------------------------------------

alter task cricket.raw.load_delivery_fact resume;
alter task cricket.raw.load_match_fact resume;
alter task cricket.raw.load_to_venue_dim resume;
alter task cricket.raw.load_to_player_dim resume;
alter task cricket.raw.load_to_team_dim resume;
alter task cricket.raw.load_to_clean_delivery resume;
alter task cricket.raw.load_to_clean_player resume;
alter task cricket.raw.load_to_clean_match resume;
alter task cricket.raw.load_json_to_raw resume;

-- Verify all tasks are active
show tasks in schema cricket.raw;
