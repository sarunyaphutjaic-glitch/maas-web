-- =====================================================
-- Seed data: ตารางกลาง + BTS
-- รันหลัง 00_central_schema.sql และ 02_bts_schema.sql
-- รันได้ครั้งเดียว ถ้าจะรันใหม่ให้รันบล็อก RESET ด้านล่างก่อน
-- =====================================================

-- ---------- RESET (ลบข้อมูลทั้งหมดแล้วเริ่มนับ id ใหม่) ----------
-- TRUNCATE gate_logs, card_topups, fare_tables, cards, card_types,
--          station_sequences, stations, lines, payments, chat_logs,
--          locations, users RESTART IDENTITY CASCADE;

-- ทำให้ค่าสุ่มออกมาเหมือนเดิมทุกครั้งที่รัน
SELECT setseed(0.313);

-- =====================================================
-- 1. users (40 คน: admin 2, staff 3, passenger 35)
-- =====================================================
INSERT INTO users (full_name, email, phone, role, created_at)
SELECT
    f.first_name || ' ' || l.last_name,
    'user' || lpad(n::text, 2, '0') || '@maas.test',
    '08' || lpad((10000000 + n * 1373)::text, 8, '0'),
    CASE WHEN n <= 2 THEN 'admin' WHEN n <= 5 THEN 'staff' ELSE 'passenger' END,
    TIMESTAMPTZ '2026-06-01 09:00+07' + make_interval(days => n * 3)
FROM generate_series(1, 40) AS n
JOIN unnest(ARRAY[
    'สมชาย','สมหญิง','ณัฐพล','กมลชนก','ธนากร','พิมพ์ชนก','วีรภัทร','ศิริพร','อนุชา','ปวีณา',
    'กิตติพงษ์','จิราพร','ภานุวัฒน์','สุภาวดี','ชยพล','อรอุมา','ธีรวัฒน์','นภัสสร','วรเมธ','ปิยธิดา',
    'ศุภกร','กัญญาณัฐ','พงศกร','ชุติมา','ณัฐวุฒิ','รัตนาภรณ์','อภิสิทธิ์','เบญจมาศ','ปฐมพงศ์','วิภาวี',
    'ธนวัฒน์','สุนิสา','จักรพันธ์','ลลิตา','กฤษดา','มณีรัตน์','ภูมิพัฒน์','ชนิดา','วัชระ','อัญชลี'
]) WITH ORDINALITY AS f(first_name, i) ON f.i = n
JOIN unnest(ARRAY[
    'ใจดี','รักไทย','ศรีสุข','วงศ์สวัสดิ์','แก้วมณี','บุญมา','ทองดี','สุขเจริญ','พรหมมา','จันทร์เพ็ญ',
    'ศักดิ์สิทธิ์','มีสุข','เพชรรัตน์','อินทร์แก้ว','สายทอง','นาคสวัสดิ์','ประเสริฐ','ชัยมงคล','บุญเรือง','ทองคำ',
    'สมบูรณ์','วิเศษ','ศรีวงศ์','กิตติคุณ','รุ่งเรือง','ปัญญาดี','มั่นคง','สว่างวงศ์','พูลสวัสดิ์','เจริญผล',
    'ธรรมรักษ์','ศรีประเสริฐ','แสงทอง','วัฒนกุล','ปิ่นทอง','ชัยประเสริฐ','บุญประเสริฐ','สุวรรณ','เกษมสุข','ศรีสมบัติ'
]) WITH ORDINALITY AS l(last_name, i) ON l.i = n;

-- =====================================================
-- 2. lines (2 สาย)
-- =====================================================
INSERT INTO lines (line_name, code) VALUES
    ('สายสุขุมวิท', 'SUK'),
    ('สายสีลม',    'SIL');

