-- =====================================================
-- analysis_queries.sql — ส่วน BTS (สมาชิกคนที่ 2)
-- รันทีละคำสั่ง: ลากคลุมคำสั่งที่ต้องการแล้วกด Run
-- ช่วงข้อมูล: 1 ต.ค. – 9 พ.ย. 2569
-- =====================================================


-- #####################################################
-- หมวด 1: SQL Select Join Tables
-- #####################################################

-- Q1.1 [INNER JOIN 5 ตาราง]
-- คำถาม: 10 เที่ยวล่าสุดที่เดินทางสำเร็จ ใครเดินทาง ใช้บัตรประเภทใด จากสถานีไหนไปไหน และจ่ายเท่าไร
SELECT
    u.full_name                                   AS passenger,
    ct.type_name                                  AS card_type,
    se.station_name                               AS from_station,
    sx.station_name                               AS to_station,
    g.entry_time AT TIME ZONE 'Asia/Bangkok'      AS entry_time_th,
    g.fare_charged
FROM gate_logs g
INNER JOIN cards c       ON c.card_id = g.card_id
INNER JOIN users u       ON u.user_id = c.user_id
INNER JOIN card_types ct ON ct.card_type_id = c.card_type_id
INNER JOIN stations se   ON se.station_id = g.entry_station_id
INNER JOIN stations sx   ON sx.station_id = g.exit_station_id
WHERE g.status = 'COMPLETED'
ORDER BY g.entry_time DESC
LIMIT 10;

-- Q1.2 [LEFT JOIN + Subquery]
-- คำถาม: ผู้ใช้คนไหนเติมเงินมากกว่าค่าเฉลี่ยของทุกคน และเดินทางไปกี่เที่ยว
--        (LEFT JOIN ทำให้เห็นคนที่เติมเงินแต่ไม่เคยเดินทางด้วย)
WITH t AS (
    SELECT c.user_id, SUM(ctu.amount) AS total_topup
    FROM card_topups ctu
    JOIN cards c ON c.card_id = ctu.card_id
    GROUP BY c.user_id
)
SELECT
    u.full_name,
    t.total_topup,
    COUNT(g.log_id) AS trips
FROM t
JOIN users u          ON u.user_id = t.user_id
LEFT JOIN cards c     ON c.user_id = u.user_id
LEFT JOIN gate_logs g ON g.card_id = c.card_id
WHERE t.total_topup > (SELECT AVG(total_topup) FROM t)
GROUP BY u.full_name, t.total_topup
ORDER BY t.total_topup DESC, trips DESC;


-- #####################################################
-- หมวด 2: SQL Aggregate Functions
-- #####################################################

-- Q2.1 [COUNT(*), COUNT(DISTINCT), SUM, AVG, MIN, MAX]
-- คำถาม: ภาพรวมการเดินทางที่สำเร็จในเดือนตุลาคม 2569
SELECT
    COUNT(*)                     AS total_trips,
    COUNT(DISTINCT card_id)      AS unique_cards,
    SUM(fare_charged)            AS total_revenue,
    ROUND(AVG(fare_charged), 2)  AS avg_fare,
    MIN(fare_charged)            AS min_fare,
    MAX(fare_charged)            AS max_fare
FROM gate_logs
WHERE status = 'COMPLETED'
  AND entry_time >= TIMESTAMPTZ '2026-10-01 00:00+07'
  AND entry_time <  TIMESTAMPTZ '2026-11-01 00:00+07';

-- Q2.2 [Aggregate + CASE WHEN + JOIN]
-- คำถาม: แต่ละประเภทบัตรมีเที่ยวสำเร็จ / ลืมแตะออก / ยกเลิก กี่เที่ยว (สรุปในแถวเดียว)
SELECT
    ct.type_name                                                  AS card_type,
    COUNT(*)                                                      AS total_trips,
    SUM(CASE WHEN g.status = 'COMPLETED'  THEN 1 ELSE 0 END)      AS completed,
    SUM(CASE WHEN g.status = 'IN_JOURNEY' THEN 1 ELSE 0 END)      AS in_journey,
    SUM(CASE WHEN g.status = 'CANCELLED'  THEN 1 ELSE 0 END)      AS cancelled,
    ROUND(100.0 * SUM(CASE WHEN g.status <> 'COMPLETED' THEN 1 ELSE 0 END) / COUNT(*), 2) AS problem_pct
FROM gate_logs g
JOIN cards c       ON c.card_id = g.card_id
JOIN card_types ct ON ct.card_type_id = c.card_type_id
GROUP BY ct.type_name
ORDER BY total_trips DESC;


-- #####################################################
-- หมวด 3: SQL Grouping Functions
-- #####################################################

-- Q3.1 [GROUP BY หลายคอลัมน์ + HAVING]
-- คำถาม: สถานีและช่วงเวลาใดมีผู้แตะบัตรเข้าตั้งแต่ 8 เที่ยวขึ้นไป
SELECT
    s.station_name,
    CASE
        WHEN EXTRACT(HOUR FROM g.entry_time AT TIME ZONE 'Asia/Bangkok') BETWEEN 7  AND 8  THEN 'เร่งด่วนเช้า'
        WHEN EXTRACT(HOUR FROM g.entry_time AT TIME ZONE 'Asia/Bangkok') BETWEEN 17 AND 18 THEN 'เร่งด่วนเย็น'
        ELSE 'นอกเวลาเร่งด่วน'
    END                AS time_period,
    COUNT(*)           AS entries
