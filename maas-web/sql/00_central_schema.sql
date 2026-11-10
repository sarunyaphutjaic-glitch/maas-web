-- =====================================================
-- MaaS Group — Central Tables (รันไฟล์นี้ก่อนทุกไฟล์)
-- ตาราง: users, locations, payments, chat_logs
-- ผู้รับผิดชอบ: สมาชิกคนที่ 2
-- =====================================================

-- 1. ผู้ใช้กลางของทุกระบบ (เครื่องบิน / BTS / รถเมล์)
--    auth_id เป็น NULL ได้ → ใส่ข้อมูลจำลองได้โดยไม่ต้องสมัคร Supabase Auth ทุกคน
--    ผู้ใช้ที่สมัครผ่านเว็บจะมี auth_id ผูกกับ auth.users
CREATE TABLE IF NOT EXISTS users (
    user_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    auth_id     UUID UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
    full_name   VARCHAR(100) NOT NULL,
    email       VARCHAR(150) NOT NULL UNIQUE,
    phone       VARCHAR(20),
    role        VARCHAR(20)  NOT NULL DEFAULT 'passenger',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT chk_users_role CHECK (role IN ('passenger', 'staff', 'admin'))
);

-- 2. จุดที่ตั้งกลาง ใช้เชื่อม airports / stations / bus_stops
--    แต่ละโมดูลเก็บ location_id (FK) ไว้ในตารางของตัวเอง
CREATE TABLE IF NOT EXISTS locations (
    location_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    location_name  VARCHAR(150) NOT NULL,
    location_type  VARCHAR(20)  NOT NULL,
    latitude       NUMERIC(9, 6) NOT NULL,
    longitude      NUMERIC(9, 6) NOT NULL,
    district       VARCHAR(100),
    CONSTRAINT chk_location_type CHECK (location_type IN ('AIRPORT', 'RAIL_STATION', 'BUS_STOP')),
    CONSTRAINT chk_latitude  CHECK (latitude  BETWEEN -90  AND 90),
    CONSTRAINT chk_longitude CHECK (longitude BETWEEN -180 AND 180)
);

-- 3. การชำระเงินกลาง
--    ตารางของแต่ละโมดูลอ้างกลับมาที่ payment_id (เช่น bookings, card_topups)
--    ตารางกลางจึงไม่ต้องรู้จักตารางของโมดูลใด → แยกพัฒนากันได้
CREATE TABLE IF NOT EXISTS payments (
    payment_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       BIGINT        NOT NULL,
    service_type  VARCHAR(20)   NOT NULL,
    amount        NUMERIC(10, 2) NOT NULL,
    method        VARCHAR(20)   NOT NULL,
    status        VARCHAR(20)   NOT NULL DEFAULT 'PAID',
    paid_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT fk_payments_user
        FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE RESTRICT,
    CONSTRAINT chk_payment_amount  CHECK (amount > 0),
    CONSTRAINT chk_service_type    CHECK (service_type IN ('FLIGHT', 'RAIL_TOPUP', 'BUS')),
    CONSTRAINT chk_payment_method  CHECK (method IN ('CREDIT_CARD', 'QR', 'CASH', 'MOBILE_BANKING')),
    CONSTRAINT chk_payment_status  CHECK (status IN ('PENDING', 'PAID', 'REFUNDED', 'FAILED'))
);

-- 4. ประวัติการสนทนาในหน้า Chat (Bonus)
CREATE TABLE IF NOT EXISTS chat_logs (
    chat_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id        BIGINT,                       -- NULL ได้: กรณีไม่ทราบผู้ถาม
    question       TEXT         NOT NULL,
    generated_sql  TEXT,                         -- NULL ได้: กรณีถูกปฏิเสธก่อนสร้าง SQL
    answer         TEXT,
    row_count      INT,
    status         VARCHAR(20)  NOT NULL,
    llm_model      VARCHAR(50),
    latency_ms     INT,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT fk_chat_user
        FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE SET NULL,
    CONSTRAINT chk_chat_status CHECK (status IN ('SUCCESS', 'ERROR', 'REJECTED')),
    CONSTRAINT chk_row_count   CHECK (row_count IS NULL OR row_count >= 0)
);

CREATE INDEX IF NOT EXISTS idx_payments_user     ON payments(user_id);
CREATE INDEX IF NOT EXISTS idx_payments_paid_at  ON payments(paid_at);
CREATE INDEX IF NOT EXISTS idx_locations_type    ON locations(location_type);
CREATE INDEX IF NOT EXISTS idx_chat_logs_user    ON chat_logs(user_id);