-- =====================================================
-- 3. locations + stations (30 สถานี พิกัดโดยประมาณ)
-- =====================================================
WITH s(code, name, lat, lon, district) AS (
    VALUES
    ('N8',  'หมอชิต',            13.802600, 100.553800, 'จตุจักร'),
    ('N7',  'สะพานควาย',          13.793700, 100.549800, 'พญาไท'),
    ('N5',  'อารีย์',             13.779700, 100.544600, 'พญาไท'),
    ('N4',  'สนามเป้า',           13.772600, 100.542000, 'พญาไท'),
    ('N3',  'อนุสาวรีย์ชัยสมรภูมิ', 13.762800, 100.537200, 'ราชเทวี'),
    ('N2',  'พญาไท',             13.756900, 100.533800, 'ราชเทวี'),
    ('N1',  'ราชเทวี',            13.751600, 100.531600, 'ราชเทวี'),
    ('CEN', 'สยาม',              13.745600, 100.534100, 'ปทุมวัน'),
    ('E1',  'ชิดลม',             13.744100, 100.543000, 'ปทุมวัน'),
    ('E2',  'เพลินจิต',           13.743000, 100.549000, 'ปทุมวัน'),
    ('E3',  'นานา',              13.740500, 100.555500, 'คลองเตย'),
    ('E4',  'อโศก',              13.737000, 100.560300, 'วัฒนา'),
    ('E5',  'พร้อมพงษ์',          13.730500, 100.569700, 'วัฒนา'),
    ('E6',  'ทองหล่อ',           13.724300, 100.578500, 'วัฒนา'),
    ('E7',  'เอกมัย',             13.719400, 100.585000, 'วัฒนา'),
    ('E8',  'พระโขนง',           13.715200, 100.591700, 'คลองเตย'),
    ('E9',  'อ่อนนุช',            13.705600, 100.601100, 'พระโขนง'),
    ('E10', 'บางจาก',            13.696700, 100.605300, 'พระโขนง'),
    ('E11', 'ปุณณวิถี',           13.689300, 100.608900, 'พระโขนง'),
    ('E12', 'อุดมสุข',            13.679900, 100.609400, 'บางนา'),
    ('E13', 'บางนา',             13.668300, 100.604500, 'บางนา'),
    ('E14', 'แบริ่ง',             13.661100, 100.601600, 'บางนา'),
    ('W1',  'สนามกีฬาแห่งชาติ',    13.746500, 100.529100, 'ปทุมวัน'),
    ('S1',  'ราชดำริ',            13.739300, 100.539300, 'ปทุมวัน'),
    ('S2',  'ศาลาแดง',           13.728600, 100.534300, 'บางรัก'),
    ('S3',  'ช่องนนทรี',          13.723700, 100.529300, 'บางรัก'),
    ('S4',  'เซนต์หลุยส์',         13.720800, 100.526400, 'สาทร'),
    ('S5',  'สุรศักดิ์',           13.719300, 100.521500, 'สาทร'),
    ('S6',  'สะพานตากสิน',        13.718700, 100.514300, 'บางรัก'),
    ('S7',  'กรุงธนบุรี',          13.721000, 100.502500, 'คลองสาน')
),
ins AS (
    INSERT INTO locations (location_name, location_type, latitude, longitude, district)
    SELECT 'สถานี BTS ' || name, 'RAIL_STATION', lat, lon, district FROM s
    RETURNING location_id, location_name
)
INSERT INTO stations (station_code, station_name, location_id)
SELECT s.code, s.name, ins.location_id
FROM s JOIN ins ON ins.location_name = 'สถานี BTS ' || s.name;

-- =====================================================
-- 4. station_sequences (สยาม CEN อยู่ทั้ง 2 สาย)
-- =====================================================
INSERT INTO station_sequences (line_id, station_id, sequence_no)
SELECT l.line_id, st.station_id, x.seq
FROM unnest(ARRAY['N8','N7','N5','N4','N3','N2','N1','CEN',
                  'E1','E2','E3','E4','E5','E6','E7','E8','E9','E10','E11','E12','E13','E14'])
     WITH ORDINALITY AS x(code, seq)
JOIN stations st ON st.station_code = x.code
JOIN lines l ON l.code = 'SUK';

INSERT INTO station_sequences (line_id, station_id, sequence_no)
SELECT l.line_id, st.station_id, x.seq
FROM unnest(ARRAY['W1','CEN','S1','S2','S3','S4','S5','S6','S7'])
     WITH ORDINALITY AS x(code, seq)
JOIN stations st ON st.station_code = x.code
JOIN lines l ON l.code = 'SIL';

-- =====================================================
-- 5. card_types (ส่วนลดจำลอง)
-- =====================================================
INSERT INTO card_types (type_name, discount_rate) VALUES
    ('Adult',   0.00),
    ('Student', 0.10),
    ('Senior',  0.50);

-- =====================================================
-- 6. cards (1 ใบต่อผู้ใช้ = 40 ใบ)
-- =====================================================
INSERT INTO cards (user_id, card_type_id, card_number, status, issued_at)
SELECT
    u.user_id,
    ct.card_type_id,
    '7001' || lpad(u.rn::text, 8, '0'),
    CASE WHEN u.rn = 38 THEN 'BLOCKED' WHEN u.rn = 39 THEN 'EXPIRED' ELSE 'ACTIVE' END,
    u.created_at + INTERVAL '1 day'
