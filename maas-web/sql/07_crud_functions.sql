-- =====================================================
-- 07: ฟังก์ชันสำหรับหน้า CRUD
-- การเพิ่ม/ลบสถานีต้องแก้หลายตารางพร้อมกัน (locations, stations,
-- station_sequences, fare_tables) จึงรวมไว้ในฟังก์ชันเดียว
-- ถ้าขั้นตอนใดผิดพลาด ทุกอย่างจะถูกยกเลิกทั้งหมด (atomic)
-- SECURITY INVOKER → ทำงานด้วยสิทธิ์ของผู้เรียก RLS จึงยังบังคับใช้ (admin เท่านั้น)
-- =====================================================

-- เพิ่มสถานีใหม่ต่อท้ายสาย พร้อมสร้างค่าโดยสารไป-กลับทุกสถานี
CREATE OR REPLACE FUNCTION public.add_station(
    p_code      TEXT,
    p_name      TEXT,
    p_line_code TEXT,
    p_latitude  NUMERIC,
    p_longitude NUMERIC,
    p_district  TEXT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_line_id    BIGINT;
    v_loc_id     BIGINT;
    v_station_id BIGINT;
BEGIN
    SELECT line_id INTO v_line_id FROM lines WHERE code = p_line_code;
    IF v_line_id IS NULL THEN
        RAISE EXCEPTION 'ไม่พบสายรถไฟฟ้ารหัส %', p_line_code;
    END IF;

    INSERT INTO locations (location_name, location_type, latitude, longitude, district)
    VALUES ('สถานี BTS ' || p_name, 'RAIL_STATION', p_latitude, p_longitude, p_district)
    RETURNING location_id INTO v_loc_id;

    INSERT INTO stations (station_code, station_name, location_id)
    VALUES (upper(trim(p_code)), trim(p_name), v_loc_id)
    RETURNING station_id INTO v_station_id;

    -- ต่อท้ายสาย (ลำดับถัดจากสถานีสุดท้าย)
    INSERT INTO station_sequences (line_id, station_id, sequence_no)
    SELECT v_line_id, v_station_id, COALESCE(MAX(sequence_no), 0) + 1
    FROM station_sequences WHERE line_id = v_line_id;

    -- ค่าโดยสารระหว่างสถานีใหม่กับทุกสถานี (สูตรเดียวกับข้อมูลจำลอง)
    WITH m AS (SELECT station_id, line_id, sequence_no FROM station_sequences),
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
        JOIN m b    ON a.station_id <> b.station_id
        JOIN cen ca ON ca.line_id = a.line_id
        JOIN cen cb ON cb.line_id = b.line_id
        WHERE a.station_id = v_station_id OR b.station_id = v_station_id
        GROUP BY a.station_id, b.station_id
    )
    INSERT INTO fare_tables (origin_station_id, destination_station_id, base_fare)
    SELECT o, d, LEAST(47, 14 + 3 * hops) FROM d
    ON CONFLICT (origin_station_id, destination_station_id) DO NOTHING;

    RETURN v_station_id;
END;
$$;

-- ลบสถานี (ค่าโดยสารและลำดับสถานีถูกลบตาม CASCADE แล้วลบ location ที่ผูกอยู่)
-- ถ้าสถานีมีประวัติการเดินทางใน gate_logs จะลบไม่ได้ (FK ป้องกันไว้)
CREATE OR REPLACE FUNCTION public.delete_station(p_station_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_loc_id BIGINT;
BEGIN
    DELETE FROM stations WHERE station_id = p_station_id
    RETURNING location_id INTO v_loc_id;

    IF v_loc_id IS NULL THEN
        RAISE EXCEPTION 'ไม่พบสถานี หรือคุณไม่มีสิทธิ์ลบ';
    END IF;

    DELETE FROM locations WHERE location_id = v_loc_id;
END;
$$;

-- ผู้ใช้ที่ไม่ได้ login เรียกฟังก์ชันไม่ได้
REVOKE EXECUTE ON FUNCTION public.add_station(TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.delete_station(BIGINT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.add_station(TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TEXT) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.delete_station(BIGINT) TO authenticated;
