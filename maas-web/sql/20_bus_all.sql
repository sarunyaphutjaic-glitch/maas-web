-- =====================================================================
-- Module 3: ระบบบริหารและตารางเดินรถประจำทาง (Bus Operation & Schedule)
-- สมาชิกคนที่ 3
--
-- ตาราง (8): bus_routes, bus_stops, route_stops, buses, drivers,
--            bus_schedules, trip_logs, bus_rides
-- เชื่อมกับตารางกลาง:
--   bus_stops.location_id → locations  (ป้ายรถเมล์อยู่บนแผนที่เดียวกับสถานี BTS → หาป้ายใกล้สถานีได้)
--   bus_rides.user_id     → users      (ผู้โดยสารคนเดียวกับที่ใช้ BTS / สายการบิน)
--   bus_rides.payment_id  → payments   (service_type = 'BUS')
--
-- Normalization: เดิมออกแบบเป็นตาราง buses_and_drivers (ข้อมูลรถและคนขับรวมกัน)
--   ทำให้ข้อมูลคนขับซ้ำทุกครั้งที่ไปขับรถคันอื่น (ละเมิด 3NF) → แยกเป็น buses + drivers
--   แล้วจับคู่รถกับคนขับในแต่ละรอบผ่าน bus_schedules
--
-- ต้องรันหลัง 00_central_schema.sql, 04_seed_central_bts.sql (ใช้ users และพิกัดสถานี BTS)
-- ไฟล์นี้มี 4 ส่วน: (1) สร้างตาราง (2) ข้อมูลจำลอง (3) Views (4) RLS
-- =====================================================================


-- #####################################################################
-- ส่วนที่ 1: สร้างตาราง
-- #####################################################################

-- 1.1 สายรถเมล์
CREATE TABLE IF NOT EXISTS bus_routes (
    route_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    route_no    VARCHAR(10)   NOT NULL UNIQUE,            -- เลขสาย เช่น 2, 77, 511
    route_name  VARCHAR(150)  NOT NULL,                   -- ต้นทาง–ปลายทาง
    fare        NUMERIC(6, 2) NOT NULL,                   -- ค่าโดยสารเหมาจ่ายต่อเที่ยว
    CONSTRAINT chk_route_fare CHECK (fare > 0)
);

-- 1.2 ป้ายรถเมล์ (1 ป้าย = 1 location ในตารางกลาง)
CREATE TABLE IF NOT EXISTS bus_stops (
    stop_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    stop_code    VARCHAR(10)  NOT NULL UNIQUE,
    stop_name    VARCHAR(100) NOT NULL,
    location_id  BIGINT       NOT NULL UNIQUE,
    CONSTRAINT fk_bus_stops_location
        FOREIGN KEY (location_id) REFERENCES locations(location_id) ON DELETE RESTRICT
);

-- 1.3 ลำดับป้ายในแต่ละสาย (M:N ระหว่าง bus_routes และ bus_stops)
CREATE TABLE IF NOT EXISTS route_stops (
    route_id     BIGINT NOT NULL,
    stop_id      BIGINT NOT NULL,
    sequence_no  INT    NOT NULL,
    PRIMARY KEY (route_id, stop_id),
    CONSTRAINT fk_route_stops_route FOREIGN KEY (route_id) REFERENCES bus_routes(route_id) ON DELETE CASCADE,
    CONSTRAINT fk_route_stops_stop  FOREIGN KEY (stop_id)  REFERENCES bus_stops(stop_id)  ON DELETE CASCADE,
    CONSTRAINT uq_route_sequence UNIQUE (route_id, sequence_no),
    CONSTRAINT chk_route_sequence CHECK (sequence_no > 0)
);

-- 1.4 รถเมล์
CREATE TABLE IF NOT EXISTS buses (
    bus_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plate_no   VARCHAR(20) NOT NULL UNIQUE,
    bus_type   VARCHAR(10) NOT NULL,
    capacity   INT         NOT NULL,
    CONSTRAINT chk_bus_type     CHECK (bus_type IN ('NORMAL', 'AIRCON', 'EV')),
    CONSTRAINT chk_bus_capacity CHECK (capacity > 0)
);

-- 1.5 พนักงานขับรถ
CREATE TABLE IF NOT EXISTS drivers (
    driver_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL,
    license_no  VARCHAR(20)  NOT NULL UNIQUE,
    phone       VARCHAR(20),
    hired_date  DATE         NOT NULL
);

