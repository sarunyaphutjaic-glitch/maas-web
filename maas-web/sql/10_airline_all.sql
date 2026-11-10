-- =====================================================================
-- Module 1: ระบบจองตั๋วสายการบิน (Airline Ticketing & Reservation)
-- สมาชิกคนที่ 1
--
-- ตาราง (5): airports, aircrafts, flights, bookings, tickets
-- เชื่อมกับตารางกลาง:
--   airports.location_id → locations   (ตำแหน่งสนามบินบนแผนที่ร่วมกับสถานี BTS / ป้ายรถเมล์)
--   bookings.user_id     → users       (ผู้จองคือผู้ใช้คนเดียวกับที่ใช้ BTS / รถเมล์)
--   bookings.payment_id  → payments    (การชำระเงินรวมศูนย์ service_type = 'FLIGHT')
--
-- ต้องรันหลัง 00_central_schema.sql และ 04_seed_central_bts.sql (ใช้ผู้ใช้ชุดเดียวกัน)
-- ไฟล์นี้มี 4 ส่วน: (1) สร้างตาราง (2) ข้อมูลจำลอง (3) Views (4) RLS
-- =====================================================================


-- #####################################################################
-- ส่วนที่ 1: สร้างตาราง
-- #####################################################################

-- 1.1 สนามบิน (1 สนามบิน = 1 location ในตารางกลาง)
CREATE TABLE IF NOT EXISTS airports (
    airport_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    iata_code     CHAR(3)      NOT NULL UNIQUE,          -- รหัสสากล 3 ตัว เช่น BKK
    airport_name  VARCHAR(100) NOT NULL,
    city          VARCHAR(100) NOT NULL,
    location_id   BIGINT       NOT NULL UNIQUE,
    CONSTRAINT fk_airports_location
        FOREIGN KEY (location_id) REFERENCES locations(location_id) ON DELETE RESTRICT,
    CONSTRAINT chk_iata_code CHECK (iata_code ~ '^[A-Z]{3}$')
);

-- 1.2 เครื่องบิน
CREATE TABLE IF NOT EXISTS aircrafts (
    aircraft_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration_no  VARCHAR(10) NOT NULL UNIQUE,         -- ทะเบียน เช่น HS-ABA
    model            VARCHAR(50) NOT NULL,
    total_seats      INT         NOT NULL,
    CONSTRAINT chk_total_seats CHECK (total_seats > 0)
);

-- 1.3 เที่ยวบิน
CREATE TABLE IF NOT EXISTS flights (
    flight_id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    flight_no               VARCHAR(10)    NOT NULL,      -- เช่น MA101 (บินทุกวันด้วยเลขเดิม)
    origin_airport_id       BIGINT         NOT NULL,
    destination_airport_id  BIGINT         NOT NULL,
    aircraft_id             BIGINT         NOT NULL,
    departure_time          TIMESTAMPTZ    NOT NULL,
    arrival_time            TIMESTAMPTZ    NOT NULL,
    base_price              NUMERIC(10, 2) NOT NULL,      -- ราคาชั้นประหยัด
    status                  VARCHAR(20)    NOT NULL DEFAULT 'SCHEDULED',
    CONSTRAINT fk_flights_origin
        FOREIGN KEY (origin_airport_id) REFERENCES airports(airport_id) ON DELETE RESTRICT,
    CONSTRAINT fk_flights_destination
        FOREIGN KEY (destination_airport_id) REFERENCES airports(airport_id) ON DELETE RESTRICT,
    CONSTRAINT fk_flights_aircraft
        FOREIGN KEY (aircraft_id) REFERENCES aircrafts(aircraft_id) ON DELETE RESTRICT,
    CONSTRAINT chk_flight_route   CHECK (origin_airport_id <> destination_airport_id),
    CONSTRAINT chk_flight_time    CHECK (arrival_time > departure_time),
    CONSTRAINT chk_base_price     CHECK (base_price > 0),
    CONSTRAINT chk_flight_status  CHECK (status IN ('SCHEDULED', 'DEPARTED', 'ARRIVED', 'CANCELLED')),
    CONSTRAINT uq_flight_no_time  UNIQUE (flight_no, departure_time)   -- เลขเที่ยวบินเดียวกันห้ามซ้ำเวลา
);

