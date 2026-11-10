-- =====================================================================
-- 09: Trigger คำนวณค่าโดยสาร + การวางแผนเดินทางข้ามระบบ
-- รันหลัง 31_bus_route_stops_view.sql (ใช้ตารางจากทุกส่วน)
--
-- ส่วนที่ 1  ตาราง airport_transfers (การต่อรถจากสนามบินเข้า BTS)
-- ส่วนที่ 2  Trigger บน gate_logs และ card_topups
-- ส่วนที่ 3  ฟังก์ชัน plan_trip: เครื่องบิน → ต่อรถ → BTS → รถเมล์
-- =====================================================================


-- #####################################################################
-- ส่วนที่ 1: การต่อรถจากสนามบินเข้าเมือง
-- #####################################################################
CREATE TABLE IF NOT EXISTS airport_transfers (
    transfer_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    airport_id    BIGINT       NOT NULL UNIQUE,      -- 1 สนามบิน = 1 ทางต่อหลัก
    station_id    BIGINT       NOT NULL,             -- สถานี BTS ที่ไปถึง
    mode_name     VARCHAR(100) NOT NULL,
    duration_min  INT          NOT NULL,
    fare          NUMERIC(6, 2) NOT NULL,
    CONSTRAINT fk_transfer_airport FOREIGN KEY (airport_id) REFERENCES airports(airport_id) ON DELETE CASCADE,
    CONSTRAINT fk_transfer_station FOREIGN KEY (station_id) REFERENCES stations(station_id) ON DELETE CASCADE,
    CONSTRAINT chk_transfer_duration CHECK (duration_min > 0),
    CONSTRAINT chk_transfer_fare     CHECK (fare >= 0)
);

INSERT INTO airport_transfers (airport_id, station_id, mode_name, duration_min, fare)
SELECT a.airport_id, s.station_id, x.mode_name, x.minutes, x.fare
FROM (VALUES
    ('BKK', 'N2', 'Airport Rail Link (สุวรรณภูมิ → พญาไท)', 26, 45),
    ('DMK', 'N8', 'รถเมล์ A1 (ดอนเมือง → หมอชิต)',          35, 30)
) AS x(iata, station_code, mode_name, minutes, fare)
JOIN airports a ON a.iata_code = x.iata
JOIN stations s ON s.station_code = x.station_code
ON CONFLICT (airport_id) DO NOTHING;

ALTER TABLE airport_transfers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS airport_transfers_read  ON airport_transfers;
DROP POLICY IF EXISTS airport_transfers_admin ON airport_transfers;
CREATE POLICY airport_transfers_read ON airport_transfers FOR SELECT TO authenticated USING (true);
CREATE POLICY airport_transfers_admin ON airport_transfers FOR ALL TO authenticated
    USING (public.app_role() = 'admin') WITH CHECK (public.app_role() = 'admin');


-- #####################################################################
-- ส่วนที่ 2: Trigger
-- SECURITY DEFINER: Trigger ต้องแก้ยอดเงินในบัตรได้ แม้ผู้ที่แตะบัตรจะไม่มีสิทธิ์แก้ตาราง cards
-- (ข้อมูลเดิมจากไฟล์ seed ไม่ถูกคำนวณซ้ำ Trigger ทำงานกับการแตะบัตรครั้งใหม่เท่านั้น)
-- #####################################################################

-- 2.1 แตะบัตรเข้า: บัตรต้องใช้งานได้ และมีเงินอย่างน้อยค่าโดยสารต่ำสุด
CREATE OR REPLACE FUNCTION public.trg_gate_tap_in()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_card     cards%ROWTYPE;
    v_min_fare NUMERIC;
BEGIN
    SELECT * INTO v_card FROM cards WHERE card_id = NEW.card_id;
    IF v_card.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'บัตร % ใช้งานไม่ได้ (สถานะ %)', v_card.card_number, v_card.status;
    END IF;

    SELECT MIN(base_fare) INTO v_min_fare FROM fare_tables;
    IF v_card.balance < v_min_fare THEN
        RAISE EXCEPTION 'ยอดเงินในบัตรไม่พอ (เหลือ % บาท ต้องมีอย่างน้อย % บาท)', v_card.balance, v_min_fare;
    END IF;

    IF EXISTS (SELECT 1 FROM gate_logs WHERE card_id = NEW.card_id AND status = 'IN_JOURNEY') THEN
        RAISE EXCEPTION 'บัตรนี้แตะเข้าไว้แล้วและยังไม่ได้แตะออก';
    END IF;

    NEW.entry_time      := COALESCE(NEW.entry_time, now());
    NEW.exit_station_id := NULL;
    NEW.exit_time       := NULL;
    NEW.fare_charged    := 0;
    NEW.status          := 'IN_JOURNEY';
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS gate_tap_in ON gate_logs;
CREATE TRIGGER gate_tap_in
    BEFORE INSERT ON gate_logs
    FOR EACH ROW EXECUTE FUNCTION public.trg_gate_tap_in();