FROM (SELECT user_id, created_at, row_number() OVER (ORDER BY user_id) AS rn FROM users) u
JOIN card_types ct ON ct.type_name =
    CASE WHEN u.rn % 5 = 0 THEN 'Senior' WHEN u.rn % 3 = 0 THEN 'Student' ELSE 'Adult' END;

-- =====================================================
-- 7. fare_tables (ทุกคู่สถานี 30×29 = 870 แถว)
--    ราคา = 14 + 3 × จำนวนสถานีที่ผ่าน (ต่ำสุด 17, สูงสุด 47 บาท)
--    ข้ามสายคิดระยะผ่านสถานีสยาม
-- =====================================================
WITH m AS (
    SELECT station_id, line_id, sequence_no FROM station_sequences
),
cen AS (
    SELECT ss.line_id, ss.sequence_no
    FROM station_sequences ss JOIN stations s USING (station_id)
    WHERE s.station_code = 'CEN'
),
d AS (
    SELECT a.station_id AS o, b.station_id AS d,
           MIN(CASE WHEN a.line_id = b.line_id
                    THEN abs(a.sequence_no - b.sequence_no)
                    ELSE abs(a.sequence_no - ca.sequence_no) + abs(b.sequence_no - cb.sequence_no)
               END) AS hops
    FROM m a
    JOIN m b   ON a.station_id <> b.station_id
    JOIN cen ca ON ca.line_id = a.line_id
    JOIN cen cb ON cb.line_id = b.line_id
    GROUP BY a.station_id, b.station_id
)
INSERT INTO fare_tables (origin_station_id, destination_station_id, base_fare)
SELECT o, d, LEAST(47, 14 + 3 * hops) FROM d;

-- =====================================================
-- 8. payments + card_topups (เติมเงิน 2–5 ครั้งต่อบัตร ช่วง 25 ก.ย. – 9 พ.ย. 2569)
-- =====================================================
WITH t AS MATERIALIZED (
    SELECT c.card_id, c.user_id,
           (ARRAY[100, 200, 300, 500])[1 + floor(random() * 4)::int]                     AS amount,
           (ARRAY['CREDIT_CARD','QR','CASH','MOBILE_BANKING'])[1 + floor(random() * 4)::int] AS method,
           TIMESTAMPTZ '2026-09-25 06:00+07' + random() * INTERVAL '45 days'              AS ts
    FROM cards c
    CROSS JOIN LATERAL generate_series(1, 2 + (c.card_id % 4)::int) AS k
),
p AS (
    INSERT INTO payments (user_id, service_type, amount, method, status, paid_at)
    SELECT user_id, 'RAIL_TOPUP', amount, method, 'PAID', ts FROM t
    RETURNING payment_id, user_id, amount, paid_at
)
INSERT INTO card_topups (card_id, payment_id, amount, topped_up_at)
SELECT t.card_id, p.payment_id, p.amount, p.paid_at
FROM p JOIN t ON t.user_id = p.user_id AND t.ts = p.paid_at AND t.amount = p.amount;

-- การชำระที่ไม่สำเร็จ / คืนเงิน (ไม่มีการเติมเงินคู่กัน) ไว้ใช้กับ query CASE WHEN
INSERT INTO payments (user_id, service_type, amount, method, status, paid_at)
SELECT u.user_id, 'RAIL_TOPUP', x.amount, x.method, x.status, x.ts::timestamptz
FROM (VALUES
    (7,  200, 'CREDIT_CARD',    'FAILED',   '2026-10-03 08:12+07'),
    (12, 500, 'QR',             'FAILED',   '2026-10-11 18:40+07'),
    (18, 100, 'MOBILE_BANKING', 'PENDING',  '2026-11-09 21:05+07'),
    (23, 300, 'CREDIT_CARD',    'REFUNDED', '2026-10-20 12:30+07'),
    (31, 200, 'QR',             'FAILED',   '2026-10-27 07:55+07'),
    (36, 500, 'CREDIT_CARD',    'REFUNDED', '2026-11-02 16:20+07')
) AS x(rn, amount, method, status, ts)
JOIN (SELECT user_id, row_number() OVER (ORDER BY user_id) AS rn FROM users) u ON u.rn = x.rn;

