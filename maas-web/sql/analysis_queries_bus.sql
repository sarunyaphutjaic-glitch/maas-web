-- =====================================================
-- analysis_queries — ส่วนรถเมล์ (สมาชิกคนที่ 3)
-- รันทีละคำสั่ง: ลากคลุมคำสั่งที่ต้องการแล้วกด Run
-- =====================================================


-- #####################################################
-- หมวด 1: SQL Select Join Tables
-- #####################################################

-- B1.1 [INNER JOIN 5 ตาราง]
-- คำถาม: รอบวิ่งล่าสุด 10 รอบ สายอะไร รถประเภทไหน ใครขับ ออกช้ากี่นาที
SELECT
    br.route_no,
    br.route_name,
    b.plate_no,
    b.bus_type,
    d.full_name                                                         AS driver,
    s.departure_time AT TIME ZONE 'Asia/Bangkok'                        AS planned_departure,
    ROUND(EXTRACT(EPOCH FROM (t.actual_departure - s.departure_time)) / 60) AS delay_min
FROM bus_schedules s
INNER JOIN bus_routes br ON br.route_id = s.route_id
INNER JOIN buses b       ON b.bus_id = s.bus_id
INNER JOIN drivers d     ON d.driver_id = s.driver_id
INNER JOIN trip_logs t   ON t.schedule_id = s.schedule_id
ORDER BY s.departure_time DESC
LIMIT 10;

-- B1.2 [JOIN ข้ามระบบผ่านตาราง locations]
-- คำถาม: ถ้าลงรถไฟฟ้าที่สถานีอโศก ต่อรถเมล์สายไหนได้บ้าง ป้ายอยู่ห่างกี่เมตร
SELECT bts_station, bus_stop, bus_routes, distance_m
FROM v_bus_stops_near_bts
WHERE bts_station = 'อโศก'
ORDER BY distance_m;


-- #####################################################
-- หมวด 2: SQL Aggregate Functions
-- #####################################################

-- B2.1 [COUNT(*), COUNT(DISTINCT), SUM, AVG, MIN, MAX + JOIN]
-- คำถาม: ภาพรวมผู้โดยสารรถเมล์แต่ละสาย
SELECT
    br.route_no,
    COUNT(*)                     AS rides,
    COUNT(DISTINCT r.user_id)    AS unique_passengers,
    SUM(r.fare_paid)             AS revenue,
    ROUND(AVG(r.fare_paid), 2)   AS avg_fare,
    MIN(r.boarded_at AT TIME ZONE 'Asia/Bangkok')::date AS first_ride,
    MAX(r.boarded_at AT TIME ZONE 'Asia/Bangkok')::date AS last_ride
FROM bus_rides r
JOIN bus_schedules s ON s.schedule_id = r.schedule_id
JOIN bus_routes br   ON br.route_id = s.route_id
GROUP BY br.route_no
ORDER BY rides DESC;

-- B2.2 [Aggregate + CASE WHEN]
-- คำถาม: แต่ละสายตรงเวลาแค่ไหน (ตรงเวลา ≤ 5 นาที / ช้าเล็กน้อย 6–10 / ช้ามาก > 10 / ยกเลิก)
SELECT
    br.route_no,
    COUNT(*)                                                                           AS scheduled,
    SUM(CASE WHEN t.trip_log_id IS NULL THEN 1 ELSE 0 END)                             AS cancelled,
    SUM(CASE WHEN t.actual_departure - s.departure_time <= INTERVAL '5 minutes'  THEN 1 ELSE 0 END) AS on_time,
    SUM(CASE WHEN t.actual_departure - s.departure_time >  INTERVAL '5 minutes'
              AND t.actual_departure - s.departure_time <= INTERVAL '10 minutes' THEN 1 ELSE 0 END) AS slightly_late,
    SUM(CASE WHEN t.actual_departure - s.departure_time >  INTERVAL '10 minutes' THEN 1 ELSE 0 END) AS very_late
