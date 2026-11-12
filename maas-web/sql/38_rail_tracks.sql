-- =====================================================================
-- 38: เก็บแนวรางรถไฟฟ้า BTS (ดึงจาก OpenStreetMap) ไว้ในฐานข้อมูล
-- รันหลัง 37_sync_station_locations.sql
--
-- ผู้ดูแลกดปุ่มบนหน้าแผนที่ → Edge Function ดึงข้อมูลจาก OpenStreetMap (ฝั่งเซิร์ฟเวอร์)
--   → ปรับพิกัดสถานี (sync_station_locations) + บันทึกแนวรางลงตารางนี้ (save_rail_tracks)
-- หน้าแผนที่อ่านแนวรางจากตารางนี้ ไม่ต้องเรียกเซิร์ฟเวอร์ภายนอกจากเบราว์เซอร์
-- =====================================================================
CREATE TABLE IF NOT EXISTS rail_tracks (
    line_id     BIGINT      PRIMARY KEY,
    geometry    JSONB       NOT NULL,          -- [[ [lat, lon], [lat, lon], ... ], ...] หลายช่วงราง
    segments    INT         NOT NULL,
    source      VARCHAR(100) NOT NULL DEFAULT 'OpenStreetMap (Overpass API)',
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_rail_tracks_line FOREIGN KEY (line_id) REFERENCES lines(line_id) ON DELETE CASCADE,
    CONSTRAINT chk_rail_tracks_array CHECK (jsonb_typeof(geometry) = 'array')
);
COMMENT ON TABLE rail_tracks IS 'แนวรางจริงของแต่ละสาย จาก OpenStreetMap (ข้อมูลเปิด ODbL) ใช้วาดเส้นบนแผนที่ Leaflet';

ALTER TABLE rail_tracks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rail_tracks_read ON rail_tracks;
CREATE POLICY rail_tracks_read ON rail_tracks FOR SELECT TO authenticated USING (true);

CREATE OR REPLACE FUNCTION public.save_rail_tracks(p_tracks JSONB)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_n INT;
BEGIN
    IF public.app_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'เฉพาะผู้ดูแลระบบเท่านั้น'; END IF;
    INSERT INTO rail_tracks (line_id, geometry, segments, updated_at)
    SELECT l.line_id, t.value, jsonb_array_length(t.value), now()
    FROM jsonb_each(p_tracks) t
    JOIN lines l ON l.code = t.key
    WHERE jsonb_typeof(t.value) = 'array' AND jsonb_array_length(t.value) > 0
    ON CONFLICT (line_id) DO UPDATE
        SET geometry = EXCLUDED.geometry, segments = EXCLUDED.segments, updated_at = now();
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.save_rail_tracks(JSONB) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.save_rail_tracks(JSONB) TO authenticated;
