-- =====================================================================
-- 21: สร้างข้อมูลรถเมล์ใหม่ (เลขสายจริง + ป้ายรอบสถานี BTS)
-- ใช้กับฐานข้อมูลที่รัน 20_bus_all.sql ไปแล้ว: ลบข้อมูลสาย ป้าย รอบวิ่ง การขึ้นรถเดิม แล้วสร้างใหม่
-- รถเมล์ (buses) และพนักงานขับรถ (drivers) ใช้ชุดเดิม
-- รันไฟล์นี้ครั้งเดียว
-- =====================================================================
SELECT setseed(0.303);

-- ลบข้อมูลเดิม (เรียงจากตารางลูกไปตารางแม่ ตาม Foreign Key)
DELETE FROM bus_rides;
DELETE FROM payments WHERE service_type = 'BUS';
DELETE FROM trip_logs;
DELETE FROM bus_schedules;
DELETE FROM route_stops;
DELETE FROM bus_stops;
DELETE FROM locations WHERE location_type = 'BUS_STOP';
DELETE FROM bus_routes;

-- 2.1 สายรถเมล์ (เลขสายจริงที่วิ่งผ่านถนนแนวรถไฟฟ้า BTS)
--     ข้อมูลจำลอง: เลขสายและถนนอ้างอิงเส้นทางจริง แต่ลำดับป้ายย่อเหลือเฉพาะป้ายรอบสถานี BTS
INSERT INTO bus_routes (route_no, route_name, fare) VALUES
    ('2',  'สำโรง – ปากคลองตลาด (ถ.สุขุมวิท, พระราม 1)', 15),
    ('25', 'ปากน้ำ – ท่าช้าง (ถ.สุขุมวิท, พระราม 1)',     13),
    ('29', 'รังสิต – หัวลำโพง (ถ.พหลโยธิน, พญาไท)',       15),
    ('77', 'หมอชิต 2 – สาธุประดิษฐ์ (ถ.พหลโยธิน, สีลม)',   20),
    ('15', 'บางกะปิ – ท่าพระ (ถ.ราชดำริ, สีลม)',          13),
    ('76', 'แสมดำ – ประตูน้ำ (ถ.สาทร, สีลม)',             13);

-- 2.2 ป้ายรถเมล์ 30 ป้าย อยู่รอบสถานี BTS ทุกสถานี (ห่างประมาณ 70–100 เมตร)
--     ชื่อป้ายตามสถานที่สำคัญจริงหน้าสถานี, รหัสป้าย B-<รหัสสถานี> ใช้จับคู่กับสถานี
WITH n(code, stop_name) AS (
    VALUES
    ('N8', 'ป้ายสวนจตุจักร'),        ('N7', 'ป้ายสะพานควาย'),        ('N5', 'ป้ายซอยอารีย์'),
    ('N4', 'ป้ายกองทัพบก'),          ('N3', 'ป้ายอนุสาวรีย์ชัยฯ'),     ('N2', 'ป้ายพญาไท'),
    ('N1', 'ป้ายราชเทวี'),           ('CEN', 'ป้ายสยามพารากอน'),     ('E1', 'ป้ายเซ็นทรัลชิดลม'),
    ('E2', 'ป้ายเพลินจิต'),           ('E3', 'ป้ายสุขุมวิท ซอย 3'),     ('E4', 'ป้ายอโศก (เทอร์มินอล 21)'),
    ('E5', 'ป้ายเอ็มโพเรียม'),        ('E6', 'ป้ายทองหล่อ'),           ('E7', 'ป้ายเอกมัย (ขนส่งตะวันออก)'),
    ('E8', 'ป้ายพระโขนง'),           ('E9', 'ป้ายอ่อนนุช'),           ('E10', 'ป้ายบางจาก'),
    ('E11', 'ป้ายปุณณวิถี'),          ('E12', 'ป้ายอุดมสุข'),          ('E13', 'ป้ายบางนา'),
    ('E14', 'ป้ายแบริ่ง'),            ('W1', 'ป้าย MBK'),             ('S1', 'ป้ายราชดำริ'),
    ('S2', 'ป้ายศาลาแดง (สีลม)'),     ('S3', 'ป้ายช่องนนทรี'),         ('S4', 'ป้ายเซนต์หลุยส์'),
    ('S5', 'ป้ายสุรศักดิ์'),           ('S6', 'ป้ายสะพานตากสิน'),       ('S7', 'ป้ายกรุงธนบุรี')
),
s AS (
    SELECT n.code, n.stop_name, l.latitude + 0.0006 AS lat, l.longitude + 0.0004 AS lon, l.district
    FROM n
    JOIN stations st ON st.station_code = n.code
    JOIN locations l ON l.location_id = st.location_id
),
ins AS (
    INSERT INTO locations (location_name, location_type, latitude, longitude, district)
    SELECT 'ป้ายรถเมล์ ' || code || ' ' || stop_name, 'BUS_STOP', lat, lon, district FROM s
    RETURNING location_id, location_name
)
INSERT INTO bus_stops (stop_code, stop_name, location_id)
SELECT 'B-' || s.code, s.stop_name, ins.location_id
FROM s JOIN ins ON ins.location_name = 'ป้ายรถเมล์ ' || s.code || ' ' || s.stop_name;