-- 2.2 แตะบัตรออก: คำนวณค่าโดยสาร (ราคาฐาน × ส่วนลดประเภทบัตร) แล้วหักเงินในบัตร
CREATE OR REPLACE FUNCTION public.trg_gate_tap_out()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_base     NUMERIC;
    v_discount NUMERIC;
    v_balance  NUMERIC;
    v_fare     NUMERIC;
BEGIN
    -- ทำงานเฉพาะตอนใส่สถานีขาออกครั้งแรก
    IF NEW.exit_station_id IS NULL OR OLD.exit_station_id IS NOT NULL THEN
        RETURN NEW;
    END IF;

    IF NEW.exit_station_id = NEW.entry_station_id THEN
        v_base := 0;                                  -- แตะออกสถานีเดิม = ยกเลิก ไม่คิดเงิน
    ELSE
        SELECT base_fare INTO v_base FROM fare_tables
        WHERE origin_station_id = NEW.entry_station_id AND destination_station_id = NEW.exit_station_id;
        IF v_base IS NULL THEN
            RAISE EXCEPTION 'ไม่พบค่าโดยสารระหว่างสถานีนี้';
        END IF;
    END IF;

    SELECT ct.discount_rate, c.balance INTO v_discount, v_balance
    FROM cards c JOIN card_types ct USING (card_type_id)
    WHERE c.card_id = NEW.card_id
    FOR UPDATE OF c;                                  -- ล็อกแถวบัตรกันการหักเงินซ้อนกัน

    v_fare := ROUND(v_base * (1 - v_discount), 0);
    IF v_balance < v_fare THEN
        RAISE EXCEPTION 'ยอดเงินในบัตรไม่พอ (เหลือ % บาท ค่าโดยสาร % บาท)', v_balance, v_fare;
    END IF;

    UPDATE cards SET balance = balance - v_fare WHERE card_id = NEW.card_id;

    NEW.exit_time    := COALESCE(NEW.exit_time, now());
    NEW.fare_charged := v_fare;
    NEW.status       := CASE WHEN v_base = 0 THEN 'CANCELLED' ELSE 'COMPLETED' END;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS gate_tap_out ON gate_logs;
CREATE TRIGGER gate_tap_out
    BEFORE UPDATE OF exit_station_id ON gate_logs
    FOR EACH ROW EXECUTE FUNCTION public.trg_gate_tap_out();

-- 2.3 เติมเงิน: เพิ่มยอดในบัตรอัตโนมัติ
CREATE OR REPLACE FUNCTION public.trg_card_topup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE cards SET balance = balance + NEW.amount WHERE card_id = NEW.card_id;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS card_topup_balance ON card_topups;
CREATE TRIGGER card_topup_balance
    AFTER INSERT ON card_topups
    FOR EACH ROW EXECUTE FUNCTION public.trg_card_topup();

