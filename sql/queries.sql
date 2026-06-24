-- ============================================================
--  Racing Telemetry — SQL Query Reference
--  Dialect: DuckDB (reads .parquet directly)
--  Usage:   duckdb -c ".read queries.sql"
--           or copy individual queries into 03_sql_analysis.ipynb
-- ============================================================

-- Setup: register the parquet file as a view
CREATE OR REPLACE VIEW telemetry AS
    SELECT * FROM read_parquet('features_engineered.parquet');


-- ============================================================
-- SECTION 1 — LAP PERFORMANCE SUMMARY
-- ============================================================

-- 1.1  Basic lap stats
SELECT
    lap_number,
    ROUND(MAX(current_lap_time), 3)                                     AS lap_time_s,
    ROUND(AVG(speed_kmh), 1)                                            AS avg_speed_kmh,
    ROUND(MAX(speed_kmh), 1)                                            AS max_speed_kmh,
    ROUND(MIN(speed_kmh), 1)                                            AS min_speed_kmh,
    ROUND(AVG(throttle_norm) * 100, 1)                                  AS avg_throttle_pct,
    ROUND(SUM(CASE WHEN throttle_norm > 0.95 THEN 1.0 ELSE 0 END)
          / COUNT(*) * 100, 1)                                          AS pct_full_throttle,
    ROUND(SUM(CASE WHEN brake_norm > 0.10 THEN 1.0 ELSE 0 END)
          / COUNT(*) * 100, 1)                                          AS pct_braking,
    ROUND((MAX(fuel) - MIN(fuel)) * 100, 4)                             AS fuel_consumed_pct
FROM telemetry
GROUP BY lap_number
ORDER BY lap_number;


-- 1.2  Lap ranking with gap to best (window functions)
WITH lap_agg AS (
    SELECT
        lap_number,
        MAX(current_lap_time)       AS lap_time_s,
        AVG(speed_kmh)              AS avg_speed_kmh,
        (MAX(fuel) - MIN(fuel))*100 AS fuel_used_pct
    FROM telemetry
    GROUP BY lap_number
)
SELECT
    lap_number,
    ROUND(lap_time_s, 3)                                            AS lap_time_s,
    RANK() OVER (ORDER BY lap_time_s ASC)                           AS rank,
    ROUND(lap_time_s - MIN(lap_time_s) OVER (), 3)                  AS gap_to_best_s,
    ROUND(avg_speed_kmh, 1)                                         AS avg_speed_kmh,
    ROUND(fuel_used_pct, 4)                                         AS fuel_used_pct,
    ROUND(AVG(lap_time_s) OVER () - lap_time_s, 3)                  AS vs_avg_s
FROM lap_agg
ORDER BY lap_number;


-- 1.3  Cumulative fuel and running best lap time
WITH lap_totals AS (
    SELECT
        lap_number,
        MAX(current_lap_time)        AS lap_time_s,
        (MAX(fuel) - MIN(fuel))*100  AS fuel_used_pct
    FROM telemetry
    GROUP BY lap_number
)
SELECT
    lap_number,
    ROUND(lap_time_s, 3)                                                AS lap_time_s,
    ROUND(fuel_used_pct, 4)                                             AS fuel_used_pct,
    ROUND(SUM(fuel_used_pct)  OVER (ORDER BY lap_number
          ROWS UNBOUNDED PRECEDING), 4)                                 AS cumulative_fuel_pct,
    ROUND(MIN(lap_time_s)     OVER (ORDER BY lap_number
          ROWS UNBOUNDED PRECEDING), 3)                                 AS running_best_s,
    ROUND(lap_time_s - MIN(lap_time_s) OVER (ORDER BY lap_number
          ROWS UNBOUNDED PRECEDING), 3)                                 AS gap_to_running_best_s,
    ROUND(AVG(lap_time_s)     OVER (ORDER BY lap_number
          ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING), 3)                 AS moving_avg_3laps_s
