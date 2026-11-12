-- =====================================================================
-- 35: รถไฟฟ้า BTS สายสีเขียวครบทุกสถานี (60 สถานี) + ป้ายรถเมล์ข้างสถานีใหม่
-- รันหลัง 34_nearest_agent.sql · รันครั้งเดียว
--
-- สายสุขุมวิท: N24 คูคต → N1 ราชเทวี → CEN สยาม → E1 ชิดลม → E23 เคหะฯ   (47 สถานี)
-- สายสีลม:     W1 สนามกีฬาแห่งชาติ → CEN สยาม → S1 ราชดำริ → S12 บางหว้า (14 สถานี)
-- (สยามอยู่ทั้ง 2 สาย รวม 60 สถานี) · พิกัดเป็นค่าประมาณ
--
-- ค่าโดยสาร: ใช้สูตรเดิม LEAST(47, 14 + 3 × จำนวนสถานี) ค่าโดยสารคู่สถานีเดิมจึงไม่เปลี่ยน
-- และประวัติการเดินทางเดิมใน gate_logs ยังสอดคล้องกัน
-- =====================================================================


-- #####################################################################
-- 1) สถานีใหม่ 30 สถานี + ตำแหน่งในตารางกลาง
-- #####################################################################
WITH s(code, name, lat, lon, district) AS (
    VALUES
    ('N9',  'ห้าแยกลาดพร้าว',            13.816500, 100.561700, 'จตุจักร'),
    ('N10', 'พหลโยธิน 24',               13.824700, 100.565200, 'จตุจักร'),
    ('N11', 'รัชโยธิน',                  13.829700, 100.569400, 'จตุจักร'),
    ('N12', 'เสนานิคม',                  13.836400, 100.572900, 'จตุจักร'),
    ('N13', 'มหาวิทยาลัยเกษตรศาสตร์',     13.842000, 100.573800, 'จตุจักร'),
    ('N14', 'กรมป่าไม้',                  13.850100, 100.575900, 'จตุจักร'),
    ('N15', 'บางบัว',                    13.856200, 100.579300, 'บางเขน'),
    ('N16', 'กรมทหารราบที่ 11',           13.867800, 100.586200, 'บางเขน'),
    ('N17', 'วัดพระศรีมหาธาตุ',            13.874900, 100.596500, 'บางเขน'),
    ('N18', 'พหลโยธิน 59',               13.882200, 100.603300, 'บางเขน'),
    ('N19', 'สายหยุด',                   13.888300, 100.608300, 'บางเขน'),
    ('N20', 'สะพานใหม่',                 13.896100, 100.615800, 'บางเขน'),
    ('N21', 'โรงพยาบาลภูมิพลอดุลยเดช',     13.910400, 100.618100, 'ดอนเมือง'),
    ('N22', 'พิพิธภัณฑ์กองทัพอากาศ',       13.918300, 100.619900, 'ดอนเมือง'),
    ('N23', 'แยก คปอ.',                  13.925500, 100.625500, 'ลำลูกกา'),
    ('N24', 'คูคต',                      13.932200, 100.645700, 'ลำลูกกา'),
    ('E15', 'สำโรง',                     13.646400, 100.596100, 'เมืองสมุทรปราการ'),
    ('E16', 'ปู่เจ้า',                    13.638200, 100.591800, 'เมืองสมุทรปราการ'),
    ('E17', 'ช้างเอราวัณ',                13.622900, 100.587600, 'เมืองสมุทรปราการ'),
    ('E18', 'โรงเรียนนายเรือ',             13.608300, 100.594700, 'เมืองสมุทรปราการ'),
    ('E19', 'ปากน้ำ',                    13.604000, 100.604800, 'เมืองสมุทรปราการ'),
    ('E20', 'ศรีนครินทร์',                 13.597600, 100.608700, 'เมืองสมุทรปราการ'),
    ('E21', 'แพรกษา',                    13.587600, 100.611800, 'เมืองสมุทรปราการ'),
    ('E22', 'สายลวด',                    13.577200, 100.614900, 'เมืองสมุทรปราการ'),
    ('E23', 'เคหะฯ',                     13.567400, 100.608100, 'เมืองสมุทรปราการ'),
    ('S8',  'วงเวียนใหญ่',                13.721200, 100.495700, 'ธนบุรี'),
    ('S9',  'โพธิ์นิมิตร',                 13.719300, 100.486000, 'ธนบุรี'),
    ('S10', 'ตลาดพลู',                   13.714400, 100.476600, 'ธนบุรี'),
    ('S11', 'วุฒากาศ',                   13.712700, 100.468700, 'จอมทอง'),
    ('S12', 'บางหว้า',                   13.720600, 100.457700, 'ภาษีเจริญ')
),
ins AS (
    INSERT INTO locations (location_name, location_type, latitude, longitude, district)
    SELECT 'สถานี BTS ' || name, 'RAIL_STATION', lat, lon, district FROM s
    RETURNING location_id, location_name
)
INSERT INTO stations (station_code, station_name, location_id)
SELECT s.code, s.name, ins.location_id
FROM s JOIN ins ON ins.location_name = 'สถานี BTS ' || s.name
ON CONFLICT (station_code) DO NOTHING;