-- 1.6 ตารางเดินรถ (รอบวิ่งที่วางแผนไว้: สายไหน รถคันไหน ใครขับ ออกกี่โมง)
CREATE TABLE IF NOT EXISTS bus_schedules (
    schedule_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    route_id        BIGINT      NOT NULL,
    bus_id          BIGINT      NOT NULL,
    driver_id       BIGINT      NOT NULL,
    departure_time  TIMESTAMPTZ NOT NULL,
    CONSTRAINT fk_schedules_route  FOREIGN KEY (route_id)  REFERENCES bus_routes(route_id) ON DELETE RESTRICT,
    CONSTRAINT fk_schedules_bus    FOREIGN KEY (bus_id)    REFERENCES buses(bus_id)        ON DELETE RESTRICT,
    CONSTRAINT fk_schedules_driver FOREIGN KEY (driver_id) REFERENCES drivers(driver_id)   ON DELETE RESTRICT,
    CONSTRAINT uq_bus_departure    UNIQUE (bus_id, departure_time),     -- รถคันเดียวออกพร้อมกัน 2 รอบไม่ได้
    CONSTRAINT uq_driver_departure UNIQUE (driver_id, departure_time)   -- คนขับคนเดียวขับ 2 คันพร้อมกันไม่ได้
);

-- 1.7 บันทึกการวิ่งจริง (มีเฉพาะรอบที่วิ่งแล้ว รอบที่ยกเลิกจะไม่มีแถวนี้)
CREATE TABLE IF NOT EXISTS trip_logs (
    trip_log_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    schedule_id       BIGINT      NOT NULL UNIQUE,         -- 1 รอบ = 1 บันทึก
    actual_departure  TIMESTAMPTZ NOT NULL,
    actual_arrival    TIMESTAMPTZ NOT NULL,
    CONSTRAINT fk_trip_logs_schedule FOREIGN KEY (schedule_id) REFERENCES bus_schedules(schedule_id) ON DELETE CASCADE,
    CONSTRAINT chk_trip_time CHECK (actual_arrival > actual_departure)
);

-- 1.8 การขึ้นรถของผู้โดยสาร (เชื่อมผู้ใช้และการชำระเงินเข้ากับระบบรถเมล์)
CREATE TABLE IF NOT EXISTS bus_rides (
    ride_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         BIGINT        NOT NULL,
    schedule_id     BIGINT        NOT NULL,
    board_stop_id   BIGINT        NOT NULL,
    alight_stop_id  BIGINT        NOT NULL,
    payment_id      BIGINT        UNIQUE,
    fare_paid       NUMERIC(6, 2) NOT NULL,
    boarded_at      TIMESTAMPTZ   NOT NULL,
    CONSTRAINT fk_rides_user     FOREIGN KEY (user_id)        REFERENCES users(user_id)            ON DELETE RESTRICT,
    CONSTRAINT fk_rides_schedule FOREIGN KEY (schedule_id)    REFERENCES bus_schedules(schedule_id) ON DELETE RESTRICT,
    CONSTRAINT fk_rides_board    FOREIGN KEY (board_stop_id)  REFERENCES bus_stops(stop_id),
    CONSTRAINT fk_rides_alight   FOREIGN KEY (alight_stop_id) REFERENCES bus_stops(stop_id),
    CONSTRAINT fk_rides_payment  FOREIGN KEY (payment_id)     REFERENCES payments(payment_id)       ON DELETE RESTRICT,
    CONSTRAINT chk_ride_stops CHECK (board_stop_id <> alight_stop_id),
    CONSTRAINT chk_fare_paid  CHECK (fare_paid >= 0)
);

CREATE INDEX IF NOT EXISTS idx_route_stops_stop    ON route_stops(stop_id);
CREATE INDEX IF NOT EXISTS idx_schedules_route     ON bus_schedules(route_id);
CREATE INDEX IF NOT EXISTS idx_schedules_departure ON bus_schedules(departure_time);
CREATE INDEX IF NOT EXISTS idx_rides_user          ON bus_rides(user_id);
CREATE INDEX IF NOT EXISTS idx_rides_schedule      ON bus_rides(schedule_id);


-- #####################################################################
-- ส่วนที่ 2: ข้อมูลจำลอง
-- routes 6, stops 38, buses 12, drivers 12, schedules 120, trip_logs ~114, rides 180
-- #####################################################################
SELECT setseed(0.303);

