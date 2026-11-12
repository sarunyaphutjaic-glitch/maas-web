-- =====================================================================
-- 34: เส้นทางที่ใกล้ที่สุด + AI Agent จองตั๋ว
-- รันหลัง 09_triggers_trip_planner.sql และ 32_passenger_chat.sql
--
-- ส่วนที่ 1  distance_m()      ระยะทางระหว่าง 2 พิกัด (สูตร Haversine)
-- ส่วนที่ 2  nearest_points()  หาสถานี BTS / ป้ายรถเมล์ / สนามบิน ที่ใกล้จุดที่เลือกที่สุด
-- ส่วนที่ 3  bts_hops()        จำนวนสถานีระหว่าง 2 สถานี (ใช้ลำดับจาก station_sequences)
-- ส่วนที่ 4  plan_trip()       ปรับให้นับเวลา BTS จากจำนวนสถานีจริง
-- ส่วนที่ 5  book_flight()     จองตั๋วเครื่องบิน (ใช้โดย AI Agent)
-- =====================================================================


-- #####################################################################
-- ส่วนที่ 1: ระยะทางบนผิวโลก (Haversine)
--   d = 2R · asin( √( sin²(Δφ/2) + cos φ1 · cos φ2 · sin²(Δλ/2) ) )
--   R = 6,371,000 เมตร, φ = ละติจูด, λ = ลองจิจูด (เรเดียน)
-- #####################################################################
CREATE OR REPLACE FUNCTION public.distance_m(lat1 NUMERIC, lon1 NUMERIC, lat2 NUMERIC, lon2 NUMERIC)
RETURNS NUMERIC
LANGUAGE sql IMMUTABLE
AS $$
    SELECT ROUND((6371000 * 2 * asin(sqrt(
        power(sin(radians(lat2 - lat1) / 2), 2) +
        cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
    )))::numeric, 0);
$$;


-- #####################################################################
-- ส่วนที่ 2: จุดที่ใกล้ที่สุดของแต่ละประเภท (ใช้ตอนคลิกบนแผนที่)
--   ตาราง: locations + stations / bus_stops / airports
-- #####################################################################
CREATE OR REPLACE FUNCTION public.nearest_points(p_lat NUMERIC, p_lon NUMERIC, p_per_type INT DEFAULT 2)
RETURNS TABLE (kind TEXT, name TEXT, code TEXT, distance_m NUMERIC, latitude NUMERIC, longitude NUMERIC, extra TEXT)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
    WITH pts AS (
        SELECT 'RAIL_STATION' AS kind, s.station_name AS name, s.station_code AS code, l.latitude, l.longitude,
               (SELECT string_agg(ln.line_name, ', ') FROM station_sequences ss JOIN lines ln USING (line_id)
                 WHERE ss.station_id = s.station_id) AS extra
        FROM stations s JOIN locations l USING (location_id)
        UNION ALL
        SELECT 'BUS_STOP', b.stop_name, b.stop_code, l.latitude, l.longitude,
               'สาย ' || (SELECT string_agg(r.route_no, ', ' ORDER BY r.route_no::int) FROM route_stops rs JOIN bus_routes r USING (route_id)
                           WHERE rs.stop_id = b.stop_id)
        FROM bus_stops b JOIN locations l USING (location_id)
        UNION ALL
        SELECT 'AIRPORT', a.airport_name, a.iata_code, l.latitude, l.longitude, a.city
        FROM airports a JOIN locations l USING (location_id)
    ),
    ranked AS (
        SELECT pts.*, public.distance_m(p_lat, p_lon, latitude, longitude) AS dist,
               row_number() OVER (PARTITION BY kind
                                  ORDER BY public.distance_m(p_lat, p_lon, latitude, longitude)) AS rn
        FROM pts
    )
    SELECT kind, name, code, dist, latitude, longitude, extra
    FROM ranked WHERE rn <= p_per_type
    ORDER BY dist;
$$;