-- #####################################################################
-- 2) ลำดับสถานีใหม่ทั้งสาย
--    เลื่อนเลขลำดับเดิมออกไปก่อน (+1000) เพื่อไม่ชน UNIQUE (line_id, sequence_no) ระหว่างจัดลำดับใหม่
-- #####################################################################
UPDATE station_sequences SET sequence_no = sequence_no + 1000;

WITH lines_def(line_code, codes) AS (
    VALUES
    ('SUK', ARRAY['N24','N23','N22','N21','N20','N19','N18','N17','N16','N15','N14','N13','N12','N11','N10','N9',
                  'N8','N7','N5','N4','N3','N2','N1','CEN',
                  'E1','E2','E3','E4','E5','E6','E7','E8','E9','E10','E11','E12','E13','E14',
                  'E15','E16','E17','E18','E19','E20','E21','E22','E23']),
    ('SIL', ARRAY['W1','CEN','S1','S2','S3','S4','S5','S6','S7','S8','S9','S10','S11','S12'])
),
seq AS (
    SELECT l.line_id, st.station_id, x.seq::int AS sequence_no
    FROM lines_def d
    JOIN lines l ON l.code = d.line_code
    CROSS JOIN LATERAL unnest(d.codes) WITH ORDINALITY AS x(code, seq)
    JOIN stations st ON st.station_code = x.code
)
INSERT INTO station_sequences (line_id, station_id, sequence_no)
SELECT line_id, station_id, sequence_no FROM seq
ON CONFLICT (line_id, station_id) DO UPDATE SET sequence_no = EXCLUDED.sequence_no;


-- #####################################################################
-- 3) ค่าโดยสารทุกคู่สถานี (60 × 59 = 3,540 คู่) ด้วย bts_hops จาก 34_nearest_agent.sql
-- #####################################################################
INSERT INTO fare_tables (origin_station_id, destination_station_id, base_fare)
SELECT a.station_id, b.station_id, LEAST(47, 14 + 3 * public.bts_hops(a.station_id, b.station_id))
FROM stations a CROSS JOIN stations b
WHERE a.station_id <> b.station_id
ON CONFLICT (origin_station_id, destination_station_id) DO NOTHING;


-- #####################################################################
-- 4) ป้ายรถเมล์ข้างสถานีใหม่ 30 ป้าย (ห่างสถานีประมาณ 70–100 เมตร)
-- #####################################################################
WITH n(code, stop_name) AS (
    VALUES
    ('N9',  'ป้ายเซ็นทรัลลาดพร้าว'),   ('N10', 'ป้ายพหลโยธิน 24'),       ('N11', 'ป้ายรัชโยธิน'),
    ('N12', 'ป้ายเสนานิคม'),          ('N13', 'ป้ายมหาวิทยาลัยเกษตรศาสตร์'), ('N14', 'ป้ายกรมป่าไม้'),
    ('N15', 'ป้ายบางบัว'),            ('N16', 'ป้ายกรมทหารราบที่ 11'),    ('N17', 'ป้ายวัดพระศรีมหาธาตุ'),
    ('N18', 'ป้ายพหลโยธิน 59'),       ('N19', 'ป้ายสายหยุด'),           ('N20', 'ป้ายตลาดสะพานใหม่'),
    ('N21', 'ป้ายโรงพยาบาลภูมิพลฯ'),   ('N22', 'ป้ายพิพิธภัณฑ์กองทัพอากาศ'), ('N23', 'ป้ายแยก คปอ.'),
    ('N24', 'ป้ายคูคต'),              ('E15', 'ป้ายอิมพีเรียลสำโรง'),     ('E16', 'ป้ายปู่เจ้า'),
    ('E17', 'ป้ายช้างเอราวัณ'),        ('E18', 'ป้ายโรงเรียนนายเรือ'),     ('E19', 'ป้ายปากน้ำ'),
    ('E20', 'ป้ายศรีนครินทร์'),         ('E21', 'ป้ายแพรกษา'),            ('E22', 'ป้ายสายลวด'),
    ('E23', 'ป้ายเคหะบางพลี'),        ('S8',  'ป้ายวงเวียนใหญ่'),        ('S9',  'ป้ายโพธิ์นิมิตร'),
    ('S10', 'ป้ายตลาดพลู'),           ('S11', 'ป้ายวุฒากาศ'),           ('S12', 'ป้ายบางหว้า')
),
s AS (
    SELECT n.code, n.stop_name, l.latitude + 0.0006 AS lat, l.longitude + 0.0004 AS lon, l.district
    FROM n JOIN stations st ON st.station_code = n.code JOIN locations l ON l.location_id = st.location_id
),
ins AS (
    INSERT INTO locations (location_name, location_type, latitude, longitude, district)
    SELECT 'ป้ายรถเมล์ ' || code || ' ' || stop_name, 'BUS_STOP', lat, lon, district FROM s
    RETURNING location_id, location_name
)
INSERT INTO bus_stops (stop_code, stop_name, location_id)
SELECT 'B-' || s.code, s.stop_name, ins.location_id
FROM s JOIN ins ON ins.location_name = 'ป้ายรถเมล์ ' || s.code || ' ' || s.stop_name
ON CONFLICT (stop_code) DO NOTHING;