-- 2.1 สายรถเมล์
INSERT INTO bus_routes (route_no, route_name, fare) VALUES
    ('2',   'สำโรง – ปากคลองตลาด',          15),
    ('77',  'สถานีขนส่งหมอชิต 2 – สาธุประดิษฐ์', 20),
    ('29',  'รังสิต – หัวลำโพง',             25),
    ('511', 'สายใต้ใหม่ – ปากน้ำ',           20),
    ('15',  'สนามหลวง – สยาม',              10),
    ('40',  'หัวลำโพง – เอกมัย',             13);

-- 2.2 ป้ายรถเมล์
-- 30 ป้ายตั้งห่างจากสถานี BTS ประมาณ 70–100 เมตร (รหัส B-<รหัสสถานี>) → ใช้หาป้ายใกล้สถานี
WITH s AS (
    SELECT st.station_code, st.station_name, l.latitude + 0.0006 AS lat, l.longitude + 0.0004 AS lon, l.district
    FROM stations st JOIN locations l USING (location_id)
),
ins AS (
    INSERT INTO locations (location_name, location_type, latitude, longitude, district)
    SELECT 'ป้ายรถเมล์ ' || station_name, 'BUS_STOP', lat, lon, district FROM s
    RETURNING location_id, location_name
)
INSERT INTO bus_stops (stop_code, stop_name, location_id)
SELECT 'B-' || s.station_code, 'ป้าย' || s.station_name, ins.location_id
FROM s JOIN ins ON ins.location_name = 'ป้ายรถเมล์ ' || s.station_name;

-- 8 ป้ายที่ไม่อยู่ใกล้ BTS
WITH h(code, name, lat, lon, district) AS (
    VALUES
    ('H1', 'หัวลำโพง',             13.738800, 100.517000, 'ปทุมวัน'),
    ('H2', 'สนามหลวง',             13.755300, 100.493000, 'พระนคร'),
    ('H3', 'ปากคลองตลาด',          13.739700, 100.498700, 'พระนคร'),
    ('H4', 'ปากน้ำ',               13.599000, 100.596800, 'เมืองสมุทรปราการ'),
    ('H5', 'สำโรง',                13.646000, 100.596000, 'บางพลี'),
    ('H6', 'รังสิต',               13.989000, 100.617000, 'ธัญบุรี'),
    ('H7', 'สถานีขนส่งหมอชิต 2',    13.813000, 100.548000, 'จตุจักร'),
    ('H8', 'สถานีขนส่งสายใต้ใหม่',   13.784000, 100.406000, 'ตลิ่งชัน')
),
ins AS (
    INSERT INTO locations (location_name, location_type, latitude, longitude, district)
    SELECT 'ป้ายรถเมล์ ' || name, 'BUS_STOP', lat, lon, district FROM h
    RETURNING location_id, location_name
)
INSERT INTO bus_stops (stop_code, stop_name, location_id)
SELECT h.code, 'ป้าย' || h.name, ins.location_id
FROM h JOIN ins ON ins.location_name = 'ป้ายรถเมล์ ' || h.name;

-- 2.3 ลำดับป้ายของแต่ละสาย
WITH r(route_no, stops) AS (
    VALUES
    ('2',   ARRAY['H5','B-E14','B-E13','B-E12','B-E11','B-E10','B-E9','B-E8','B-E7','B-E6','B-E5','B-E4','B-E3','B-E2','B-E1','B-CEN','B-W1','H3']),
    ('77',  ARRAY['H7','B-N8','B-N7','B-N5','B-N4','B-N3','B-N2','B-N1','B-CEN','B-S1','B-S2','B-S3','B-S5']),
    ('29',  ARRAY['H6','H7','B-N8','B-N3','B-N1','H1']),
    ('511', ARRAY['H8','H2','B-W1','B-CEN','B-E1','B-E4','B-E9','B-E14','H4']),
    ('15',  ARRAY['H2','H3','B-S7','B-S6','B-S4','B-S2','B-S1','B-CEN']),
    ('40',  ARRAY['H1','B-W1','B-CEN','B-E2','B-E3','B-E4','B-E5','B-E6','B-E7'])
)
INSERT INTO route_stops (route_id, stop_id, sequence_no)
SELECT br.route_id, bs.stop_id, x.seq
FROM r
CROSS JOIN LATERAL unnest(r.stops) WITH ORDINALITY AS x(code, seq)
JOIN bus_routes br ON br.route_no = r.route_no
JOIN bus_stops bs  ON bs.stop_code = x.code;

-- 2.4 รถเมล์ 12 คัน (สายละ 2 คัน)
INSERT INTO buses (plate_no, bus_type, capacity)
SELECT '1' || (i % 9 + 1) || '-' || (4000 + i * 37) || ' กทม',
       (ARRAY['NORMAL', 'AIRCON', 'EV'])[1 + i % 3],
       (ARRAY[45, 40, 35])[1 + i % 3]
