-- =====================================================================
-- View ข้ามระบบ (ใช้ตารางกลาง users + payments เชื่อมทั้ง 3 โมดูล)
-- รันหลัง 10_airline_all.sql และ 20_bus_all.sql
-- ใช้ในการนำเสนอส่วนกลุ่ม: "ฐานข้อมูลที่รวมจากสมาชิกทุกคน"
-- =====================================================================

-- ค่าใช้จ่ายของผู้ใช้แต่ละคน แยกตามโหมดการเดินทาง (นับเฉพาะที่ชำระสำเร็จ)
CREATE OR REPLACE VIEW v_user_spending
WITH (security_invoker = true) AS
SELECT
    u.user_id,
    u.full_name,
    COALESCE(SUM(p.amount) FILTER (WHERE p.service_type = 'RAIL_TOPUP'), 0) AS rail_topup,
    COALESCE(SUM(p.amount) FILTER (WHERE p.service_type = 'FLIGHT'), 0)     AS flight,
    COALESCE(SUM(p.amount) FILTER (WHERE p.service_type = 'BUS'), 0)        AS bus,
    COALESCE(SUM(p.amount), 0)                                              AS total_spent,
    COUNT(DISTINCT p.service_type)                                          AS modes_used
FROM users u
LEFT JOIN payments p ON p.user_id = u.user_id AND p.status = 'PAID'
GROUP BY u.user_id, u.full_name;

-- สรุปการชำระเงินรายเดือนแยกตามบริการและช่องทาง
CREATE OR REPLACE VIEW v_payment_summary
WITH (security_invoker = true) AS
SELECT
    date_trunc('month', paid_at AT TIME ZONE 'Asia/Bangkok')::date AS month,
    service_type,
    method,
    COUNT(*)                                                       AS transactions,
    SUM(amount)                                                    AS total_amount
FROM payments
WHERE status = 'PAID'
GROUP BY 1, 2, 3;