-- 1.4 การจอง (1 การจองมีได้หลายตั๋ว เช่น จองให้ครอบครัว)
CREATE TABLE IF NOT EXISTS bookings (
    booking_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_ref  VARCHAR(8)  NOT NULL UNIQUE,              -- รหัสการจอง เช่น MA3F9A21
    user_id      BIGINT      NOT NULL,
    payment_id   BIGINT      UNIQUE,                       -- 1 การจอง = 1 การชำระเงิน
    booked_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    status       VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    CONSTRAINT fk_bookings_user
        FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE RESTRICT,
    CONSTRAINT fk_bookings_payment
        FOREIGN KEY (payment_id) REFERENCES payments(payment_id) ON DELETE RESTRICT,
    CONSTRAINT chk_booking_status CHECK (status IN ('PENDING', 'CONFIRMED', 'CANCELLED'))
);

-- 1.5 ตั๋ว (1 ตั๋ว = 1 ที่นั่ง บน 1 เที่ยวบิน)
CREATE TABLE IF NOT EXISTS tickets (
    ticket_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id      BIGINT         NOT NULL,
    flight_id       BIGINT         NOT NULL,
    passenger_name  VARCHAR(100)   NOT NULL,              -- ชื่อคนเดินทาง (อาจไม่ใช่คนจอง)
    seat_no         VARCHAR(4)     NOT NULL,              -- เช่น 12A
    travel_class    VARCHAR(10)    NOT NULL DEFAULT 'ECONOMY',
    price           NUMERIC(10, 2) NOT NULL,
    CONSTRAINT fk_tickets_booking
        FOREIGN KEY (booking_id) REFERENCES bookings(booking_id) ON DELETE CASCADE,
    CONSTRAINT fk_tickets_flight
        FOREIGN KEY (flight_id) REFERENCES flights(flight_id) ON DELETE RESTRICT,
    CONSTRAINT chk_travel_class CHECK (travel_class IN ('ECONOMY', 'BUSINESS')),
    CONSTRAINT chk_ticket_price CHECK (price >= 0),
    CONSTRAINT uq_flight_seat   UNIQUE (flight_id, seat_no)       -- ห้ามขายที่นั่งซ้ำ
);

CREATE INDEX IF NOT EXISTS idx_flights_origin      ON flights(origin_airport_id);
CREATE INDEX IF NOT EXISTS idx_flights_destination ON flights(destination_airport_id);
CREATE INDEX IF NOT EXISTS idx_flights_aircraft    ON flights(aircraft_id);
CREATE INDEX IF NOT EXISTS idx_flights_departure   ON flights(departure_time);
CREATE INDEX IF NOT EXISTS idx_bookings_user       ON bookings(user_id);
CREATE INDEX IF NOT EXISTS idx_tickets_booking     ON tickets(booking_id);


-- #####################################################################
-- ส่วนที่ 2: ข้อมูลจำลอง
-- airports 8, aircrafts 6, flights 48, bookings 60, tickets ~85
-- #####################################################################
SELECT setseed(0.101);

-- 2.1 สนามบิน + location กลาง
WITH a(code, name, city, lat, lon) AS (
    VALUES
    ('BKK', 'ท่าอากาศยานสุวรรณภูมิ',      'สมุทรปราการ', 13.690000, 100.750100),
    ('DMK', 'ท่าอากาศยานดอนเมือง',        'กรุงเทพมหานคร', 13.912600, 100.606700),
    ('CNX', 'ท่าอากาศยานเชียงใหม่',        'เชียงใหม่',     18.766800,  98.962600),
    ('HKT', 'ท่าอากาศยานภูเก็ต',           'ภูเก็ต',        8.113200,  98.316900),
    ('HDY', 'ท่าอากาศยานหาดใหญ่',          'สงขลา',         6.933200, 100.392700),
    ('KBV', 'ท่าอากาศยานกระบี่',           'กระบี่',         8.099100,  98.986200),
    ('USM', 'ท่าอากาศยานสมุย',             'สุราษฎร์ธานี',   9.547800, 100.062300),
    ('UTH', 'ท่าอากาศยานอุดรธานี',         'อุดรธานี',      17.386400, 102.788300)
),
ins AS (
    INSERT INTO locations (location_name, location_type, latitude, longitude, district)
    SELECT name, 'AIRPORT', lat, lon, city FROM a
    RETURNING location_id, location_name
)
INSERT INTO airports (iata_code, airport_name, city, location_id)
SELECT a.code, a.name, a.city, ins.location_id
FROM a JOIN ins ON ins.location_name = a.name;

-- 2.2 เครื่องบิน
INSERT INTO aircrafts (registration_no, model, total_seats) VALUES
    ('HS-ABA', 'Airbus A320',     180),
    ('HS-ABB', 'Airbus A320',     180),
    ('HS-ABC', 'Airbus A321',     220),
    ('HS-ABD', 'Boeing 737-800',  189),
    ('HS-ABE', 'ATR 72-600',       70),
    ('HS-ABF', 'Airbus A330-300', 300);