FROM generate_series(1, 12) AS i;

-- 2.5 พนักงานขับรถ 12 คน
INSERT INTO drivers (full_name, license_no, phone, hired_date)
SELECT n.name, 'DL' || lpad((52000 + i * 113)::text, 8, '0'),
       '09' || lpad((30000000 + i * 4111)::text, 8, '0'),
       DATE '2015-01-01' + (i * 211)::int
FROM unnest(ARRAY[
    'บุญชัย ขยันดี','สมศักดิ์ ใจเย็น','ประยูร ตรงเวลา','วิชัย ปลอดภัย','สุริยา ขับดี','อำนาจ มั่นใจ',
    'ชาตรี สุภาพ','เกรียงไกร รอบคอบ','ทวีศักดิ์ ทองดี','มานพ สายลม','ไพโรจน์ แสงสว่าง','ธนพล ใจกว้าง'
]) WITH ORDINALITY AS n(name, i);

-- 2.6 ตารางเดินรถ 120 รอบ (40 วัน × 3 รอบ/วัน กระจายทุกสาย)
--     รถคันที่ k วิ่งสาย ((k-1) % 6) + 1 และสลับคนขับ
INSERT INTO bus_schedules (route_id, bus_id, driver_id, departure_time)
SELECT r.route_id,
       ((n - 1) % 12) + 1                                        AS bus_id,
       ((n + (n / 12)) % 12) + 1                                 AS driver_id,
       ((DATE '2026-10-01' + (n - 1) / 3)
         + make_interval(hours => (ARRAY[6, 12, 17])[1 + (n - 1) % 3], mins => (n * 7) % 60))
         AT TIME ZONE 'Asia/Bangkok'
FROM generate_series(1, 120) AS n
JOIN bus_routes r ON r.route_id = (((n - 1) % 12) % 6) + 1;

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


-- #####################################################################
-- ส่วนที่ 3: Views (security_invoker = true → เคารพ RLS ของผู้ใช้)
-- #####################################################################

-- 3.1 รายละเอียดการขึ้นรถแต่ละครั้ง (JOIN 7 ตาราง)
CREATE OR REPLACE VIEW v_bus_ride_details
WITH (security_invoker = true) AS
SELECT
    r.ride_id,
    r.user_id,
    u.full_name                                          AS passenger_name,
    br.route_no,
    br.route_name,
    sb.stop_name                                         AS board_stop,
    sa.stop_name                                         AS alight_stop,
    r.boarded_at,
    (r.boarded_at AT TIME ZONE 'Asia/Bangkok')::date     AS ride_date,
    EXTRACT(HOUR FROM r.boarded_at AT TIME ZONE 'Asia/Bangkok')::int AS ride_hour,
    r.fare_paid,
    p.method                                             AS payment_method,
    b.bus_type
FROM bus_rides r
JOIN users u          ON u.user_id = r.user_id
JOIN bus_schedules s  ON s.schedule_id = r.schedule_id
JOIN bus_routes br    ON br.route_id = s.route_id
JOIN buses b          ON b.bus_id = s.bus_id
JOIN bus_stops sb     ON sb.stop_id = r.board_stop_id
JOIN bus_stops sa     ON sa.stop_id = r.alight_stop_id
LEFT JOIN payments p  ON p.payment_id = r.payment_id;

-- 3.2 สรุปรายสาย: จำนวนรอบ, ผู้โดยสาร, รายได้, ความล่าช้าเฉลี่ย
CREATE OR REPLACE VIEW v_route_ridership
WITH (security_invoker = true) AS
SELECT
    br.route_no,
    br.route_name,
    br.fare,
    COUNT(DISTINCT s.schedule_id)                                              AS scheduled_trips,
    COUNT(DISTINCT t.schedule_id)                                              AS completed_trips,
    (SELECT COUNT(*) FROM bus_rides r JOIN bus_schedules s2 USING (schedule_id)
      WHERE s2.route_id = br.route_id)                                         AS passengers,
    (SELECT COALESCE(SUM(r.fare_paid), 0) FROM bus_rides r JOIN bus_schedules s2 USING (schedule_id)
      WHERE s2.route_id = br.route_id)                                         AS revenue,
    ROUND(AVG(EXTRACT(EPOCH FROM (t.actual_departure - s.departure_time)) / 60), 1) AS avg_delay_min
