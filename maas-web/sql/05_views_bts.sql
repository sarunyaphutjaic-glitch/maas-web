-- =====================================================
-- Views ส่วน BTS (สมาชิกคนที่ 2)
-- security_invoker = true → View เคารพ RLS ของตารางต้นทาง
--   (ถ้าไม่ใส่ ผู้ใช้จะอ่านข้อมูลทุกแถวผ่าน View ได้แม้ตารางจะเปิด RLS)
-- เวลาทั้งหมดแปลงเป็นเวลาไทย (Asia/Bangkok)
-- =====================================================

-- 1. รายละเอียดการเดินทางแต่ละเที่ยว (View หลักสำหรับระบบ Chat)
--    JOIN 6 ตาราง: gate_logs, cards, users, card_types, stations ×2
CREATE OR REPLACE VIEW v_trip_details
WITH (security_invoker = true) AS
SELECT
    g.log_id,
    u.user_id,
    u.full_name                                          AS passenger_name,
    c.card_number,
    ct.type_name                                         AS card_type,
    se.station_name                                      AS entry_station,
    sx.station_name                                      AS exit_station,
    (g.entry_time AT TIME ZONE 'Asia/Bangkok')::date     AS trip_date,
    EXTRACT(HOUR FROM g.entry_time AT TIME ZONE 'Asia/Bangkok')::int AS entry_hour,
    g.entry_time,
    g.exit_time,
    ROUND(EXTRACT(EPOCH FROM (g.exit_time - g.entry_time)) / 60)::int AS duration_min,
    g.fare_charged,
    g.status
FROM gate_logs g
JOIN cards c       ON c.card_id = g.card_id
JOIN users u       ON u.user_id = c.user_id
JOIN card_types ct ON ct.card_type_id = c.card_type_id
JOIN stations se   ON se.station_id = g.entry_station_id
LEFT JOIN stations sx ON sx.station_id = g.exit_station_id;   -- LEFT: เที่ยวที่ยังไม่แตะออกไม่มีสถานีขาออก

-- 2. จำนวนผู้โดยสารเข้า-ออกและรายได้ของแต่ละสถานี (Dashboard)
CREATE OR REPLACE VIEW v_station_ridership
WITH (security_invoker = true) AS
SELECT
    s.station_id,
    s.station_code,
    s.station_name,
    (SELECT string_agg(l.line_name, ', ' ORDER BY l.line_id)
       FROM station_sequences ss JOIN lines l ON l.line_id = ss.line_id
      WHERE ss.station_id = s.station_id)                          AS lines,
    COUNT(*) FILTER (WHERE g.entry_station_id = s.station_id)      AS entries,
    COUNT(*) FILTER (WHERE g.exit_station_id  = s.station_id)      AS exits,
    COALESCE(SUM(g.fare_charged) FILTER (WHERE g.entry_station_id = s.station_id), 0) AS revenue_from_entries
FROM stations s
LEFT JOIN gate_logs g
       ON g.entry_station_id = s.station_id OR g.exit_station_id = s.station_id
GROUP BY s.station_id, s.station_code, s.station_name;

-- 3. รายได้และจำนวนเที่ยวรายวัน (Dashboard กราฟเส้น)
CREATE OR REPLACE VIEW v_daily_rail_revenue
WITH (security_invoker = true) AS
SELECT
    (entry_time AT TIME ZONE 'Asia/Bangkok')::date              AS trip_date,
    COUNT(*)                                                     AS total_trips,
    COUNT(*) FILTER (WHERE status = 'COMPLETED')                 AS completed_trips,
    COUNT(DISTINCT card_id)                                      AS unique_cards,
    SUM(fare_charged)                                            AS revenue,
    ROUND(AVG(fare_charged) FILTER (WHERE status = 'COMPLETED'), 2) AS avg_fare
FROM gate_logs
GROUP BY 1;

-- 4. สถิติแยกตามประเภทบัตร
CREATE OR REPLACE VIEW v_card_type_stats
WITH (security_invoker = true) AS
SELECT
    ct.type_name                                   AS card_type,
    ct.discount_rate,
    COUNT(DISTINCT c.card_id)                      AS total_cards,
    -- เฉลี่ยจากบัตรแต่ละใบ (ไม่ใช่จากทุกแถวการเดินทาง ซึ่งจะนับยอดเงินซ้ำ)
    (SELECT ROUND(AVG(c2.balance), 2) FROM cards c2
      WHERE c2.card_type_id = ct.card_type_id)     AS avg_balance,
    COUNT(g.log_id)                                AS total_trips,
    COALESCE(SUM(g.fare_charged), 0)               AS total_fare,
    ROUND(AVG(g.fare_charged) FILTER (WHERE g.status = 'COMPLETED'), 2) AS avg_fare
FROM card_types ct
LEFT JOIN cards c     ON c.card_type_id = ct.card_type_id
LEFT JOIN gate_logs g ON g.card_id = c.card_id
GROUP BY ct.card_type_id, ct.type_name, ct.discount_rate;

-- 5. เที่ยวที่มีปัญหา (ลืมแตะออก / ยกเลิก) สำหรับเจ้าหน้าที่สถานี
CREATE OR REPLACE VIEW v_problem_trips
WITH (security_invoker = true) AS
SELECT log_id, passenger_name, card_number, card_type,
       entry_station, entry_time, status
FROM v_trip_details
WHERE status IN ('IN_JOURNEY', 'CANCELLED');