-- #####################################################################
-- 5) สายรถเมล์: ขยายสายเดิมและเพิ่ม 2 สาย (เลขสายจริง ลำดับป้ายย่อเฉพาะแนว BTS)
-- #####################################################################
INSERT INTO bus_routes (route_no, route_name, fare) VALUES
    ('365', 'ปากน้ำ – บางปู (ถ.สุขุมวิท)',                    15),
    ('4',   'ท่าเรือคลองเตย – ภาษีเจริญ (ถ.สีลม, เพชรเกษม)',    13)
ON CONFLICT (route_no) DO NOTHING;

UPDATE bus_routes SET route_name = 'รังสิต – หัวลำโพง (ถ.พหลโยธิน, พญาไท)' WHERE route_no = '29';

-- ลำดับป้ายใหม่ของสายที่เปลี่ยน: เก็บในตารางชั่วคราว → ลบลำดับเดิมของสายนั้น → ใส่ใหม่ทั้งสาย
CREATE TEMP TABLE new_route_stops (route_no TEXT, stops TEXT[]);
INSERT INTO new_route_stops VALUES
    ('29',  ARRAY['B-N24','B-N23','B-N22','B-N21','B-N20','B-N19','B-N18','B-N17','B-N16','B-N15','B-N14',
                  'B-N13','B-N12','B-N11','B-N10','B-N9','B-N8','B-N7','B-N5','B-N4','B-N3','B-N2','B-W1']),
    ('2',   ARRAY['B-E15','B-E14','B-E13','B-E12','B-E11','B-E10','B-E9','B-E8','B-E7','B-E6','B-E5','B-E4',
                  'B-E3','B-E2','B-E1','B-CEN','B-W1']),
    ('25',  ARRAY['B-E19','B-E18','B-E17','B-E16','B-E15','B-E13','B-E9','B-E7','B-E5','B-E4','B-E2','B-E1',
                  'B-CEN','B-W1']),
    ('365', ARRAY['B-E19','B-E20','B-E21','B-E22','B-E23']),
    ('4',   ARRAY['B-S2','B-S3','B-S6','B-S7','B-S8','B-S9','B-S10','B-S11','B-S12']),
    ('77',  ARRAY['B-N9','B-N8','B-N7','B-N5','B-N3','B-N1','B-S1','B-S2','B-S3','B-S5']);

DELETE FROM route_stops
WHERE route_id IN (SELECT br.route_id FROM bus_routes br JOIN new_route_stops r USING (route_no));

INSERT INTO route_stops (route_id, stop_id, sequence_no)
SELECT br.route_id, bs.stop_id, x.seq
FROM new_route_stops r
CROSS JOIN LATERAL unnest(r.stops) WITH ORDINALITY AS x(code, seq)
JOIN bus_routes br ON br.route_no = r.route_no
JOIN bus_stops bs  ON bs.stop_code = x.code;

DROP TABLE new_route_stops;


-- ตรวจผล
SELECT (SELECT COUNT(*) FROM stations) AS stations,
       (SELECT COUNT(*) FROM station_sequences) AS station_sequences,
       (SELECT COUNT(*) FROM fare_tables) AS fare_pairs,
       (SELECT COUNT(*) FROM bus_stops) AS bus_stops,
       (SELECT COUNT(*) FROM bus_routes) AS bus_routes;