-- 2.3 เที่ยวบิน: 12 เส้นทาง × 4 วัน = 48 เที่ยว (1 ต.ค. – 20 พ.ย. 2569)
--     เที่ยวบินหลัง 10 พ.ย. ยังไม่ออก (SCHEDULED) ใช้แสดงการจองล่วงหน้า
WITH r(rn, flight_no, org, dst, minutes, price, hh, reg) AS (
    VALUES
    ( 1, 'MA101', 'BKK', 'CNX',  70, 1890, 7,  'HS-ABA'),
    ( 2, 'MA102', 'CNX', 'BKK',  70, 1890, 10, 'HS-ABA'),
    ( 3, 'MA201', 'BKK', 'HKT',  85, 2190, 8,  'HS-ABC'),
    ( 4, 'MA202', 'HKT', 'BKK',  85, 2190, 12, 'HS-ABC'),
    ( 5, 'MA301', 'DMK', 'HDY',  90, 1590, 6,  'HS-ABD'),
    ( 6, 'MA302', 'HDY', 'DMK',  90, 1590, 9,  'HS-ABD'),
    ( 7, 'MA401', 'BKK', 'KBV',  80, 1790, 13, 'HS-ABB'),
    ( 8, 'MA402', 'KBV', 'BKK',  80, 1790, 16, 'HS-ABB'),
    ( 9, 'MA501', 'BKK', 'USM',  65, 3290, 11, 'HS-ABF'),
    (10, 'MA502', 'USM', 'BKK',  65, 3290, 14, 'HS-ABF'),
    (11, 'MA601', 'DMK', 'UTH',  65, 1290, 17, 'HS-ABE'),
    (12, 'MA602', 'UTH', 'DMK',  65, 1290, 19, 'HS-ABE')
),
d(k, day) AS (
    VALUES (1, DATE '2026-10-03'), (2, DATE '2026-10-17'), (3, DATE '2026-10-31'), (4, DATE '2026-11-14')
),
f AS (
    SELECT r.*, d.k,
           ((d.day + make_interval(hours => r.hh)) AT TIME ZONE 'Asia/Bangkok')
             + make_interval(days => (r.rn % 3))  AS dep      -- เลื่อนวันตามเส้นทางให้กระจาย
    FROM r CROSS JOIN d
)
INSERT INTO flights (flight_no, origin_airport_id, destination_airport_id, aircraft_id,
                     departure_time, arrival_time, base_price, status)
SELECT f.flight_no, ao.airport_id, ad.airport_id, ac.aircraft_id,
       f.dep, f.dep + make_interval(mins => f.minutes), f.price,
       CASE WHEN f.k = 2 AND f.rn IN (5, 11) THEN 'CANCELLED'          -- ยกเลิก 2 เที่ยว
            WHEN f.dep < TIMESTAMPTZ '2026-11-10 00:00+07' THEN 'ARRIVED'
            ELSE 'SCHEDULED' END
FROM f
JOIN airports ao  ON ao.iata_code = f.org
JOIN airports ad  ON ad.iata_code = f.dst
JOIN aircrafts ac ON ac.registration_no = f.reg
ORDER BY f.dep;

-- 2.4 การจอง + การชำระเงิน + ตั๋ว (วนสร้างทีละการจอง เพื่อให้เลขที่นั่งไม่ซ้ำ)
DO $$
DECLARE
    v_users     BIGINT[];
    v_flights   BIGINT[];
    v_user      BIGINT;
    v_flight    flights%ROWTYPE;
    v_flight_id BIGINT;
    v_name      TEXT;
    v_n         INT;
    v_class     TEXT;
    v_price     NUMERIC;
    v_total     NUMERIC;
    v_status    TEXT;
    v_booked    TIMESTAMPTZ;
    v_payment   BIGINT;
    v_booking   BIGINT;
    v_seat_idx  INT;
    v_prices    NUMERIC[];
    v_classes   TEXT[];
    i INT; j INT;