-- #####################################################################
-- ส่วนที่ 3: จำนวนสถานีระหว่าง 2 สถานี
--   สายเดียวกัน:  hops = | ลำดับ A − ลำดับ B |
--   ต่างสาย:      hops = | ลำดับ A − ลำดับสยามในสาย A | + | ลำดับ B − ลำดับสยามในสาย B |  (เปลี่ยนสายที่สยาม)
--   ถ้าสถานีอยู่หลายสาย เลือกค่าที่น้อยที่สุด (MIN)
-- #####################################################################
CREATE OR REPLACE FUNCTION public.bts_hops(p_a BIGINT, p_b BIGINT)
RETURNS INT
LANGUAGE sql STABLE SET search_path = public
AS $$
    WITH cen AS (
        SELECT ss.line_id, ss.sequence_no FROM station_sequences ss JOIN stations s USING (station_id)
        WHERE s.station_code = 'CEN'
    )
    SELECT COALESCE(MIN(CASE WHEN a.line_id = b.line_id
                             THEN abs(a.sequence_no - b.sequence_no)
                             ELSE abs(a.sequence_no - ca.sequence_no) + abs(b.sequence_no - cb.sequence_no) END), 0)
    FROM station_sequences a
    JOIN station_sequences b ON b.station_id = p_b
    JOIN cen ca ON ca.line_id = a.line_id
    JOIN cen cb ON cb.line_id = b.line_id
    WHERE a.station_id = p_a;
$$;