-- 2.4 ฟังก์ชันเรียกจากหน้าเว็บ: แตะเข้า / แตะออก / เติมเงิน (Trigger ทำงานต่อเอง)
--     SECURITY DEFINER + ตรวจสิทธิ์เอง: ผู้โดยสารทำได้กับบัตรของตัวเอง, staff/admin ทำได้ทุกบัตร
CREATE OR REPLACE FUNCTION public.can_use_card(p_card_id BIGINT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT public.app_role() IN ('staff', 'admin')
        OR EXISTS (SELECT 1 FROM cards WHERE card_id = p_card_id AND user_id = public.app_user_id());
$$;

CREATE OR REPLACE FUNCTION public.tap_in(p_card_id BIGINT, p_station_id BIGINT)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id BIGINT;
BEGIN
    IF NOT public.can_use_card(p_card_id) THEN RAISE EXCEPTION 'คุณไม่มีสิทธิ์ใช้บัตรใบนี้'; END IF;
    INSERT INTO gate_logs (card_id, entry_station_id) VALUES (p_card_id, p_station_id) RETURNING log_id INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.tap_out(p_log_id BIGINT, p_station_id BIGINT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r gate_logs%ROWTYPE;
BEGIN
    SELECT * INTO r FROM gate_logs WHERE log_id = p_log_id AND status = 'IN_JOURNEY';
    IF r.log_id IS NULL THEN RAISE EXCEPTION 'ไม่พบเที่ยวที่กำลังเดินทางอยู่'; END IF;
    IF NOT public.can_use_card(r.card_id) THEN RAISE EXCEPTION 'คุณไม่มีสิทธิ์ใช้บัตรใบนี้'; END IF;
    UPDATE gate_logs SET exit_station_id = p_station_id WHERE log_id = p_log_id RETURNING * INTO r;
    RETURN json_build_object('fare_charged', r.fare_charged, 'status', r.status,
        'balance', (SELECT balance FROM cards WHERE card_id = r.card_id));
END;
$$;

CREATE OR REPLACE FUNCTION public.top_up_card(p_card_id BIGINT, p_amount NUMERIC, p_method TEXT)
RETURNS NUMERIC LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_pay BIGINT; v_user BIGINT;
BEGIN
    IF NOT public.can_use_card(p_card_id) THEN RAISE EXCEPTION 'คุณไม่มีสิทธิ์ใช้บัตรใบนี้'; END IF;
    IF p_amount NOT IN (100, 200, 300, 500, 1000) THEN RAISE EXCEPTION 'เติมได้ครั้งละ 100, 200, 300, 500 หรือ 1000 บาท'; END IF;
    SELECT user_id INTO v_user FROM cards WHERE card_id = p_card_id;
    -- บันทึก 2 ตารางใน Transaction เดียว: payments (กลาง) + card_topups (BTS)
    INSERT INTO payments (user_id, service_type, amount, method, status)
    VALUES (v_user, 'RAIL_TOPUP', p_amount, p_method, 'PAID') RETURNING payment_id INTO v_pay;
    INSERT INTO card_topups (card_id, payment_id, amount) VALUES (p_card_id, v_pay, p_amount);
    RETURN (SELECT balance FROM cards WHERE card_id = p_card_id);
END;
$$;


-- #####################################################################
-- ส่วนที่ 3: วางแผนเดินทางข้ามระบบ
-- plan_trip(เที่ยวบิน, 'STATION' หรือ 'BUS_STOP', id ปลายทาง, ประเภทบัตร)
-- คืน JSON: legs (แต่ละช่วง: โหมด จาก ถึง เวลา ค่าโดยสาร), total_fare, total_minutes
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
        LEFT JOIN fare_tables ft ON ft.origin_station_id = v_from_st AND ft.destination_station_id = st.station_id
        WHERE rs_dest.stop_id = p_dest_id
        ORDER BY COALESCE((ft.base_fare - 14) / 3 * 2.5 + 4, 0)                -- เวลาบน BTS
               + abs(rs_dest.sequence_no - rs_on.sequence_no) * 4               -- เวลาบนรถเมล์
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
        v_min  := ((v_base - 14) / 3 * 2.5 + 4)::int;
        v_legs := v_legs || jsonb_build_object('mode', 'BTS', 'title', 'รถไฟฟ้า BTS',
            'from', (SELECT station_name FROM stations WHERE station_id = v_from_st),
            'to',   (SELECT station_name FROM stations WHERE station_id = v_to_st),
            'depart', v_clock, 'arrive', v_clock + make_interval(mins => v_min), 'minutes', v_min, 'fare', v_fare,
            'note', format('ราคาฐาน %s บาท', v_base::int)
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

REVOKE EXECUTE ON FUNCTION public.tap_in(BIGINT, BIGINT), public.tap_out(BIGINT, BIGINT),
    public.top_up_card(BIGINT, NUMERIC, TEXT), public.plan_trip(BIGINT, TEXT, BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tap_in(BIGINT, BIGINT), public.tap_out(BIGINT, BIGINT),
    public.top_up_card(BIGINT, NUMERIC, TEXT), public.plan_trip(BIGINT, TEXT, BIGINT, TEXT) TO authenticated;