FROM lap_totals
ORDER BY lap_number;


-- ============================================================
-- SECTION 2 — TRACK SECTION DISTRIBUTION
-- ============================================================

-- 2.1  Time and speed per section
SELECT
    track_section,
    COUNT(*)                                                            AS samples,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)                 AS pct_total,
    ROUND(AVG(speed_kmh), 1)                                           AS avg_speed_kmh,
    ROUND(MAX(speed_kmh), 1)                                           AS max_speed_kmh,
    ROUND(AVG(ABS(g_lateral)), 3)                                      AS avg_abs_lat_g,
    ROUND(AVG(throttle_norm) * 100, 1)                                 AS avg_throttle_pct,
    ROUND(AVG(brake_norm)    * 100, 1)                                 AS avg_brake_pct,
    ROUND(AVG(combined_slip_avg), 5)                                   AS avg_slip
FROM telemetry
GROUP BY track_section
ORDER BY samples DESC;


-- 2.2  Section breakdown per lap
SELECT
    lap_number,
    track_section,
    COUNT(*)                                                            AS samples,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY lap_number), 1) AS pct_of_lap,
    ROUND(AVG(speed_kmh), 1)                                           AS avg_speed_kmh
FROM telemetry
GROUP BY lap_number, track_section
ORDER BY lap_number, samples DESC;


-- ============================================================
-- SECTION 3 — CORNER RANKING & DIFFICULTY
-- ============================================================

-- 3.1  Average metrics per corner (across all laps)
SELECT
    corner_id                                                           AS corner_id,
    FLOOR(corner_id / 100)                                             AS lap,
    corner_id % 100                                                    AS corner_num,
    COUNT(*)                                                           AS samples_in_window,
    ROUND(AVG(speed_kmh), 1)                                          AS avg_speed_kmh,
    ROUND(MIN(speed_kmh), 1)                                          AS apex_speed_kmh,
    ROUND(MAX(ABS(g_lateral)), 3)                                     AS peak_lat_g,
    ROUND(AVG(ABS(understeer_index)), 5)                              AS avg_abs_understeer,
    ROUND(AVG(combined_slip_avg), 5)                                  AS avg_slip
FROM telemetry
WHERE corner_id != -1
GROUP BY corner_id
ORDER BY lap, corner_num;


-- 3.2  Slowest corners across all laps (hardest braking)
SELECT
    corner_id % 100                                                    AS corner_num,
    ROUND(MIN(speed_kmh), 1)                                          AS apex_speed_kmh,
    ROUND(MAX(ABS(g_lateral)), 3)                                     AS peak_lat_g,
    ROUND(AVG(brake_norm) * 100, 1)                                   AS avg_brake_pct,
    FLOOR(corner_id / 100)                                            AS lap
FROM telemetry
WHERE corner_id != -1
GROUP BY corner_id
ORDER BY apex_speed_kmh ASC
LIMIT 10;


-- ============================================================
-- SECTION 4 — SAFETY EVENTS
-- ============================================================

-- 4.1  Wheel spin and lock events per lap
SELECT
    lap_number,
    SUM(CASE WHEN wheel_spin_index > 0.05  THEN 1 ELSE 0 END)         AS spin_events,
    ROUND(SUM(CASE WHEN wheel_spin_index > 0.05  THEN 1.0 ELSE 0 END)
          / COUNT(*) * 100, 2)                                         AS spin_pct,
    SUM(wheel_lock_flag)                                               AS lock_events,
    ROUND(SUM(wheel_lock_flag::FLOAT) / COUNT(*) * 100, 2)            AS lock_pct,
    SUM(CASE WHEN understeer_index < -0.01 THEN 1 ELSE 0 END)         AS oversteer_samples,
    ROUND(SUM(CASE WHEN understeer_index < -0.01 THEN 1.0 ELSE 0 END)
          / COUNT(*) * 100, 2)                                         AS oversteer_pct
