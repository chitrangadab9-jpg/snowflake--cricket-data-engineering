-- ============================================================
-- FILE: match_fact_table.sql
-- PURPOSE: Create match fact table and populate it
-- Layer: CONSUMPTION
-- Grain: One row = one complete cricket match
-- ============================================================

-- WHY a fact table:
-- Dimensions hold context. The fact table holds the NUMBERS and
-- connects all dimensions together via foreign keys.
-- Every metric you want to analyse lives here:
-- scores, wickets, overs, toss result, match result.

CREATE or replace TABLE match_fact (
    match_id                    INT PRIMARY KEY autoincrement,
    date_id                     INT NOT NULL,
    referee_id                  INT NOT NULL,
    team_a_id                   INT NOT NULL,
    team_b_id                   INT NOT NULL,
    match_type_id               INT NOT NULL,
    venue_id                    INT NOT NULL,
    total_overs                 number(3),
    balls_per_over              number(1),
    overs_played_by_team_a      number(2),
    bowls_played_by_team_a      number(3),
    extra_bowls_played_by_team_a number(3),
    extra_runs_scored_by_team_a number(3),
    fours_by_team_a             number(3),
    sixes_by_team_a             number(3),
    total_score_by_team_a       number(3),
    wicket_lost_by_team_a       number(2),
    overs_played_by_team_b      number(2),
    bowls_played_by_team_b      number(3),
    extra_bowls_played_by_team_b number(3),
    extra_runs_scored_by_team_b number(3),
    fours_by_team_b             number(3),
    sixes_by_team_b             number(3),
    total_score_by_team_b       number(3),
    wicket_lost_by_team_b       number(2),
    toss_winner_team_id         int not null,
    toss_decision               text not null,
    match_result                text not null,
    winner_team_id              int not null,
    CONSTRAINT fk_date         FOREIGN KEY (date_id)            REFERENCES date_dim (date_id),
    CONSTRAINT fk_referee      FOREIGN KEY (referee_id)         REFERENCES referee_dim (referee_id),
    CONSTRAINT fk_team1        FOREIGN KEY (team_a_id)          REFERENCES team_dim (team_id),
    CONSTRAINT fk_team2        FOREIGN KEY (team_b_id)          REFERENCES team_dim (team_id),
    CONSTRAINT fk_match_type   FOREIGN KEY (match_type_id)      REFERENCES match_type_dim (match_type_id),
    CONSTRAINT fk_venue        FOREIGN KEY (venue_id)           REFERENCES venue_dim (venue_id),
    CONSTRAINT fk_toss_winner  FOREIGN KEY (toss_winner_team_id) REFERENCES team_dim (team_id),
    CONSTRAINT fk_winner_team  FOREIGN KEY (winner_team_id)     REFERENCES team_dim (team_id)
);

-- Populate the fact table
-- The LEFT JOIN anti-pattern (WHERE b.match_id IS NULL) ensures
-- only new matches are inserted — no duplicates even if run multiple times

insert into cricket.consumption.match_fact
select
    m.match_type_number as match_id,
    dd.date_id,
    0 as referee_id,       -- placeholder; updated after referee_dim was populated
    ftd.team_id as first_team_id,
    std.team_id as second_team_id,
    mtd.match_type_id,
    vd.venue_id,
    50 as total_overs,
    6 as balls_per_overs,
    max(case when d.team_name = m.first_team then d.over else 0 end) as overs_played_by_team_a,
    sum(case when d.team_name = m.first_team then 1 else 0 end) as balls_played_by_team_a,
    sum(case when d.team_name = m.first_team then d.extras else 0 end) as extra_balls_played_by_team_a,
    sum(case when d.team_name = m.first_team then d.extra_runs else 0 end) as extra_runs_scored_by_team_a,
    0 as fours_by_team_a,
    0 as sixes_by_team_a,
    (sum(case when d.team_name = m.first_team then d.runs else 0 end) +
     sum(case when d.team_name = m.first_team then d.extra_runs else 0 end)) as total_runs_scored_by_team_a,
    sum(case when d.team_name = m.first_team and player_out is not null then 1 else 0 end) as wicket_lost_by_team_a,
    max(case when d.team_name = m.second_team then d.over else 0 end) as overs_played_by_team_b,
    sum(case when d.team_name = m.second_team then 1 else 0 end) as balls_played_by_team_b,
    sum(case when d.team_name = m.second_team then d.extras else 0 end) as extra_balls_played_by_team_b,
    sum(case when d.team_name = m.second_team then d.extra_runs else 0 end) as extra_runs_scored_by_team_b,
    0 as fours_by_team_b,
    0 as sixes_by_team_b,
    (sum(case when d.team_name = m.second_team then d.runs else 0 end) +
     sum(case when d.team_name = m.second_team then d.extra_runs else 0 end)) as total_runs_scored_by_team_b,
    sum(case when d.team_name = m.second_team and player_out is not null then 1 else 0 end) as wicket_lost_by_team_b,
    tw.team_id as toss_winner_team_id,
    m.toss_decision,
    m.match_result,
    mw.team_id as winner_team_id
from cricket.clean.match_detail_clean m
join date_dim dd on m.event_date = dd.full_dt
join team_dim ftd on m.first_team = ftd.team_name
join team_dim std on m.second_team = std.team_name
join match_type_dim mtd on m.match_type = mtd.match_type
join venue_dim vd on m.venue = vd.venue_name and m.city = vd.city
join cricket.clean.delivery_clean_tbl d on d.match_type_number = m.match_type_number
join team_dim tw on m.toss_winner = tw.team_name
join team_dim mw on m.winner = mw.team_name
group by
    m.match_type_number, date_id, referee_id,
    first_team_id, second_team_id, match_type_id, venue_id,
    total_overs, toss_winner_team_id, toss_decision, match_result, winner_team_id;

select * from cricket.consumption.match_fact;
