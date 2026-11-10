-- =====================================================
-- analysis_queries — ส่วนสายการบิน (สมาชิกคนที่ 1)
-- รันทีละคำสั่ง: ลากคลุมคำสั่งที่ต้องการแล้วกด Run
-- =====================================================


-- #####################################################
-- หมวด 1: SQL Select Join Tables
-- #####################################################

-- A1.1 [INNER JOIN 5 ตาราง]
-- คำถาม: การจองที่ยืนยันแล้ว 10 รายการล่าสุด ใครจอง บินจากเมืองไหนไปไหน ชั้นอะไร
SELECT
    b.booking_ref,
    u.full_name                                  AS booker,
    f.flight_no,
    ao.city                                      AS from_city,
    ad.city                                      AS to_city,
    f.departure_time AT TIME ZONE 'Asia/Bangkok' AS departure_th,
    t.travel_class,
    t.price
FROM tickets t
INNER JOIN bookings b  ON b.booking_id = t.booking_id
INNER JOIN users u     ON u.user_id = b.user_id
INNER JOIN flights f   ON f.flight_id = t.flight_id
INNER JOIN airports ao ON ao.airport_id = f.origin_airport_id
INNER JOIN airports ad ON ad.airport_id = f.destination_airport_id
WHERE b.status = 'CONFIRMED'
ORDER BY b.booked_at DESC
LIMIT 10;

-- A1.2 [LEFT JOIN ข้ามระบบ]
-- คำถาม: ผู้ใช้ที่เคยบิน มีบัตร BTS หรือไม่ และใช้บัตรประเภทอะไร (ลูกค้าที่ใช้หลายบริการ)
SELECT
    u.full_name,
    COUNT(DISTINCT b.booking_id)  AS flight_bookings,
    c.card_number,
    ct.type_name                  AS bts_card_type
FROM users u
INNER JOIN bookings b    ON b.user_id = u.user_id AND b.status = 'CONFIRMED'
LEFT JOIN cards c        ON c.user_id = u.user_id
LEFT JOIN card_types ct  ON ct.card_type_id = c.card_type_id
GROUP BY u.full_name, c.card_number, ct.type_name
ORDER BY flight_bookings DESC
LIMIT 10;


-- #####################################################
-- หมวด 2: SQL Aggregate Functions
-- #####################################################

-- A2.1 [COUNT(*), COUNT(DISTINCT), SUM, AVG, MIN, MAX]
-- คำถาม: ภาพรวมการขายตั๋วที่ยืนยันแล้วทั้งหมด
SELECT
    COUNT(*)                     AS tickets_sold,
    COUNT(DISTINCT b.user_id)    AS unique_customers,
    SUM(t.price)                 AS total_revenue,
    ROUND(AVG(t.price), 2)       AS avg_price,
    MIN(t.price)                 AS min_price,
    MAX(t.price)                 AS max_price
FROM tickets t
JOIN bookings b ON b.booking_id = t.booking_id
WHERE b.status = 'CONFIRMED';

-- A2.2 [Aggregate + CASE WHEN + JOIN]
-- คำถาม: แต่ละเส้นทางมีการจองสถานะใดบ้าง (ยืนยัน / รอชำระ / ยกเลิก) สรุปในแถวเดียว
SELECT
    ao.iata_code || '-' || ad.iata_code                             AS route,
    COUNT(DISTINCT b.booking_id)                                    AS bookings,
    COUNT(DISTINCT CASE WHEN b.status = 'CONFIRMED' THEN b.booking_id END) AS confirmed,
    COUNT(DISTINCT CASE WHEN b.status = 'PENDING'   THEN b.booking_id END) AS pending,
    COUNT(DISTINCT CASE WHEN b.status = 'CANCELLED' THEN b.booking_id END) AS cancelled