FROM telemetry
GROUP BY lap_number
ORDER BY lap_number;


-- 4.2  Track position of spin events (for mapping)
SELECT
    lap_number,
    ROUND(lap_dist_pct, 1)                                            AS dist_pct,
    ROUND(position_x, 1)                                              AS pos_x,
    ROUND(position_z, 1)                                              AS pos_z,
    ROUND(wheel_spin_index, 4)                                        AS spin_index,
    track_section
FROM telemetry
WHERE wheel_spin_index > 0.05
ORDER BY lap_number, dist_pct;


-- 4.3  Oversteer moments by track section
SELECT
    track_section,
    COUNT(*)                                                          AS oversteer_samples,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)               AS pct_of_all_oversteer,
    ROUND(AVG(understeer_index), 5)                                   AS avg_understeer_idx,
    ROUND(AVG(speed_kmh), 1)                                         AS avg_speed_at_event
FROM telemetry
WHERE understeer_index < -0.01
GROUP BY track_section
ORDER BY oversteer_samples DESC;


-- ============================================================
-- SECTION 5 — TIRE TEMPERATURE & FUEL CONSUMPTION
-- ============================================================

-- 5.1  Tire temperature summary per lap
SELECT
    lap_number,
    ROUND(MIN(tire_temp_avg), 2)                                      AS temp_start_c,
    ROUND(MAX(tire_temp_avg), 2)                                      AS temp_peak_c,
    ROUND(AVG(tire_temp_avg), 2)                                      AS temp_avg_c,
    ROUND(MAX(tire_temp_avg) - MIN(tire_temp_avg), 3)                 AS temp_rise_c,
    ROUND(AVG(tire_temp_fr_delta), 4)                                 AS front_rear_imbalance_c,
    ROUND(AVG(tire_temp_lr_delta), 4)                                 AS left_right_imbalance_c
FROM telemetry
GROUP BY lap_number
ORDER BY lap_number;


-- 5.2  Fuel level over the race (sampled every 1%)
SELECT
    lap_number,
    ROUND(lap_dist_pct)                                               AS dist_pct,
    ROUND(AVG(fuel) * 100, 3)                                        AS fuel_level_pct
FROM telemetry
GROUP BY lap_number, ROUND(lap_dist_pct)
ORDER BY lap_number, dist_pct;


-- 5.3  Tire temp vs combined slip (correlation proxy)
SELECT
    lap_number,
    track_section,
    ROUND(AVG(tire_temp_avg), 2)                                      AS avg_tire_temp_c,
    ROUND(AVG(combined_slip_avg), 5)                                  AS avg_slip,
    ROUND(CORR(tire_temp_avg, combined_slip_avg), 4)                  AS temp_slip_corr
FROM telemetry
GROUP BY lap_number, track_section
ORDER BY lap_number, track_section;


-- ============================================================
-- SECTION 6 — WINDOW FUNCTIONS
-- ============================================================

-- 6.1  LAG/LEAD: speed 1 second ago and ahead (partition by lap)
SELECT
    lap_number,
    ROUND(lap_dist_pct, 2)                                            AS dist_pct,
    ROUND(speed_kmh, 1)                                               AS speed_now,
    ROUND(LAG(speed_kmh, 12)  OVER w, 1)                             AS speed_1s_ago,
    ROUND(LEAD(speed_kmh, 12) OVER w, 1)                             AS speed_1s_ahead,
    ROUND(speed_kmh - LAG(speed_kmh, 12) OVER w, 1)                  AS accel_1s,
    track_section,
    gear
FROM telemetry
WINDOW w AS (PARTITION BY lap_number ORDER BY lap_dist_pct)
QUALIFY lap_dist_pct BETWEEN 10 AND 90
ORDER BY lap_number, dist_pct;


