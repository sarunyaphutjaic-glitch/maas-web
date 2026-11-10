-- =====================================================================
-- 32: สิทธิ์ของผู้โดยสารในระบบ Chat + View ข้อมูลสาธารณะ
-- รันหลัง 08_chat_query.sql, 10_airline_all.sql
--
-- ผู้โดยสารถาม Chat ได้ 2 แบบเท่านั้น
--   1) ข้อมูลสาธารณะ: ค่าโดยสาร BTS, ตารางเที่ยวบิน, สายและป้ายรถเมล์
--   2) ข้อมูลของตัวเอง: การเดินทาง ตั๋ว การขึ้นรถ ค่าใช้จ่าย (RLS กรองให้เหลือของตัวเอง)
-- View ภาพรวม/รายได้ (v_station_ridership, v_route_revenue, v_payment_summary ฯลฯ) ถูกปฏิเสธในฐานข้อมูล
-- =====================================================================

-- ค่าโดยสาร BTS ระหว่างสถานี พร้อมราคาตามประเภทบัตร (ข้อมูลสาธารณะ)
CREATE OR REPLACE VIEW v_fare_lookup
WITH (security_invoker = true) AS
SELECT
    so.station_name                                        AS origin_station,
    so.station_code                                        AS origin_code,
    sd.station_name                                        AS destination_station,
    sd.station_code                                        AS destination_code,
    ft.base_fare                                           AS adult_fare,
    ROUND(ft.base_fare * (1 - (SELECT discount_rate FROM card_types WHERE type_name = 'Student')), 0) AS student_fare,
    ROUND(ft.base_fare * (1 - (SELECT discount_rate FROM card_types WHERE type_name = 'Senior')), 0)  AS senior_fare
FROM fare_tables ft
JOIN stations so ON so.station_id = ft.origin_station_id
JOIN stations sd ON sd.station_id = ft.destination_station_id;

-- ตารางเที่ยวบิน (ข้อมูลสาธารณะ ไม่มีข้อมูลผู้โดยสาร)
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
    f.status                                               AS flight_status
FROM flights f
JOIN airports ao ON ao.airport_id = f.origin_airport_id
JOIN airports ad ON ad.airport_id = f.destination_airport_id;

-- ฟังก์ชันรัน SQL ของ Chat (เพิ่มการตรวจสิทธิ์ผู้โดยสาร)
CREATE OR REPLACE FUNCTION public.run_chat_query(p_sql TEXT)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
SET statement_timeout = '5s'
AS $$
DECLARE
    v_sql    TEXT := regexp_replace(trim(p_sql), ';\s*$', '');   -- ตัด ; ท้ายคำสั่ง
    v_lower  TEXT;
    v_ref    TEXT;
    v_result JSON;
BEGIN
    v_lower := lower(v_sql);

    IF v_lower !~ '^(select|with)\s' THEN
        RAISE EXCEPTION 'อนุญาตเฉพาะคำสั่ง SELECT เท่านั้น';
    END IF;

    IF position(';' IN v_sql) > 0 THEN
        RAISE EXCEPTION 'อนุญาตให้รันได้ครั้งละหนึ่งคำสั่งเท่านั้น';
    END IF;

    IF v_lower ~ '\m(insert|update|delete|merge|drop|alter|create|truncate|grant|revoke|copy|call|execute|vacuum|reindex|cluster|lock|listen|notify|refresh)\M' THEN
        RAISE EXCEPTION 'พบคำสั่งที่แก้ไขข้อมูลหรือโครงสร้าง ซึ่งไม่อนุญาต';
    END IF;

    IF v_lower ~ '(pg_|information_schema|\mauth\.|\mstorage\.|\mextensions\.|\mvault\.|dblink|lo_import|lo_export|set_config|current_setting)' THEN
        RAISE EXCEPTION 'ไม่อนุญาตให้เข้าถึงตารางหรือฟังก์ชันของระบบ';
    END IF;

    -- ชื่อที่ตามหลัง FROM / JOIN ต้องไม่ใช่ตารางจริง (ใช้ได้เฉพาะ View หรือ CTE)
    FOR v_ref IN
        SELECT (regexp_matches(v_lower, '\m(?:from|join)\s+(?:public\.)?([a-z_][a-z0-9_]*)', 'g'))[1]
    LOOP
        IF EXISTS (
            SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relname = v_ref AND c.relkind IN ('r', 'p', 'f')
        ) THEN
            RAISE EXCEPTION 'ไม่อนุญาตให้อ่านตาราง % โดยตรง ให้ใช้ View (v_...) แทน', v_ref;
        END IF;
    END LOOP;

    -- ผู้โดยสารใช้ได้เฉพาะ View ข้อมูลสาธารณะและข้อมูลของตัวเอง (View ภาพรวม/รายได้ เป็นของผู้ดูแลเท่านั้น)
    IF public.app_role() = 'passenger' THEN
        FOR v_ref IN
            SELECT (regexp_matches(v_lower, '\m(?:from|join)\s+(?:public\.)?([a-z_][a-z0-9_]*)', 'g'))[1]
        LOOP
            IF EXISTS (
                SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'public' AND c.relname = v_ref AND c.relkind = 'v'
            ) AND v_ref <> ALL (ARRAY[
                'v_trip_details', 'v_problem_trips', 'v_flight_bookings', 'v_bus_ride_details', 'v_user_spending',
                'v_bus_route_stops', 'v_bus_stops_near_bts', 'v_fare_lookup', 'v_flight_schedule'
            ]) THEN
                RAISE EXCEPTION 'ข้อมูลนี้ (%) เป็นข้อมูลภาพรวมของระบบ ดูได้เฉพาะผู้ดูแลระบบ', v_ref;
            END IF;
        END LOOP;
    END IF;

    EXECUTE format(
        'SELECT COALESCE(json_agg(t), ''[]''::json) FROM (SELECT * FROM (%s) q LIMIT 100) t',
        v_sql
    ) INTO v_result;

    RETURN json_build_object('rows', v_result);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.run_chat_query(TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.run_chat_query(TEXT) TO authenticated;