-- 2.3 ลำดับป้ายของแต่ละสาย (เฉพาะช่วงที่ผ่านแนว BTS)
WITH r(route_no, stops) AS (
    VALUES
    ('2',  ARRAY['B-E14','B-E13','B-E12','B-E11','B-E10','B-E9','B-E8','B-E7','B-E6','B-E5','B-E4','B-E3','B-E2','B-E1','B-CEN','B-W1']),
    ('25', ARRAY['B-E13','B-E9','B-E7','B-E5','B-E4','B-E2','B-E1','B-CEN','B-W1']),
    ('29', ARRAY['B-N8','B-N7','B-N5','B-N4','B-N3','B-N2','B-W1']),
    ('77', ARRAY['B-N8','B-N7','B-N5','B-N3','B-N1','B-S1','B-S2','B-S3','B-S5']),
    ('15', ARRAY['B-E1','B-S1','B-S2','B-S3','B-S5','B-S6']),
    ('76', ARRAY['B-S7','B-S6','B-S5','B-S4','B-S3','B-S2','B-S1','B-CEN'])
)
INSERT INTO route_stops (route_id, stop_id, sequence_no)
SELECT br.route_id, bs.stop_id, x.seq
FROM r
CROSS JOIN LATERAL unnest(r.stops) WITH ORDINALITY AS x(code, seq)
JOIN bus_routes br ON br.route_no = r.route_no
JOIN bus_stops bs  ON bs.stop_code = x.code;

-- 2.6 ตารางเดินรถ 120 รอบ (40 วัน × 3 รอบ/วัน กระจายทุกสาย)
--     รถคันที่ k วิ่งสายลำดับที่ ((k-1) % 6) + 1 และสลับคนขับ (อ้างด้วยลำดับ ไม่ผูกกับเลข id)
WITH r AS (SELECT route_id, row_number() OVER (ORDER BY route_id) AS rn FROM bus_routes),
     b AS (SELECT bus_id, row_number() OVER (ORDER BY bus_id) AS rn FROM buses),
     d AS (SELECT driver_id, row_number() OVER (ORDER BY driver_id) AS rn FROM drivers)
INSERT INTO bus_schedules (route_id, bus_id, driver_id, departure_time)
SELECT r.route_id, b.bus_id, d.driver_id,
       ((DATE '2026-10-01' + (n - 1) / 3)
         + make_interval(hours => (ARRAY[6, 12, 17])[1 + (n - 1) % 3], mins => (n * 7) % 60))
         AT TIME ZONE 'Asia/Bangkok'