-- 6.2  NTILE(5): five-sector breakdown per lap
WITH zoned AS (
    SELECT
        lap_number,
        speed_kmh,
        g_lateral,
        throttle_norm,
        brake_norm,
        understeer_index,
        combined_slip_avg,
        NTILE(5) OVER (PARTITION BY lap_number ORDER BY lap_dist_pct) AS sector
    FROM telemetry
)
SELECT
    lap_number,
    sector,
    ROUND(AVG(speed_kmh), 1)                                          AS avg_speed_kmh,
    ROUND(PERCENTILE_CONT(0.5)
          WITHIN GROUP (ORDER BY speed_kmh), 1)                       AS median_speed_kmh,
    ROUND(MAX(ABS(g_lateral)), 3)                                     AS peak_lat_g,
    ROUND(AVG(throttle_norm)*100, 1)                                  AS avg_throttle_pct,
    ROUND(AVG(brake_norm)*100, 1)                                     AS avg_brake_pct,
    ROUND(AVG(understeer_index), 4)                                   AS avg_understeer,
    ROUND(AVG(combined_slip_avg), 5)                                  AS avg_slip
FROM zoned
GROUP BY lap_number, sector
ORDER BY lap_number, sector;


-- 6.3  RANK per corner: which lap had the fastest apex speed at each corner?
WITH corner_apexes AS (
    SELECT
        corner_id % 100                                               AS corner_num,
        FLOOR(corner_id / 100)                                       AS lap_number,
        MIN(speed_kmh)                                               AS apex_speed_kmh,
        MAX(ABS(g_lateral))                                          AS peak_lat_g
    FROM telemetry
    WHERE corner_id != -1
    GROUP BY corner_id
)
SELECT
    corner_num,
    lap_number,
    ROUND(apex_speed_kmh, 1)                                         AS apex_speed_kmh,
    RANK() OVER (PARTITION BY corner_num ORDER BY apex_speed_kmh DESC) AS speed_rank,
    ROUND(peak_lat_g, 3)                                             AS peak_lat_g,
    ROUND(apex_speed_kmh - AVG(apex_speed_kmh)
          OVER (PARTITION BY corner_num), 1)                         AS vs_corner_avg
FROM corner_apexes
ORDER BY corner_num, lap_number;


-- 6.4  Best sector combination (qualifying-style)
WITH sectored AS (
    SELECT
        lap_number,
        NTILE(3) OVER (PARTITION BY lap_number ORDER BY lap_dist_pct) AS sector,
        current_lap_time
    FROM telemetry
),
sector_times AS (
    SELECT
        lap_number,
        sector,
        MAX(current_lap_time) - MIN(current_lap_time)                AS sector_time_s
    FROM sectored
    GROUP BY lap_number, sector
),
best_per_sector AS (
    SELECT
        sector,
        MIN(sector_time_s)                                           AS best_sector_s,
        ARG_MIN(lap_number, sector_time_s)                           AS best_lap
    FROM sector_times
    GROUP BY sector
)
SELECT
    st.lap_number,
    st.sector,
    ROUND(st.sector_time_s, 3)                                       AS sector_time_s,
    ROUND(bs.best_sector_s, 3)                                       AS best_sector_s,
    bs.best_lap,
    ROUND(st.sector_time_s - bs.best_sector_s, 3)                   AS gap_to_best_s,
    RANK() OVER (PARTITION BY st.sector ORDER BY st.sector_time_s)   AS sector_rank
FROM sector_times st
JOIN best_per_sector bs ON bs.sector = st.sector
ORDER BY st.sector, st.lap_number;


-- 6.5  Understeer index heatmap data (section × lap)
SELECT
    lap_number,
    track_section,
    ROUND(AVG(understeer_index), 5)                                   AS avg_understeer,
    ROUND(STDDEV(understeer_index), 5)                                AS std_understeer,
    ROUND(AVG(combined_slip_avg), 5)                                  AS avg_slip,
    COUNT(*)                                                          AS samples
FROM telemetry
GROUP BY lap_number, track_section
ORDER BY lap_number, track_section;
