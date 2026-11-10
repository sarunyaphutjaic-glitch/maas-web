-- =====================================================================
-- View เพิ่มเติม (ส่วนรถเมล์): ป้ายทั้งหมดของแต่ละสาย เรียงตามลำดับ
-- ใช้ตอบคำถามแบบ "รถเมล์สายไหนไปรังสิต" หรือ "สาย 2 ผ่านป้ายอะไรบ้าง"
-- รันหลัง 20_bus_all.sql
-- =====================================================================
CREATE OR REPLACE VIEW v_bus_route_stops
WITH (security_invoker = true) AS
SELECT
    br.route_no,
    br.route_name,
    br.fare,
    rs.sequence_no,
    bs.stop_code,
    bs.stop_name,
    l.district,
    -- ชื่อสถานี BTS ถ้าป้ายนี้อยู่ใกล้สถานี (ป้ายที่ขึ้นต้นด้วย B- ตั้งไว้ข้างสถานี)
    st.station_name AS near_bts_station
FROM route_stops rs
JOIN bus_routes br    ON br.route_id = rs.route_id
JOIN bus_stops bs     ON bs.stop_id = rs.stop_id
JOIN locations l      ON l.location_id = bs.location_id
LEFT JOIN stations st ON bs.stop_code = 'B-' || st.station_code;