-- #####################################################################
-- ส่วนที่ 4: plan_trip (ฉบับปรับปรุง)
--   เวลา BTS  = จำนวนสถานี × 2.5 นาที + 4 นาที (รอรถ/เดินในสถานี)
--   ค่า BTS   = fare_tables.base_fare × (1 − card_types.discount_rate)
--   เวลารถเมล์ = จำนวนป้าย × 4 นาที + รอรถ 10 นาที
--   เลือกป้ายขึ้นรถเมล์ที่ทำให้ (เวลา BTS + เวลารถเมล์) น้อยที่สุด
-- #####################################################################
CREATE OR REPLACE FUNCTION public.plan_trip(
    p_flight_id  BIGINT,
    p_dest_type  TEXT,
    p_dest_id    BIGINT,
    p_card_type  TEXT DEFAULT 'Adult'
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    f          RECORD;
    tr         RECORD;
    v_disc     NUMERIC;
    v_legs     JSONB := '[]'::jsonb;
    v_clock    TIMESTAMPTZ;
    v_total    NUMERIC := 0;
    v_from_st  BIGINT;       -- สถานี BTS ที่อยู่ตอนนี้
    v_to_st    BIGINT;       -- สถานี BTS ที่จะลง
    v_base     NUMERIC;
    v_fare     NUMERIC;
    v_min      INT;
    v_hops     INT;
    bus        RECORD;
BEGIN
    -- 1) เที่ยวบิน
    SELECT fl.flight_no, fl.departure_time, fl.arrival_time, fl.base_price, fl.status,
           ao.airport_name AS org_name, ad.airport_name AS dst_name, ad.airport_id AS dst_id
    INTO f
    FROM flights fl
    JOIN airports ao ON ao.airport_id = fl.origin_airport_id
    JOIN airports ad ON ad.airport_id = fl.destination_airport_id
    WHERE fl.flight_id = p_flight_id;
    IF f.flight_no IS NULL THEN RAISE EXCEPTION 'ไม่พบเที่ยวบิน'; END IF;
    IF f.status = 'CANCELLED' THEN RAISE EXCEPTION 'เที่ยวบิน % ถูกยกเลิก', f.flight_no; END IF;

    v_legs := v_legs || jsonb_build_object('mode', 'FLIGHT', 'title', 'เที่ยวบิน ' || f.flight_no,
        'from', f.org_name, 'to', f.dst_name, 'depart', f.departure_time, 'arrive', f.arrival_time,
        'minutes', (EXTRACT(EPOCH FROM (f.arrival_time - f.departure_time)) / 60)::int, 'fare', f.base_price,
        'note', 'ราคาชั้นประหยัด');
    v_total := f.base_price;

    -- 2) ต่อรถจากสนามบินเข้าเมือง
    SELECT t.*, s.station_name INTO tr
    FROM airport_transfers t JOIN stations s USING (station_id)
    WHERE t.airport_id = f.dst_id;
    IF tr.transfer_id IS NULL THEN
        RAISE EXCEPTION 'เที่ยวบิน % ลงที่ % ซึ่งไม่ใช่สนามบินในกรุงเทพ จึงต่อรถไฟฟ้าหรือรถเมล์ไม่ได้', f.flight_no, f.dst_name;
    END IF;
    v_clock := f.arrival_time + INTERVAL '30 minutes';                     -- ลงเครื่องและรับกระเป๋า
    v_legs := v_legs || jsonb_build_object('mode', 'TRANSFER', 'title', tr.mode_name,
        'from', f.dst_name, 'to', 'สถานี BTS ' || tr.station_name, 'depart', v_clock,
        'arrive', v_clock + make_interval(mins => tr.duration_min), 'minutes', tr.duration_min, 'fare', tr.fare,
        'note', 'เผื่อเวลาลงเครื่องและรับกระเป๋า 30 นาที');
    v_clock := v_clock + make_interval(mins => tr.duration_min);
    v_total := v_total + tr.fare;
    v_from_st := tr.station_id;

    SELECT discount_rate INTO v_disc FROM card_types WHERE type_name = p_card_type;
    v_disc := COALESCE(v_disc, 0);

    -- 3) เลือกสถานี BTS ที่จะลง และรถเมล์ (ถ้าปลายทางเป็นป้ายรถเมล์)
    IF p_dest_type = 'STATION' THEN
        v_to_st := p_dest_id;
    ELSIF p_dest_type = 'BUS_STOP' THEN
        -- หาป้ายในสายเดียวกับปลายทางที่อยู่ข้างสถานี BTS แล้วเลือกทางที่ใช้เวลารวมน้อยที่สุด
        SELECT br.route_no, br.route_name, br.fare, st.station_id, st.station_name,
               bs_on.stop_name AS board_stop, bs_dest.stop_name AS dest_stop,
               abs(rs_dest.sequence_no - rs_on.sequence_no) AS stops
        INTO bus
        FROM route_stops rs_dest
        JOIN route_stops rs_on ON rs_on.route_id = rs_dest.route_id AND rs_on.stop_id <> rs_dest.stop_id
        JOIN bus_stops bs_on   ON bs_on.stop_id = rs_on.stop_id
        JOIN stations st       ON bs_on.stop_code = 'B-' || st.station_code
        JOIN bus_stops bs_dest ON bs_dest.stop_id = rs_dest.stop_id
        JOIN bus_routes br     ON br.route_id = rs_dest.route_id
        WHERE rs_dest.stop_id = p_dest_id
        ORDER BY CASE WHEN st.station_id = v_from_st THEN 0
                      ELSE public.bts_hops(v_from_st, st.station_id) * 2.5 + 4 END   -- เวลาบน BTS
               + abs(rs_dest.sequence_no - rs_on.sequence_no) * 4                    -- เวลาบนรถเมล์
        LIMIT 1;
        IF bus.route_no IS NULL THEN RAISE EXCEPTION 'ไม่พบรถเมล์ที่ต่อจาก BTS ไปป้ายนี้ได้'; END IF;
        v_to_st := bus.station_id;
    ELSE
        RAISE EXCEPTION 'ประเภทปลายทางต้องเป็น STATION หรือ BUS_STOP';
    END IF;

    -- 4) ช่วง BTS (ถ้าสถานีลงไม่ใช่สถานีที่อยู่แล้ว)
    IF v_to_st <> v_from_st THEN
        SELECT base_fare INTO v_base FROM fare_tables
        WHERE origin_station_id = v_from_st AND destination_station_id = v_to_st;
        v_fare := ROUND(v_base * (1 - v_disc), 0);
        v_hops := public.bts_hops(v_from_st, v_to_st);
        v_min  := (v_hops * 2.5 + 4)::int;                          -- สูตรเวลา BTS
        v_legs := v_legs || jsonb_build_object('mode', 'BTS', 'title', 'รถไฟฟ้า BTS',
            'from', (SELECT station_name FROM stations WHERE station_id = v_from_st),
            'to',   (SELECT station_name FROM stations WHERE station_id = v_to_st),
            'depart', v_clock, 'arrive', v_clock + make_interval(mins => v_min), 'minutes', v_min, 'fare', v_fare,
            'note', format('%s สถานี · ราคาฐาน %s บาท', v_hops, v_base::int)
                    || CASE WHEN v_disc > 0 THEN format(' · บัตร %s ลด %s%%', p_card_type, (v_disc * 100)::int) ELSE '' END);
        v_clock := v_clock + make_interval(mins => v_min);
        v_total := v_total + v_fare;
    END IF;

    -- 5) ช่วงรถเมล์
    IF p_dest_type = 'BUS_STOP' THEN
        v_min := bus.stops * 4;
        v_legs := v_legs || jsonb_build_object('mode', 'BUS', 'title', 'รถเมล์สาย ' || bus.route_no,
            'from', bus.board_stop, 'to', bus.dest_stop,
            'depart', v_clock + INTERVAL '10 minutes', 'arrive', v_clock + make_interval(mins => 10 + v_min),
            'minutes', 10 + v_min, 'fare', bus.fare,
            'note', format('%s · %s ป้าย · เผื่อรอรถ 10 นาที', bus.route_name, bus.stops));
        v_clock := v_clock + make_interval(mins => 10 + v_min);
        v_total := v_total + bus.fare;
    END IF;

    RETURN json_build_object(
        'legs', v_legs,
        'total_fare', v_total,
        'start', f.departure_time,
        'arrive', v_clock,
        'total_minutes', round(EXTRACT(EPOCH FROM (v_clock - f.departure_time)) / 60)
    );
