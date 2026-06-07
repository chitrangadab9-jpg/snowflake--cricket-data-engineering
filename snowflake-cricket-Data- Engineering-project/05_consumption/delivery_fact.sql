-- ============================================================
-- FILE: delivery_fact.sql
-- PURPOSE: Create delivery (ball-by-ball) fact table and populate it
-- Layer: CONSUMPTION
-- Grain: One row = one ball bowled in a match
-- ============================================================

-- WHY a separate delivery fact table:
-- match_fact is at match level (one row per match).
-- delivery_fact is at ball level (hundreds of rows per match).
-- Keeping them separate is the Fact Constellation (Galaxy Schema) pattern.
-- It avoids repeating match-level info (venue, date) for every single ball.

CREATE or replace TABLE delivery_fact (
    match_id         INT,
    team_id          INT,
    bowler_id        INT,
    batter_id        INT,
    non_striker_id   INT,
    over             INT,
    runs             INT,
    extra_runs       INT,
    extra_type       VARCHAR(255),
    player_out       VARCHAR(255),
    player_out_kind  VARCHAR(255),
    CONSTRAINT fk_bowler      FOREIGN KEY (bowler_id)       REFERENCES player_dim (player_id),
    CONSTRAINT fk_batter      FOREIGN KEY (batter_id)       REFERENCES player_dim (player_id),
    CONSTRAINT fk_striker     FOREIGN KEY (non_striker_id)  REFERENCES player_dim (player_id),
    CONSTRAINT fk_del_match   FOREIGN KEY (match_id)        REFERENCES match_fact (match_id),
    CONSTRAINT fk_del_team    FOREIGN KEY (team_id)         REFERENCES team_dim (team_id)
);

-- Populate delivery_fact
-- LEFT JOIN anti-pattern: only insert deliveries for matches not already loaded

insert into delivery_fact
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
    join team_dim td on d.team_name = td.team_name
    join player_dim bpd on d.bowler = bpd.player_name
    join player_dim spd on d.batter = spd.player_name
    join player_dim nspd on d.non_striker = nspd.player_name
) a
left join cricket.consumption.delivery_fact b on a.match_id = b.match_id
where b.match_id is null;

-- Verify
select * from delivery_fact;

-- Sample cross-fact query: which venue had the most sixes?
-- (joins delivery_fact to match_fact to get venue info)
select
    vd.venue_name,
    count(*) as total_sixes
from cricket.consumption.delivery_fact df
join cricket.consumption.match_fact mf on df.match_id = mf.match_id
join cricket.consumption.venue_dim vd on mf.venue_id = vd.venue_id
where df.runs = 6
group by vd.venue_name
order by total_sixes desc;
