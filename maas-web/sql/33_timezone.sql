-- =====================================================================
-- 33: กำหนด Timezone เป็นเวลาไทย (Asia/Bangkok, UTC+07:00)
--
-- นโยบายเวลาของระบบ
--   1) ทุกคอลัมน์เวลาใช้ TIMESTAMPTZ (timestamp with time zone) ไม่ใช้ TIMESTAMP เปล่า
--      PostgreSQL เก็บค่าเป็นจุดเวลาเดียวกันทั่วโลก (ภายในเป็น UTC) จึงไม่กำกวม
--   2) เวลาที่บันทึกเข้าระบบระบุ +07 เสมอ เช่น '2026-11-14 07:00:00+07'
--   3) การแสดงผลใช้เวลาไทย: ตั้งค่า timezone ของฐานข้อมูลเป็น Asia/Bangkok
--      และใน View ที่ต้องได้วันที่/ชั่วโมงไทย ใช้  เวลา AT TIME ZONE 'Asia/Bangkok'
--   4) หน้าเว็บแปลงด้วย toLocaleString('th-TH', { timeZone: 'Asia/Bangkok' })
--      และส่งเวลาเข้าระบบในรูปแบบ YYYY-MM-DDTHH:mm:00+07:00
-- =====================================================================

-- ฐานข้อมูลและ role ที่หน้าเว็บใช้ แสดงเวลาเป็นเวลาไทย (มีผลกับการเชื่อมต่อใหม่)
ALTER DATABASE postgres SET timezone TO 'Asia/Bangkok';
ALTER ROLE authenticated SET timezone TO 'Asia/Bangkok';
ALTER ROLE anon          SET timezone TO 'Asia/Bangkok';
SET timezone TO 'Asia/Bangkok';    -- การเชื่อมต่อปัจจุบัน

-- คำอธิบายคอลัมน์เวลา (เห็นใน Supabase Table Editor)
COMMENT ON COLUMN users.created_at        IS 'TIMESTAMPTZ · แสดงผลเป็นเวลาไทย Asia/Bangkok (+07)';
COMMENT ON COLUMN payments.paid_at        IS 'TIMESTAMPTZ · แสดงผลเป็นเวลาไทย Asia/Bangkok (+07)';
COMMENT ON COLUMN chat_logs.created_at    IS 'TIMESTAMPTZ · แสดงผลเป็นเวลาไทย Asia/Bangkok (+07)';
COMMENT ON COLUMN cards.issued_at         IS 'TIMESTAMPTZ · แสดงผลเป็นเวลาไทย Asia/Bangkok (+07)';
COMMENT ON COLUMN gate_logs.entry_time    IS 'TIMESTAMPTZ · เวลาแตะบัตรเข้า (เวลาไทย +07)';
COMMENT ON COLUMN gate_logs.exit_time     IS 'TIMESTAMPTZ · เวลาแตะบัตรออก (เวลาไทย +07)';
COMMENT ON COLUMN card_topups.topped_up_at IS 'TIMESTAMPTZ · แสดงผลเป็นเวลาไทย Asia/Bangkok (+07)';
COMMENT ON COLUMN flights.departure_time  IS 'TIMESTAMPTZ · เวลาออกตามเวลาไทย (+07)';
COMMENT ON COLUMN flights.arrival_time    IS 'TIMESTAMPTZ · เวลาถึงตามเวลาไทย (+07)';
COMMENT ON COLUMN bookings.booked_at      IS 'TIMESTAMPTZ · แสดงผลเป็นเวลาไทย Asia/Bangkok (+07)';
COMMENT ON COLUMN bus_schedules.departure_time IS 'TIMESTAMPTZ · เวลาออกตามแผน (เวลาไทย +07)';
COMMENT ON COLUMN trip_logs.actual_departure   IS 'TIMESTAMPTZ · เวลาออกจริง (เวลาไทย +07)';
COMMENT ON COLUMN trip_logs.actual_arrival     IS 'TIMESTAMPTZ · เวลาถึงจริง (เวลาไทย +07)';
COMMENT ON COLUMN bus_rides.boarded_at    IS 'TIMESTAMPTZ · เวลาขึ้นรถ (เวลาไทย +07)';

-- ตรวจผล: ต้องได้ Asia/Bangkok และเวลาปัจจุบันลงท้าย +07
SELECT current_setting('TimeZone') AS timezone, now() AS now_thai;