END;
$$;



-- #####################################################################
-- ส่วนที่ 5: จองตั๋วเครื่องบิน (เรียกโดย AI Agent ผ่าน Edge Function)
--   ทำใน Transaction เดียว: payments → bookings → tickets
--   SECURITY DEFINER + ใช้ app_user_id() → จองได้เฉพาะในชื่อของผู้ที่ login
-- #####################################################################
CREATE OR REPLACE FUNCTION public.book_flight(
    p_flight_id  BIGINT,
    p_passengers TEXT[],
    p_class      TEXT DEFAULT 'ECONOMY',
    p_method     TEXT DEFAULT 'CREDIT_CARD'
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user   users%ROWTYPE;
    f        RECORD;
    v_n      INT := COALESCE(array_length(p_passengers, 1), 0);
    v_price  NUMERIC;
    v_total  NUMERIC;
    v_pay    BIGINT;
    v_book   BIGINT;
    v_ref    TEXT;
    v_sold   INT;
    v_seat   TEXT;
    v_seats  TEXT[] := '{}';
    i        INT;
BEGIN
    SELECT * INTO v_user FROM users WHERE user_id = public.app_user_id();
    IF v_user.user_id IS NULL THEN RAISE EXCEPTION 'กรุณาเข้าสู่ระบบก่อนจอง'; END IF;
    IF v_n < 1 OR v_n > 4 THEN RAISE EXCEPTION 'จองได้ครั้งละ 1–4 คน'; END IF;
    IF p_class NOT IN ('ECONOMY', 'BUSINESS') THEN RAISE EXCEPTION 'ชั้นโดยสารต้องเป็น ECONOMY หรือ BUSINESS'; END IF;
    IF p_method NOT IN ('CREDIT_CARD', 'QR', 'MOBILE_BANKING') THEN RAISE EXCEPTION 'ช่องทางชำระไม่ถูกต้อง'; END IF;

    SELECT fl.flight_id, fl.flight_no, fl.departure_time, fl.arrival_time, fl.base_price, fl.status,
           ao.iata_code AS org, ao.city AS org_city, ad.iata_code AS dst, ad.city AS dst_city, ac.total_seats
    INTO f
    FROM flights fl
    JOIN airports ao  ON ao.airport_id = fl.origin_airport_id
    JOIN airports ad  ON ad.airport_id = fl.destination_airport_id
    JOIN aircrafts ac ON ac.aircraft_id = fl.aircraft_id
    WHERE fl.flight_id = p_flight_id
    FOR UPDATE OF fl;                                   -- ล็อกเที่ยวบินกันจองที่นั่งชนกัน
    IF f.flight_id IS NULL THEN RAISE EXCEPTION 'ไม่พบเที่ยวบิน'; END IF;
    IF f.status <> 'SCHEDULED' OR f.departure_time <= now() THEN
        RAISE EXCEPTION 'เที่ยวบิน % จองไม่ได้แล้ว (ออกไปแล้วหรือถูกยกเลิก)', f.flight_no;
    END IF;

    SELECT COUNT(*) INTO v_sold FROM tickets WHERE flight_id = p_flight_id;
    IF v_sold + v_n > f.total_seats THEN RAISE EXCEPTION 'ที่นั่งไม่พอ'; END IF;

    v_price := f.base_price * CASE WHEN p_class = 'BUSINESS' THEN 2.5 ELSE 1 END;
    v_total := v_price * v_n;
    v_ref   := 'MA' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));

    INSERT INTO payments (user_id, service_type, amount, method, status, paid_at)
    VALUES (v_user.user_id, 'FLIGHT', v_total, p_method, 'PAID', now())
    RETURNING payment_id INTO v_pay;

    INSERT INTO bookings (booking_ref, user_id, payment_id, booked_at, status)
    VALUES (v_ref, v_user.user_id, v_pay, now(), 'CONFIRMED')
    RETURNING booking_id INTO v_book;

    FOR i IN 1..v_n LOOP
        SELECT COUNT(*) INTO v_sold FROM tickets WHERE flight_id = p_flight_id;
        v_seat := CASE WHEN p_class = 'BUSINESS' THEN (1 + v_sold / 4)::text || chr(65 + v_sold % 4)
                       ELSE (10 + v_sold / 6)::text || chr(65 + v_sold % 6) END;
        INSERT INTO tickets (booking_id, flight_id, passenger_name, seat_no, travel_class, price)
        VALUES (v_book, p_flight_id, trim(p_passengers[i]), v_seat, p_class, v_price);
        v_seats := v_seats || v_seat;
    END LOOP;

    RETURN json_build_object(
        'booking_ref', v_ref, 'flight_id', f.flight_id, 'flight_no', f.flight_no,
        'origin', f.org, 'origin_city', f.org_city, 'destination', f.dst, 'destination_city', f.dst_city,
        'departure_time', f.departure_time, 'arrival_time', f.arrival_time,
        'passengers', p_passengers, 'seats', v_seats, 'travel_class', p_class,
        'price_each', v_price, 'total', v_total, 'payment_method', p_method,
        'email', v_user.email, 'name', v_user.full_name
    );
