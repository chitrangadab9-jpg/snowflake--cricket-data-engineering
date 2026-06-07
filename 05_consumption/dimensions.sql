-- ============================================================
-- FILE: dimensions.sql
-- PURPOSE: Create all dimension tables and populate them
-- Layer: CONSUMPTION
-- Tables: date_dim, team_dim, player_dim, venue_dim, match_type_dim, referee_dim
-- ============================================================

-- WHY dimension tables:
-- Dimensions hold the "who, what, where, when" context of a match.
-- They use surrogate keys (autoincrement integers) instead of raw names
-- so joins are fast and historical data stays intact even if names change.

use schema cricket.consumption;

-- ---------------------------------------------------------------
-- DATE DIMENSION
-- Pre-splits date into day/month/year/quarter so analysts can
-- filter by year or month without recalculating every query
-- ---------------------------------------------------------------

create or replace table date_dim (
    date_id      int primary key autoincrement,
    full_dt      date,
    day          int,
    month        int,
    year         int,
    quarter      int,
    dayofweek    int,
    dayofmonth   int,
    dayofyear    int,
    dayofweekname varchar(3),
    isweekend    boolean
);

-- Generate a date range covering all match dates
-- Find the range first:
select min(event_date), max(event_date) from cricket.clean.match_detail_clean;

-- Generate all dates in the range using Snowflake's SEQ4() + GENERATOR
CREATE or replace transient TABLE cricket.consumption.date_rnage01 (date DATE);

INSERT INTO cricket.consumption.date_rnage01 (date)
SELECT DATEADD(day, SEQ4(), '2023-10-12'::date) as date
FROM TABLE(GENERATOR(ROWCOUNT => 10000))
WHERE DATEADD(day, SEQ4(), '2023-10-12'::date) <= '2023-11-10'::date;

-- Populate date_dim from the generated dates
INSERT INTO date_dim (full_dt, day, month, year, quarter, dayofweek, dayofmonth, dayofyear, dayofweekname, isweekend)
SELECT
    date as full_dt,
    DAY(date) as day,
    MONTH(date) as month,
    YEAR(date) as year,
    QUARTER(date) as quarter,
    DAYOFWEEK(date) as dayofweek,
    DAYOFMONTH(date) as dayofmonth,
    DAYOFYEAR(date) as dayofyear,
    LEFT(DAYNAME(date), 3) as dayofweekname,
    CASE WHEN DAYOFWEEK(date) IN (1, 7) THEN TRUE ELSE FALSE END as isweekend
FROM cricket.consumption.date_rnage01;

select * from date_dim;

-- ---------------------------------------------------------------
-- TEAM DIMENSION
-- All unique teams across both first_team and second_team columns
-- UNION ALL then DISTINCT to get every team once
-- ---------------------------------------------------------------

create or replace table team_dim (
    team_id   int primary key autoincrement,
    team_name text not null
);

insert into cricket.consumption.team_dim (team_name)
select distinct team_name from (
    select first_team as team_name from cricket.clean.match_detail_clean
    union all
    select second_team as team_name from cricket.clean.match_detail_clean
) order by team_name;

select * from cricket.consumption.team_dim order by team_name;

-- ---------------------------------------------------------------
-- PLAYER DIMENSION
-- One row per unique player. FK to team_dim.
-- ---------------------------------------------------------------

create or replace table player_dim (
    player_id   int primary key autoincrement,
    team_id     int not null,
    player_name text not null
);

-- FK links player to their team
alter table cricket.consumption.player_dim
    add constraint fk_team_player_id foreign key (team_id)
    references cricket.consumption.team_dim (team_id);

insert into cricket.consumption.player_dim (team_id, player_name)
select b.team_id, a.player_name
from cricket.clean.player_clean_tbl a
join cricket.consumption.team_dim b on a.country = b.team_name
group by b.team_id, a.player_name;

select * from player_dim;

-- ---------------------------------------------------------------
-- VENUE DIMENSION
-- One row per unique venue + city combination
-- ---------------------------------------------------------------

create or replace table venue_dim (
    venue_id       int primary key autoincrement,
    venue_name     text not null,
    city           text not null,
    state          text,
    country        text,
    continent      text,
    end_names      text,
    capacity       number,
    pitch          text,
    flood_light    boolean,
    established_dt date,
    playing_area   text,
    other_sports   text,
    curator        text,
    lattitude      number(10,6),
    longitude      number(10,6)
);

insert into cricket.consumption.venue_dim (venue_name, city)
select venue, city from (
    select
        venue,
        case when city is null then 'NA' else city end as city
    from cricket.clean.match_detail_clean
)
group by venue, city;

select * from cricket.consumption.venue_dim;

-- ---------------------------------------------------------------
-- MATCH TYPE DIMENSION
-- T20, ODI, Test etc.
-- ---------------------------------------------------------------

create or replace table match_type_dim (
    match_type_id int primary key autoincrement,
    match_type    text not null
);

insert into cricket.consumption.match_type_dim (match_type)
select match_type from cricket.clean.match_detail_clean group by match_type;

select * from cricket.consumption.match_type_dim;

-- ---------------------------------------------------------------
-- REFEREE DIMENSION
-- All officials: match referee, reserve umpire, TV umpire,
-- first umpire, second umpire — extracted from the JSON officials block
-- UNION (not UNION ALL) removes duplicates automatically
-- ---------------------------------------------------------------

create or replace table referee_dim (
    referee_id   int primary key autoincrement,
    referee_name text not null
);

INSERT INTO cricket.consumption.referee_dim (referee_name)
SELECT referee_name FROM (
    SELECT info:officials.match_referees[0]::text as referee_name
    FROM cricket.raw.match_raw_tbl
    WHERE info:officials.match_referees[0]::text IS NOT NULL
    UNION
    SELECT info:officials.reserve_umpires[0]::text
    FROM cricket.raw.match_raw_tbl
    WHERE info:officials.reserve_umpires[0]::text IS NOT NULL
    UNION
    SELECT info:officials.tv_umpires[0]::text
    FROM cricket.raw.match_raw_tbl
    WHERE info:officials.tv_umpires[0]::text IS NOT NULL
    UNION
    SELECT info:officials.umpires[0]::text
    FROM cricket.raw.match_raw_tbl
    WHERE info:officials.umpires[0]::text IS NOT NULL
    UNION
    SELECT info:officials.umpires[1]::text
    FROM cricket.raw.match_raw_tbl
    WHERE info:officials.umpires[1]::text IS NOT NULL
);

select * from cricket.consumption.referee_dim;

-- ---------------------------------------------------------------
-- Verify all dimensions
-- ---------------------------------------------------------------
select * from date_dim;
select * from match_fact;
select * from match_type_dim;
select * from player_dim;
select * from referee_dim;
select * from team_dim;
select * from venue_dim;