BEGIN
    SELECT array_agg(user_id ORDER BY user_id) INTO v_users FROM users WHERE email LIKE '%@maas.test';
    SELECT array_agg(flight_id ORDER BY flight_id) INTO v_flights FROM flights WHERE status <> 'CANCELLED';

    FOR i IN 1..60 LOOP
        v_user := v_users[1 + floor(random() * array_length(v_users, 1))::int];
        -- สุ่ม id ใส่ตัวแปรก่อน (ถ้าสุ่มใน WHERE ตรงๆ random() จะถูกเรียกใหม่ทุกแถวที่สแกน)
        v_flight_id := v_flights[1 + floor(random() * array_length(v_flights, 1))::int];
        SELECT * INTO v_flight FROM flights WHERE flight_id = v_flight_id;
        SELECT full_name INTO v_name FROM users WHERE user_id = v_user;

        v_n := CASE WHEN random() < 0.70 THEN 1 WHEN random() < 0.6 THEN 2 ELSE 3 END;   -- จำนวนตั๋ว
        v_status := CASE WHEN random() < 0.88 THEN 'CONFIRMED' WHEN random() < 0.6 THEN 'CANCELLED' ELSE 'PENDING' END;
        v_booked := v_flight.departure_time - make_interval(days => 2 + floor(random() * 25)::int, mins => floor(random() * 600)::int);

        -- คำนวณราคาตั๋วแต่ละใบก่อน เพื่อรู้ยอดชำระรวม
        v_total := 0; v_prices := '{}'; v_classes := '{}';
        FOR j IN 1..v_n LOOP
            v_class := CASE WHEN random() < 0.15 THEN 'BUSINESS' ELSE 'ECONOMY' END;
            v_price := round((v_flight.base_price * CASE WHEN v_class = 'BUSINESS' THEN 2.5 ELSE 1 END
                              * (0.9 + random() * 0.3))::numeric, 0);       -- ราคาขึ้นลงตามวันที่จอง
            v_prices  := v_prices  || v_price;
            v_classes := v_classes || v_class;
            v_total   := v_total + v_price;
        END LOOP;

        INSERT INTO payments (user_id, service_type, amount, method, status, paid_at)
        VALUES (v_user, 'FLIGHT', v_total,
                (ARRAY['CREDIT_CARD', 'QR', 'MOBILE_BANKING'])[1 + floor(random() * 3)::int],
                CASE v_status WHEN 'CONFIRMED' THEN 'PAID' WHEN 'CANCELLED' THEN 'REFUNDED' ELSE 'PENDING' END,
                v_booked)
        RETURNING payment_id INTO v_payment;

        INSERT INTO bookings (booking_ref, user_id, payment_id, booked_at, status)
        VALUES ('MA' || upper(substr(md5(i::text || v_user::text), 1, 6)), v_user, v_payment, v_booked, v_status)
        RETURNING booking_id INTO v_booking;

        FOR j IN 1..v_n LOOP
            SELECT count(*) INTO v_seat_idx FROM tickets WHERE flight_id = v_flight.flight_id;
            INSERT INTO tickets (booking_id, flight_id, passenger_name, seat_no, travel_class, price)
            VALUES (v_booking, v_flight.flight_id,
                    CASE WHEN j = 1 THEN v_name ELSE v_name || ' (ผู้ติดตาม ' || (j - 1) || ')' END,
                    -- ชั้นธุรกิจแถว 1–3, ชั้นประหยัดเริ่มแถว 10 (ที่นั่ง A–F)
                    CASE WHEN v_classes[j] = 'BUSINESS'
                         THEN (1 + v_seat_idx / 4)::text  || chr(65 + v_seat_idx % 4)
                         ELSE (10 + v_seat_idx / 6)::text || chr(65 + v_seat_idx % 6) END,
                    v_classes[j], v_prices[j]);
        END LOOP;
    END LOOP;
END $$;


-- #####################################################################
-- ส่วนที่ 3: Views (security_invoker = true → เคารพ RLS ของผู้ใช้)
-- #####################################################################

-- 3.1 รายละเอียดตั๋วแต่ละใบ (JOIN 7 ตาราง: tickets, bookings, users, flights, airports ×2, payments)
CREATE OR REPLACE VIEW v_flight_bookings
WITH (security_invoker = true) AS
SELECT
    t.ticket_id,
    b.booking_ref,
    b.user_id,
    u.full_name                                              AS booker_name,
    t.passenger_name,
    f.flight_no,
    ao.iata_code                                             AS origin_code,
    ao.city                                                  AS origin_city,
    ad.iata_code                                             AS destination_code,
    ad.city                                                  AS destination_city,
    f.departure_time,
    (f.departure_time AT TIME ZONE 'Asia/Bangkok')::date     AS flight_date,
    t.travel_class,
    t.seat_no,
    t.price,
    b.status                                                 AS booking_status,
    p.method                                                 AS payment_method,
    f.status                                                 AS flight_status
FROM tickets t
JOIN bookings b  ON b.booking_id = t.booking_id
JOIN users u     ON u.user_id = b.user_id
JOIN flights f   ON f.flight_id = t.flight_id
JOIN airports ao ON ao.airport_id = f.origin_airport_id
JOIN airports ad ON ad.airport_id = f.destination_airport_id
LEFT JOIN payments p ON p.payment_id = b.payment_id;