END;
$$;

-- เพิ่ม flight_id ต่อท้าย View ตารางเที่ยวบิน (Agent ใช้อ้างอิงตอนจอง)
CREATE OR REPLACE VIEW v_flight_schedule
WITH (security_invoker = true) AS
SELECT
    f.flight_no,
    ao.iata_code                                           AS origin_code,
    ao.city                                                AS origin_city,
    ad.iata_code                                           AS destination_code,
    ad.city                                                AS destination_city,
    f.departure_time,
    f.arrival_time,
    (f.departure_time AT TIME ZONE 'Asia/Bangkok')::date   AS flight_date,
    f.base_price,
    f.status                                               AS flight_status,
    f.flight_id
FROM flights f
JOIN airports ao ON ao.airport_id = f.origin_airport_id
JOIN airports ad ON ad.airport_id = f.destination_airport_id;

REVOKE EXECUTE ON FUNCTION public.nearest_points(NUMERIC, NUMERIC, INT), public.book_flight(BIGINT, TEXT[], TEXT, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.nearest_points(NUMERIC, NUMERIC, INT), public.book_flight(BIGINT, TEXT[], TEXT, TEXT),
                           public.distance_m(NUMERIC, NUMERIC, NUMERIC, NUMERIC), public.bts_hops(BIGINT, BIGINT) TO authenticated;