FROM bus_schedules s
JOIN bus_routes br     ON br.route_id = s.route_id
LEFT JOIN trip_logs t  ON t.schedule_id = s.schedule_id
GROUP BY br.route_no
ORDER BY br.route_no;


-- #####################################################
-- หมวด 3: SQL Grouping Functions
-- #####################################################

-- B3.1 [GROUP BY หลายคอลัมน์ + HAVING]
-- คำถาม: สายและประเภทรถใดที่มีผู้โดยสารตั้งแต่ 10 คนขึ้นไป
SELECT route_no, bus_type, COUNT(*) AS rides, SUM(fare_paid) AS revenue
FROM v_bus_ride_details
GROUP BY route_no, bus_type
HAVING COUNT(*) >= 10
ORDER BY rides DESC;

-- B3.2 [Window Function: RANK + AVG() OVER]
-- คำถาม: จัดอันดับคนขับตามความตรงเวลา และเทียบกับค่าเฉลี่ยของทุกคน
SELECT
    driver_name,
    completed_trips,
    avg_delay_min,
    RANK() OVER (ORDER BY avg_delay_min ASC)                         AS punctuality_rank,
    ROUND(avg_delay_min - AVG(avg_delay_min) OVER (), 1)             AS diff_from_average
FROM v_driver_workload
ORDER BY punctuality_rank;


-- #####################################################
-- หมวด 4: Statistical and Mathematical Functions
-- #####################################################

-- B4.1 [STDDEV, VARIANCE, MODE]
-- คำถาม: ความล่าช้าของแต่ละสายสม่ำเสมอแค่ไหน และนาทีที่ช้าบ่อยที่สุดคือเท่าไร
SELECT
    br.route_no,
    COUNT(t.trip_log_id)                                                                   AS trips,
    ROUND(AVG(EXTRACT(EPOCH FROM (t.actual_departure - s.departure_time)) / 60), 2)        AS mean_delay,
    ROUND(STDDEV_SAMP(EXTRACT(EPOCH FROM (t.actual_departure - s.departure_time)) / 60), 2) AS stddev_delay,
    ROUND(VAR_SAMP(EXTRACT(EPOCH FROM (t.actual_departure - s.departure_time)) / 60), 2)    AS variance_delay,
    MODE() WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (t.actual_departure - s.departure_time)) / 60) AS mode_delay
FROM bus_schedules s
JOIN bus_routes br ON br.route_id = s.route_id
JOIN trip_logs t   ON t.schedule_id = s.schedule_id
GROUP BY br.route_no
ORDER BY stddev_delay DESC;

-- B4.2 [PERCENTILE_CONT + ระยะทาง Haversine]
-- คำถาม: ผู้โดยสารนั่งรถเมล์ไกลแค่ไหน (ระยะทางตรงจากป้ายขึ้นถึงป้ายลง กิโลเมตร)
WITH d AS (
    SELECT 6371 * 2 * asin(sqrt(
               power(sin(radians(la.latitude - lb.latitude) / 2), 2) +
               cos(radians(lb.latitude)) * cos(radians(la.latitude)) *
               power(sin(radians(la.longitude - lb.longitude) / 2), 2))) AS km
    FROM bus_rides r
    JOIN bus_stops sb ON sb.stop_id = r.board_stop_id
    JOIN bus_stops sa ON sa.stop_id = r.alight_stop_id
    JOIN locations lb ON lb.location_id = sb.location_id
    JOIN locations la ON la.location_id = sa.location_id
)
SELECT
    COUNT(*)                                                             AS rides,
    ROUND(AVG(km)::numeric, 2)                                           AS mean_km,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY km)::numeric, 2)   AS median_km,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY km)::numeric, 2)   AS p90_km,
    ROUND(STDDEV_SAMP(km)::numeric, 2)                                   AS stddev_km
FROM d;
