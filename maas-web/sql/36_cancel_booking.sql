-- =====================================================================
-- 36: ยกเลิกการจองตั๋วเครื่องบิน
-- รันหลัง 34_nearest_agent.sql
--
-- นโยบาย
--   ผู้โดยสาร: ยกเลิกได้เฉพาะการจองของตัวเอง และก่อนเครื่องออกอย่างน้อย 24 ชั่วโมง (คืนเงินเต็ม)
--   ผู้ดูแล:   ยกเลิกได้ทุกการจอง ก่อนเครื่องออก (กรณีพิเศษ เช่น เที่ยวบินมีปัญหา)
-- ผลการยกเลิก (Transaction เดียว)
--   bookings.status → CANCELLED + บันทึกเวลา ผู้ยกเลิก เหตุผล
--   payments.status → REFUNDED
--   tickets เก็บไว้เป็นประวัติ แต่ไม่นับเป็นที่นั่งที่ขายแล้ว
-- =====================================================================

-- 1) คอลัมน์บันทึกการยกเลิก
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cancelled_at  TIMESTAMPTZ;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cancelled_by  BIGINT;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cancel_reason VARCHAR(200);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_bookings_cancelled_by') THEN
        ALTER TABLE bookings ADD CONSTRAINT fk_bookings_cancelled_by
            FOREIGN KEY (cancelled_by) REFERENCES users(user_id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_booking_cancel_info') THEN
        -- ถ้ายกเลิกต้องมีเวลายกเลิก
        ALTER TABLE bookings ADD CONSTRAINT chk_booking_cancel_info
            CHECK (status <> 'CANCELLED' OR cancelled_at IS NOT NULL) NOT VALID;
    END IF;
END $$;

-- การจองที่ยกเลิกในข้อมูลจำลองเดิม: ใส่เวลายกเลิกเป็นเวลาจอง
UPDATE bookings SET cancelled_at = booked_at WHERE status = 'CANCELLED' AND cancelled_at IS NULL;

COMMENT ON COLUMN bookings.cancelled_at  IS 'TIMESTAMPTZ · เวลาที่ยกเลิก (เวลาไทย +07)';
COMMENT ON COLUMN bookings.cancelled_by  IS 'ผู้ที่กดยกเลิก (ผู้โดยสารเอง หรือผู้ดูแล)';
COMMENT ON COLUMN bookings.cancel_reason IS 'เหตุผลการยกเลิก';


-- 2) ฟังก์ชันยกเลิก
CREATE OR REPLACE FUNCTION public.cancel_booking(p_booking_ref TEXT, p_reason TEXT DEFAULT NULL)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me     users%ROWTYPE;
    b        RECORD;
    v_admin  BOOLEAN;
    v_hours  NUMERIC;
BEGIN
    SELECT * INTO v_me FROM users WHERE user_id = public.app_user_id();
    IF v_me.user_id IS NULL THEN RAISE EXCEPTION 'กรุณาเข้าสู่ระบบ'; END IF;
    v_admin := v_me.role = 'admin';

    SELECT bk.booking_id, bk.booking_ref, bk.user_id, bk.status, bk.payment_id,
           f.flight_no, f.departure_time, f.arrival_time,
           ao.iata_code AS origin, ao.city AS origin_city, ad.iata_code AS destination, ad.city AS destination_city,
           u.email, u.full_name,
           (SELECT SUM(price) FROM tickets t WHERE t.booking_id = bk.booking_id) AS total,
           (SELECT array_agg(passenger_name || ' (' || seat_no || ')' ORDER BY ticket_id) FROM tickets t WHERE t.booking_id = bk.booking_id) AS passengers
    INTO b
    FROM bookings bk
    JOIN users u ON u.user_id = bk.user_id
    JOIN LATERAL (SELECT flight_id FROM tickets t WHERE t.booking_id = bk.booking_id LIMIT 1) tk ON true
    JOIN flights f   ON f.flight_id = tk.flight_id
    JOIN airports ao ON ao.airport_id = f.origin_airport_id
    JOIN airports ad ON ad.airport_id = f.destination_airport_id
    WHERE bk.booking_ref = upper(trim(p_booking_ref))
    FOR UPDATE OF bk;

    IF b.booking_id IS NULL THEN RAISE EXCEPTION 'ไม่พบการจอง %', p_booking_ref; END IF;
    IF NOT v_admin AND b.user_id <> v_me.user_id THEN RAISE EXCEPTION 'ยกเลิกได้เฉพาะการจองของตัวเอง'; END IF;
    IF b.status = 'CANCELLED' THEN RAISE EXCEPTION 'การจอง % ถูกยกเลิกไปแล้ว', b.booking_ref; END IF;

    v_hours := EXTRACT(EPOCH FROM (b.departure_time - now())) / 3600;
    IF v_hours <= 0 THEN RAISE EXCEPTION 'เที่ยวบินออกเดินทางไปแล้ว ยกเลิกไม่ได้'; END IF;
    IF NOT v_admin AND v_hours < 24 THEN
        RAISE EXCEPTION 'ยกเลิกเองได้ก่อนเครื่องออกอย่างน้อย 24 ชั่วโมง (เหลือ % ชั่วโมง) กรุณาติดต่อผู้ดูแลระบบ', ROUND(v_hours, 1);
    END IF;

    UPDATE bookings
    SET status = 'CANCELLED', cancelled_at = now(), cancelled_by = v_me.user_id,
        cancel_reason = COALESCE(NULLIF(trim(p_reason), ''), CASE WHEN v_admin AND b.user_id <> v_me.user_id
                                                               THEN 'ยกเลิกโดยผู้ดูแลระบบ' ELSE 'ผู้โดยสารยกเลิกเอง' END)
    WHERE booking_id = b.booking_id;

    UPDATE payments SET status = 'REFUNDED' WHERE payment_id = b.payment_id;

    RETURN json_build_object(
        'booking_ref', b.booking_ref, 'flight_no', b.flight_no,
        'origin', b.origin, 'origin_city', b.origin_city, 'destination', b.destination, 'destination_city', b.destination_city,
        'departure_time', b.departure_time, 'passengers', b.passengers, 'refund', b.total,
        'cancelled_by_admin', v_admin AND b.user_id <> v_me.user_id,
        'reason', COALESCE(NULLIF(trim(p_reason), ''), '-'),
        'email', b.email, 'name', b.full_name
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.cancel_booking(TEXT, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.cancel_booking(TEXT, TEXT) TO authenticated;


-- 3) จองใหม่: นับที่นั่งว่างโดยไม่รวมการจองที่ยกเลิก
--    (เลขที่นั่งยังรันต่อจากตั๋วทั้งหมด เพื่อไม่ชน UNIQUE (flight_id, seat_no) กับตั๋วที่ยกเลิก)
CREATE OR REPLACE FUNCTION public.seats_taken(p_flight_id BIGINT)
RETURNS INT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT COUNT(*)::int FROM tickets t JOIN bookings b USING (booking_id)
    WHERE t.flight_id = p_flight_id AND b.status <> 'CANCELLED';
$$;

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

    IF public.seats_taken(p_flight_id) + v_n > f.total_seats THEN RAISE EXCEPTION 'ที่นั่งไม่พอ'; END IF;

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