FROM bus_routes br
LEFT JOIN bus_schedules s ON s.route_id = br.route_id
LEFT JOIN trip_logs t     ON t.schedule_id = s.schedule_id
GROUP BY br.route_id, br.route_no, br.route_name, br.fare;

-- 3.3 ภาระงานของพนักงานขับรถ
CREATE OR REPLACE VIEW v_driver_workload
WITH (security_invoker = true) AS
SELECT
    d.driver_id,
    d.full_name                                                                AS driver_name,
    COUNT(t.trip_log_id)                                                       AS completed_trips,
    ROUND(SUM(EXTRACT(EPOCH FROM (t.actual_arrival - t.actual_departure))) / 3600, 1) AS driving_hours,
    ROUND(AVG(EXTRACT(EPOCH FROM (t.actual_departure - s.departure_time)) / 60), 1)   AS avg_delay_min,
    COUNT(DISTINCT s.route_id)                                                 AS routes_driven
FROM drivers d
LEFT JOIN bus_schedules s ON s.driver_id = d.driver_id
LEFT JOIN trip_logs t     ON t.schedule_id = s.schedule_id
GROUP BY d.driver_id, d.full_name;

-- 3.4 ป้ายรถเมล์ที่อยู่ใกล้สถานี BTS (ข้ามระบบ: ใช้พิกัดจาก locations กลาง)
--     ระยะทางคำนวณด้วยสูตร Haversine (หน่วยเมตร)
CREATE OR REPLACE VIEW v_bus_stops_near_bts
WITH (security_invoker = true) AS
SELECT
    st.station_name                                          AS bts_station,
    st.station_code,
    bs.stop_name                                             AS bus_stop,
    (SELECT string_agg(br.route_no, ', ' ORDER BY br.route_no)
       FROM route_stops rs JOIN bus_routes br USING (route_id)
      WHERE rs.stop_id = bs.stop_id)                         AS bus_routes,
    ROUND((6371000 * 2 * asin(sqrt(
        power(sin(radians(lb.latitude - ls.latitude) / 2), 2) +
        cos(radians(ls.latitude)) * cos(radians(lb.latitude)) *
        power(sin(radians(lb.longitude - ls.longitude) / 2), 2)
    )))::numeric, 0)                                         AS distance_m
FROM stations st
JOIN locations ls ON ls.location_id = st.location_id
CROSS JOIN bus_stops bs
JOIN locations lb ON lb.location_id = bs.location_id
WHERE abs(lb.latitude - ls.latitude) < 0.01 AND abs(lb.longitude - ls.longitude) < 0.01   -- กรองคร่าวๆ ก่อนคำนวณ
  AND 6371000 * 2 * asin(sqrt(
        power(sin(radians(lb.latitude - ls.latitude) / 2), 2) +
        cos(radians(ls.latitude)) * cos(radians(lb.latitude)) *
        power(sin(radians(lb.longitude - ls.longitude) / 2), 2)
      )) <= 500;


-- #####################################################################
-- ส่วนที่ 4: RLS
-- #####################################################################
ALTER TABLE bus_routes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE bus_stops     ENABLE ROW LEVEL SECURITY;
ALTER TABLE route_stops   ENABLE ROW LEVEL SECURITY;
ALTER TABLE buses         ENABLE ROW LEVEL SECURITY;
ALTER TABLE drivers       ENABLE ROW LEVEL SECURITY;
ALTER TABLE bus_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_logs     ENABLE ROW LEVEL SECURITY;
ALTER TABLE bus_rides     ENABLE ROW LEVEL SECURITY;

-- ข้อมูลการเดินรถ: ทุกคนที่ login อ่านได้, admin แก้ไขได้
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['bus_routes', 'bus_stops', 'route_stops', 'buses', 'drivers', 'bus_schedules', 'trip_logs'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_admin', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)', t || '_read', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                        USING (public.app_role() = ''admin'') WITH CHECK (public.app_role() = ''admin'')', t || '_admin', t);
    END LOOP;
END $$;

-- การขึ้นรถ: เจ้าของเห็นของตัวเอง, staff/admin เห็นทั้งหมด
DROP POLICY IF EXISTS bus_rides_read  ON bus_rides;
DROP POLICY IF EXISTS bus_rides_admin ON bus_rides;
CREATE POLICY bus_rides_read ON bus_rides FOR SELECT TO authenticated
    USING (user_id = public.app_user_id() OR public.app_role() IN ('staff', 'admin'));
CREATE POLICY bus_rides_admin ON bus_rides FOR ALL TO authenticated
    USING (public.app_role() = 'admin') WITH CHECK (public.app_role() = 'admin');
