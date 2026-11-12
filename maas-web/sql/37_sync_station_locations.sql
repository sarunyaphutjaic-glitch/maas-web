-- =====================================================================
-- 37: ปรับพิกัดสถานี BTS ให้ตรงตำแหน่งจริงจาก OpenStreetMap
-- รันหลัง 35_bts_full_line.sql
--
-- หน้าแผนที่ (ผู้ดูแล) ดึงตำแหน่งสถานีจริงจาก OpenStreetMap แล้วส่งมาเป็น JSON
--   [{ "code": "N24", "lat": 13.93, "lon": 100.64 }, ...]
-- ฟังก์ชันนี้อัปเดตพิกัดใน locations ของสถานี และย้ายป้ายรถเมล์ข้างสถานี (B-<รหัส>) ตามไปด้วย
-- =====================================================================
CREATE OR REPLACE FUNCTION public.sync_station_locations(p_points JSONB)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_rail INT;
    v_bus  INT;
BEGIN
    IF public.app_role() IS DISTINCT FROM 'admin' THEN
        RAISE EXCEPTION 'เฉพาะผู้ดูแลระบบเท่านั้น';
    END IF;

    -- ตรวจรูปแบบข้อมูล: พิกัดต้องอยู่ในกรอบกรุงเทพฯ และปริมณฑล
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_points) e
        WHERE (e->>'lat')::numeric NOT BETWEEN 13.4 AND 14.1
           OR (e->>'lon')::numeric NOT BETWEEN 100.2 AND 100.9
    ) THEN
        RAISE EXCEPTION 'มีพิกัดอยู่นอกพื้นที่กรุงเทพฯ';
    END IF;

    WITH p AS (
        SELECT e->>'code' AS code, ROUND((e->>'lat')::numeric, 6) AS lat, ROUND((e->>'lon')::numeric, 6) AS lon
        FROM jsonb_array_elements(p_points) e
    )
    UPDATE locations l SET latitude = p.lat, longitude = p.lon
    FROM p JOIN stations s ON s.station_code = p.code
    WHERE l.location_id = s.location_id;
    GET DIAGNOSTICS v_rail = ROW_COUNT;

    -- ป้ายรถเมล์ข้างสถานี: ห่างจากสถานีประมาณ 70–100 เมตรเหมือนเดิม
    WITH p AS (
        SELECT e->>'code' AS code, ROUND((e->>'lat')::numeric, 6) AS lat, ROUND((e->>'lon')::numeric, 6) AS lon
        FROM jsonb_array_elements(p_points) e
    )
    UPDATE locations l SET latitude = p.lat + 0.0006, longitude = p.lon + 0.0004
    FROM p JOIN bus_stops b ON b.stop_code = 'B-' || p.code
    WHERE l.location_id = b.location_id;
    GET DIAGNOSTICS v_bus = ROW_COUNT;

    RETURN json_build_object('stations_updated', v_rail, 'bus_stops_moved', v_bus);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.sync_station_locations(JSONB) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.sync_station_locations(JSONB) TO authenticated;