FROM gate_logs g
JOIN stations s ON s.station_id = g.entry_station_id
GROUP BY s.station_name, time_period
HAVING COUNT(*) >= 8
ORDER BY entries DESC;

-- Q3.2 [GROUP BY ROLLUP]
-- คำถาม: ยอดเติมเงินแยกตามประเภทบัตรและช่องทางชำระ พร้อมยอดรวมย่อยและยอดรวมทั้งหมด
SELECT
    COALESCE(ct.type_name, '== รวมทุกประเภท ==')  AS card_type,
    COALESCE(p.method,     '-- รวม --')           AS method,
    COUNT(*)                                     AS topups,
    SUM(ctu.amount)                              AS total_amount
FROM card_topups ctu
JOIN payments p    ON p.payment_id = ctu.payment_id
JOIN cards c       ON c.card_id = ctu.card_id
JOIN card_types ct ON ct.card_type_id = c.card_type_id
GROUP BY ROLLUP (ct.type_name, p.method)
ORDER BY ct.type_name NULLS LAST, p.method NULLS LAST;

-- Q3.3 [Window Function: RANK, SUM() OVER]
-- คำถาม: 10 สถานีที่มีผู้แตะบัตรเข้ามากที่สุด คิดเป็นกี่ % ของทั้งหมด และสะสมได้กี่ %
SELECT *
FROM (
    SELECT
        station_name,
        entries,
        RANK() OVER (ORDER BY entries DESC)                                  AS rank_no,
        ROUND(100.0 * entries / SUM(entries) OVER (), 2)                     AS share_pct,
        ROUND(100.0 * SUM(entries) OVER (ORDER BY entries DESC, station_name)
                    / SUM(entries) OVER (), 2)                               AS cumulative_pct
    FROM v_station_ridership
) r
WHERE rank_no <= 10
ORDER BY rank_no;


-- #####################################################
-- หมวด 4: Statistical and Mathematical Functions
-- #####################################################

-- Q4.1 [STDDEV, VARIANCE, PERCENTILE_CONT, MODE]
-- คำถาม: ค่าโดยสารของแต่ละประเภทบัตรกระจายตัวอย่างไร (ค่าเฉลี่ย มัธยฐาน ฐานนิยม ส่วนเบี่ยงเบน)
SELECT
    ct.type_name                                                        AS card_type,
    COUNT(*)                                                            AS trips,
    ROUND(AVG(g.fare_charged), 2)                                       AS mean_fare,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY g.fare_charged)         AS median_fare,
    MODE() WITHIN GROUP (ORDER BY g.fare_charged)                       AS mode_fare,
    ROUND(STDDEV_SAMP(g.fare_charged), 2)                               AS stddev_fare,
    ROUND(VAR_SAMP(g.fare_charged), 2)                                  AS variance_fare
FROM gate_logs g
JOIN cards c       ON c.card_id = g.card_id
JOIN card_types ct ON ct.card_type_id = c.card_type_id
WHERE g.status = 'COMPLETED'
GROUP BY ct.type_name
ORDER BY mean_fare DESC;

-- Q4.2 [CORR, REGR_SLOPE]
-- คำถาม: ระยะเวลาเดินทางสัมพันธ์กับค่าโดยสารมากแค่ไหน และนั่งนานขึ้น 1 นาทีค่าโดยสารเพิ่มกี่บาท
SELECT
    COUNT(*)                                                       AS trips,
    ROUND(CORR(duration_min, fare_charged)::numeric, 4)            AS correlation,
    ROUND(REGR_SLOPE(fare_charged, duration_min)::numeric, 2)      AS baht_per_minute,
    ROUND(AVG(duration_min), 1)                                    AS avg_duration_min
FROM v_trip_details
WHERE status = 'COMPLETED' AND card_type = 'Adult';

-- Q4.3 [LAG + การคำนวณ % เปลี่ยนแปลง]
-- คำถาม: รายได้รายสัปดาห์เพิ่มหรือลดกี่ % เมื่อเทียบกับสัปดาห์ก่อน
SELECT
    week_start,
    revenue,
    LAG(revenue) OVER (ORDER BY week_start)                                   AS prev_week,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY week_start))
                / NULLIF(LAG(revenue) OVER (ORDER BY week_start), 0), 2)      AS change_pct
FROM (
    SELECT date_trunc('week', trip_date)::date AS week_start,
           SUM(revenue)                        AS revenue
    FROM v_daily_rail_revenue
    WHERE trip_date BETWEEN DATE '2026-10-05' AND DATE '2026-11-08'   -- เฉพาะสัปดาห์เต็ม (จันทร์–อาทิตย์)
    GROUP BY 1
) w
ORDER BY week_start;