FROM generate_series(1, 120) AS n
JOIN b ON b.rn = ((n - 1) % 12) + 1
JOIN r ON r.rn = (((n - 1) % 12) % 6) + 1
JOIN d ON d.rn = ((n + (n / 12)) % 12) + 1;

-- 2.7 บันทึกการวิ่งจริง: ~5% ถูกยกเลิก (ไม่มีบันทึก), ที่เหลือออกช้า 0–15 นาที
INSERT INTO trip_logs (schedule_id, actual_departure, actual_arrival)
SELECT s.schedule_id,
       s.departure_time + make_interval(mins => d.delay),
       s.departure_time + make_interval(mins => d.delay + rs.stop_count::int * 4 + floor(random() * 10)::int)
FROM bus_schedules s
JOIN (SELECT route_id, COUNT(*) AS stop_count FROM route_stops GROUP BY route_id) rs USING (route_id)
-- อ้าง s.schedule_id ใน LATERAL เพื่อบังคับให้สุ่มใหม่ทุกแถว (ไม่งั้นจะสุ่มครั้งเดียวใช้ทุกแถว)
CROSS JOIN LATERAL (SELECT floor(random() * 16 + 0 * s.schedule_id)::int AS delay,
                           random() + 0 * s.schedule_id                AS r_cancel) d
WHERE d.r_cancel >= 0.05;

-- 2.8 การขึ้นรถ 180 ครั้ง + การชำระเงิน (วนสร้างทีละครั้ง)
DO $$
DECLARE
    v_users    BIGINT[];
    v_trips    BIGINT[];
    v_user     BIGINT;
    v_sched    BIGINT;
    v_route    BIGINT;
    v_fare     NUMERIC;
    v_dep      TIMESTAMPTZ;
    v_n_stops  INT;
    v_b        INT;
    v_a        INT;
    v_board    BIGINT;
    v_alight   BIGINT;
    v_time     TIMESTAMPTZ;
    v_payment  BIGINT;
    i INT;
BEGIN
    SELECT array_agg(user_id ORDER BY user_id) INTO v_users FROM users WHERE email LIKE '%@maas.test';
    SELECT array_agg(schedule_id ORDER BY schedule_id) INTO v_trips FROM trip_logs;

    FOR i IN 1..180 LOOP
        v_user  := v_users[1 + floor(random() * array_length(v_users, 1))::int];
        v_sched := v_trips[1 + floor(random() * array_length(v_trips, 1))::int];

        SELECT s.route_id, r.fare, t.actual_departure INTO v_route, v_fare, v_dep
        FROM bus_schedules s JOIN bus_routes r USING (route_id) JOIN trip_logs t USING (schedule_id)
        WHERE s.schedule_id = v_sched;

        -- สุ่มป้ายขึ้นก่อนป้ายลง
        SELECT COUNT(*) INTO v_n_stops FROM route_stops WHERE route_id = v_route;
        v_b := 1 + floor(random() * (v_n_stops - 1))::int;
        v_a := v_b + 1 + floor(random() * (v_n_stops - v_b))::int;
        SELECT stop_id INTO v_board  FROM route_stops WHERE route_id = v_route AND sequence_no = v_b;
        SELECT stop_id INTO v_alight FROM route_stops WHERE route_id = v_route AND sequence_no = v_a;
        v_time := v_dep + make_interval(mins => (v_b - 1) * 4);

        INSERT INTO payments (user_id, service_type, amount, method, status, paid_at)
        VALUES (v_user, 'BUS', v_fare,
                (ARRAY['CASH', 'CASH', 'QR', 'MOBILE_BANKING', 'CREDIT_CARD'])[1 + floor(random() * 5)::int],
                'PAID', v_time)
        RETURNING payment_id INTO v_payment;

        INSERT INTO bus_rides (user_id, schedule_id, board_stop_id, alight_stop_id, payment_id, fare_paid, boarded_at)
        VALUES (v_user, v_sched, v_board, v_alight, v_payment, v_fare, v_time);
    END LOOP;
END $$;