-- 3.2 รายได้ต่อเส้นทาง (นับเฉพาะการจองที่ยืนยันแล้ว)
CREATE OR REPLACE VIEW v_route_revenue
WITH (security_invoker = true) AS
SELECT
    ao.iata_code || '-' || ad.iata_code                      AS route,
    ao.city                                                  AS origin_city,
    ad.city                                                  AS destination_city,
    COUNT(DISTINCT f.flight_id)                              AS flights,
    COUNT(t.ticket_id)                                       AS tickets_sold,
    COALESCE(SUM(t.price), 0)                                AS revenue,
    ROUND(AVG(t.price), 2)                                   AS avg_ticket_price
FROM flights f
JOIN airports ao ON ao.airport_id = f.origin_airport_id
JOIN airports ad ON ad.airport_id = f.destination_airport_id
LEFT JOIN tickets t  ON t.flight_id = f.flight_id
                    AND EXISTS (SELECT 1 FROM bookings b WHERE b.booking_id = t.booking_id AND b.status = 'CONFIRMED')
GROUP BY ao.iata_code, ad.iata_code, ao.city, ad.city;

-- 3.3 อัตราที่นั่งเต็มต่อเที่ยวบิน
CREATE OR REPLACE VIEW v_flight_occupancy
WITH (security_invoker = true) AS
SELECT
    f.flight_id,
    f.flight_no,
    ao.iata_code || '-' || ad.iata_code                      AS route,
    f.departure_time,
    (f.departure_time AT TIME ZONE 'Asia/Bangkok')::date     AS flight_date,
    ac.model                                                 AS aircraft_model,
    ac.total_seats,
    COUNT(t.ticket_id)                                       AS seats_sold,
    ROUND(100.0 * COUNT(t.ticket_id) / ac.total_seats, 2)    AS occupancy_pct,
    f.status                                                 AS flight_status
FROM flights f
JOIN aircrafts ac ON ac.aircraft_id = f.aircraft_id
JOIN airports ao  ON ao.airport_id = f.origin_airport_id
JOIN airports ad  ON ad.airport_id = f.destination_airport_id
LEFT JOIN tickets t ON t.flight_id = f.flight_id
GROUP BY f.flight_id, f.flight_no, ao.iata_code, ad.iata_code, f.departure_time, ac.model, ac.total_seats, f.status;


-- #####################################################################
-- ส่วนที่ 4: RLS (ใช้ฟังก์ชัน app_role / app_user_id จาก 06_auth_rls.sql)
-- #####################################################################
ALTER TABLE airports  ENABLE ROW LEVEL SECURITY;
ALTER TABLE aircrafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE flights   ENABLE ROW LEVEL SECURITY;
ALTER TABLE bookings  ENABLE ROW LEVEL SECURITY;
ALTER TABLE tickets   ENABLE ROW LEVEL SECURITY;

-- ข้อมูลสาธารณะ (สนามบิน เครื่องบิน เที่ยวบิน): ทุกคนที่ login อ่านได้, admin แก้ไขได้
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['airports', 'aircrafts', 'flights'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_admin', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)', t || '_read', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                        USING (public.app_role() = ''admin'') WITH CHECK (public.app_role() = ''admin'')', t || '_admin', t);
    END LOOP;
END $$;

-- การจอง: เจ้าของเห็นของตัวเอง, staff/admin เห็นทั้งหมด, admin แก้ไขได้
DROP POLICY IF EXISTS bookings_read  ON bookings;
DROP POLICY IF EXISTS bookings_admin ON bookings;
CREATE POLICY bookings_read ON bookings FOR SELECT TO authenticated
    USING (user_id = public.app_user_id() OR public.app_role() IN ('staff', 'admin'));
CREATE POLICY bookings_admin ON bookings FOR ALL TO authenticated
    USING (public.app_role() = 'admin') WITH CHECK (public.app_role() = 'admin');

-- ตั๋ว: เห็นได้ถ้าเป็นตั๋วในการจองของตัวเอง
DROP POLICY IF EXISTS tickets_read  ON tickets;
DROP POLICY IF EXISTS tickets_admin ON tickets;
CREATE POLICY tickets_read ON tickets FOR SELECT TO authenticated
    USING (public.app_role() IN ('staff', 'admin')
           OR booking_id IN (SELECT booking_id FROM bookings WHERE user_id = public.app_user_id()));
CREATE POLICY tickets_admin ON tickets FOR ALL TO authenticated
    USING (public.app_role() = 'admin') WITH CHECK (public.app_role() = 'admin');