-- =====================================================
-- 9. gate_logs (~430 เที่ยว ช่วง 1 ต.ค. – 9 พ.ย. 2569)
--    ช่วงเช้า 7–9 น. และเย็น 17–19 น. หนาแน่นกว่าปกติ
--    ~93% COMPLETED, ~3% IN_JOURNEY (ลืมแตะออก), ~4% CANCELLED
-- =====================================================
WITH ca AS (SELECT array_agg(card_id ORDER BY card_id) AS a FROM cards WHERE status = 'ACTIVE'),
     sa AS (SELECT array_agg(station_id ORDER BY station_id) AS a FROM stations),
g AS MATERIALIZED (
    SELECT
        ca.a[1 + floor(random() * array_length(ca.a, 1))::int] AS card_id,
        sa.a[1 + floor(random() * array_length(sa.a, 1))::int] AS o,
        sa.a[1 + floor(random() * array_length(sa.a, 1))::int] AS d,
        random() AS r_status, random() AS r_peak, random() AS r_hour,
        floor(random() * 60)::int AS minute,
        floor(random() * 40)::int AS day_off,
        floor(random() * 5)::int  AS extra_min
    FROM generate_series(1, 450), ca, sa
),
x AS (
    SELECT g.*,
        CASE WHEN r_status < 0.04 THEN 'CANCELLED'
             WHEN r_status < 0.07 THEN 'IN_JOURNEY'
             ELSE 'COMPLETED' END AS st,
        (DATE '2026-10-01' + day_off
            + make_interval(hours => CASE WHEN r_peak < 0.35 THEN 7  + floor(r_hour * 2)::int
                                          WHEN r_peak < 0.70 THEN 17 + floor(r_hour * 2)::int
                                          ELSE 6 + floor(r_hour * 17)::int END,
                            mins  => minute)
        ) AT TIME ZONE 'Asia/Bangkok' AS et
    FROM g
    WHERE o <> d
)
INSERT INTO gate_logs (card_id, entry_station_id, exit_station_id, entry_time, exit_time, fare_charged, status)
SELECT
    x.card_id,
    x.o,
    CASE WHEN x.st = 'COMPLETED' THEN x.d END,
    x.et,
    CASE WHEN x.st = 'COMPLETED'
         THEN x.et + make_interval(mins => ((ft.base_fare - 14) / 3 * 2.5 + 4)::int + x.extra_min) END,
    CASE WHEN x.st = 'COMPLETED' THEN ROUND(ft.base_fare * (1 - ct.discount_rate), 0) ELSE 0 END,
    x.st
FROM x
JOIN fare_tables ft ON ft.origin_station_id = x.o AND ft.destination_station_id = x.d
JOIN cards c        ON c.card_id = x.card_id
JOIN card_types ct  ON ct.card_type_id = c.card_type_id
ORDER BY x.et;

-- =====================================================
-- 10. ยอดเงินคงเหลือ = เงินตั้งต้น 100 + เติมเงินทั้งหมด − ค่าโดยสารทั้งหมด
-- =====================================================
UPDATE cards c
SET balance = GREATEST(0,
      100
    + COALESCE((SELECT SUM(amount)       FROM card_topups t WHERE t.card_id = c.card_id), 0)
    - COALESCE((SELECT SUM(fare_charged) FROM gate_logs  g WHERE g.card_id = c.card_id), 0));

-- =====================================================
-- ตรวจผล: จำนวนแถวแต่ละตาราง
-- =====================================================
SELECT 'users' AS table_name, COUNT(*) AS row_count FROM users
UNION ALL SELECT 'locations',         COUNT(*) FROM locations
UNION ALL SELECT 'lines',             COUNT(*) FROM lines
UNION ALL SELECT 'stations',          COUNT(*) FROM stations
UNION ALL SELECT 'station_sequences', COUNT(*) FROM station_sequences
UNION ALL SELECT 'card_types',        COUNT(*) FROM card_types
UNION ALL SELECT 'cards',             COUNT(*) FROM cards
UNION ALL SELECT 'fare_tables',       COUNT(*) FROM fare_tables
UNION ALL SELECT 'payments',          COUNT(*) FROM payments
UNION ALL SELECT 'card_topups',       COUNT(*) FROM card_topups
UNION ALL SELECT 'gate_logs',         COUNT(*) FROM gate_logs
UNION ALL SELECT 'chat_logs',         COUNT(*) FROM chat_logs;