FROM bookings b
JOIN tickets t   ON t.booking_id = b.booking_id
JOIN flights f   ON f.flight_id = t.flight_id
JOIN airports ao ON ao.airport_id = f.origin_airport_id
JOIN airports ad ON ad.airport_id = f.destination_airport_id
GROUP BY ao.iata_code, ad.iata_code
ORDER BY bookings DESC;


-- #####################################################
-- หมวด 3: SQL Grouping Functions
-- #####################################################

-- A3.1 [GROUP BY ROLLUP + HAVING]
-- คำถาม: รายได้แยกตามเมืองปลายทางและชั้นโดยสาร พร้อมยอดรวมย่อย (แสดงเฉพาะกลุ่มที่รายได้เกิน 3,000 บาท)
SELECT
    COALESCE(destination_city, '== รวมทุกเมือง ==') AS destination_city,
    COALESCE(travel_class, '-- รวม --')            AS travel_class,
    COUNT(*)                                       AS tickets,
    SUM(price)                                     AS revenue
FROM v_flight_bookings
WHERE booking_status = 'CONFIRMED'
GROUP BY ROLLUP (destination_city, travel_class)
HAVING SUM(price) > 3000
ORDER BY destination_city NULLS LAST, travel_class NULLS LAST;

-- A3.2 [Window Function: RANK, SUM() OVER]
-- คำถาม: จัดอันดับเส้นทางตามรายได้ และแต่ละเส้นทางคิดเป็นกี่ % ของรายได้ทั้งหมด
SELECT
    route,
    revenue,
    RANK() OVER (ORDER BY revenue DESC)                     AS rank_no,
    ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)        AS share_pct,
    ROUND(100.0 * SUM(revenue) OVER (ORDER BY revenue DESC, route)
                / SUM(revenue) OVER (), 2)                  AS cumulative_pct
FROM v_route_revenue
ORDER BY rank_no;


-- #####################################################
-- หมวด 4: Statistical and Mathematical Functions
-- #####################################################

-- A4.1 [STDDEV, VARIANCE, PERCENTILE_CONT]
-- คำถาม: ราคาตั๋วชั้นประหยัดแต่ละเส้นทางผันผวนแค่ไหน (ราคาเปลี่ยนตามวันที่จอง)
SELECT
    ao.iata_code || '-' || ad.iata_code                              AS route,
    COUNT(*)                                                         AS tickets,
    f.base_price,
    ROUND(AVG(t.price), 2)                                           AS mean_price,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY t.price)             AS median_price,
    ROUND(STDDEV_SAMP(t.price), 2)                                   AS stddev_price,
    ROUND(VAR_SAMP(t.price), 2)                                      AS variance_price
FROM tickets t
JOIN flights f   ON f.flight_id = t.flight_id
JOIN airports ao ON ao.airport_id = f.origin_airport_id
JOIN airports ad ON ad.airport_id = f.destination_airport_id
WHERE t.travel_class = 'ECONOMY'
GROUP BY ao.iata_code, ad.iata_code, f.base_price
HAVING COUNT(*) >= 2
ORDER BY stddev_price DESC NULLS LAST;

-- A4.2 [CORR + การคำนวณวันล่วงหน้า]
-- คำถาม: ยิ่งจองล่วงหน้านาน ราคาถูกลงหรือไม่ (ความสัมพันธ์ระหว่างจำนวนวันล่วงหน้ากับราคาเทียบราคาฐาน)
SELECT
    COUNT(*)                                                                        AS tickets,
    ROUND(AVG(EXTRACT(EPOCH FROM (f.departure_time - b.booked_at)) / 86400), 1)     AS avg_days_in_advance,
    ROUND(CORR(EXTRACT(EPOCH FROM (f.departure_time - b.booked_at)) / 86400,
               t.price / f.base_price)::numeric, 4)                                 AS correlation,
    MODE() WITHIN GROUP (ORDER BY t.travel_class)                                   AS most_common_class
FROM tickets t
JOIN bookings b ON b.booking_id = t.booking_id
JOIN flights f  ON f.flight_id = t.flight_id
WHERE t.travel_class = 'ECONOMY';
