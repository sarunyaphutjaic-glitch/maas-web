-- =====================================================
-- Module 2: BTS/MRT Ticketing & Fare System
-- ตาราง: lines, stations, station_sequences, card_types, cards,
--        fare_tables, gate_logs, card_topups
-- ต้องรัน 00_central_schema.sql ก่อน (อ้าง users, locations, payments)
-- ผู้รับผิดชอบ: สมาชิกคนที่ 2
-- =====================================================

-- 1. สายรถไฟฟ้า
CREATE TABLE IF NOT EXISTS lines (
    line_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    line_name  VARCHAR(100) NOT NULL UNIQUE,
    code       VARCHAR(10)  NOT NULL UNIQUE
);

-- 2. สถานี (1 สถานี = 1 location ในตารางกลาง)
--    ไม่มี line_id แล้ว เพราะสถานีร่วม เช่น สยาม อยู่ได้หลายสาย → ย้ายไป station_sequences
CREATE TABLE IF NOT EXISTS stations (
    station_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    station_code  VARCHAR(10)  NOT NULL UNIQUE,      -- เช่น CEN, E1, S2
    station_name  VARCHAR(100) NOT NULL,
    location_id   BIGINT       NOT NULL UNIQUE,
    CONSTRAINT fk_stations_location
        FOREIGN KEY (location_id) REFERENCES locations(location_id) ON DELETE RESTRICT
);

-- 3. ลำดับสถานีในแต่ละสาย (M:N ระหว่าง lines และ stations)
CREATE TABLE IF NOT EXISTS station_sequences (
    line_id      BIGINT NOT NULL,
    station_id   BIGINT NOT NULL,
    sequence_no  INT    NOT NULL,
    PRIMARY KEY (line_id, station_id),
    CONSTRAINT fk_seq_line
        FOREIGN KEY (line_id) REFERENCES lines(line_id) ON DELETE CASCADE,
    CONSTRAINT fk_seq_station
        FOREIGN KEY (station_id) REFERENCES stations(station_id) ON DELETE CASCADE,
    CONSTRAINT uq_line_seq UNIQUE (line_id, sequence_no),   -- ห้ามลำดับซ้ำในสายเดียวกัน
    CONSTRAINT chk_sequence_no CHECK (sequence_no > 0)
);

-- 4. ประเภทบัตร (แยกออกมาจาก CHECK เดิม → ตัวอย่าง Normalization 3NF)
CREATE TABLE IF NOT EXISTS card_types (
    card_type_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    type_name      VARCHAR(20)  NOT NULL UNIQUE,     -- Adult, Student, Senior
    discount_rate  NUMERIC(4, 2) NOT NULL DEFAULT 0, -- 0.10 = ลด 10%
    CONSTRAINT chk_discount_rate CHECK (discount_rate BETWEEN 0 AND 1)
);

-- 5. บัตรโดยสาร (แทน passengers เดิม — ข้อมูลบุคคลย้ายไป users กลาง)
CREATE TABLE IF NOT EXISTS cards (
    card_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       BIGINT         NOT NULL,
    card_type_id  BIGINT         NOT NULL,
    card_number   VARCHAR(20)    NOT NULL UNIQUE,
    balance       NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    status        VARCHAR(20)    NOT NULL DEFAULT 'ACTIVE',
    issued_at     TIMESTAMPTZ    NOT NULL DEFAULT now(),
    CONSTRAINT fk_cards_user
        FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE RESTRICT,
    CONSTRAINT fk_cards_type
        FOREIGN KEY (card_type_id) REFERENCES card_types(card_type_id) ON DELETE RESTRICT,
    CONSTRAINT chk_balance     CHECK (balance >= 0),
    CONSTRAINT chk_card_status CHECK (status IN ('ACTIVE', 'BLOCKED', 'EXPIRED'))
);

-- 6. ตารางค่าโดยสาร (ราคาฐานสำหรับบัตร Adult)
CREATE TABLE IF NOT EXISTS fare_tables (
    fare_id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    origin_station_id       BIGINT        NOT NULL,
    destination_station_id  BIGINT        NOT NULL,
    base_fare               NUMERIC(6, 2) NOT NULL,
    CONSTRAINT fk_fare_origin
        FOREIGN KEY (origin_station_id) REFERENCES stations(station_id) ON DELETE CASCADE,
    CONSTRAINT fk_fare_destination
        FOREIGN KEY (destination_station_id) REFERENCES stations(station_id) ON DELETE CASCADE,
    CONSTRAINT chk_base_fare      CHECK (base_fare >= 0),
    CONSTRAINT chk_fare_diff_stn  CHECK (origin_station_id <> destination_station_id),
    CONSTRAINT uq_fare_pair UNIQUE (origin_station_id, destination_station_id)
);

-- 7. บันทึกการแตะบัตรเข้า-ออก (เดิมชื่อ tap_logs)
CREATE TABLE IF NOT EXISTS gate_logs (
    log_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    card_id           BIGINT        NOT NULL,
    entry_station_id  BIGINT        NOT NULL,
    exit_station_id   BIGINT,                     -- NULL ได้: ยังไม่แตะออก
    entry_time        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    exit_time         TIMESTAMPTZ,                -- NULL ได้: ยังไม่แตะออก
    fare_charged      NUMERIC(6, 2) NOT NULL DEFAULT 0,
    status            VARCHAR(20)   NOT NULL DEFAULT 'IN_JOURNEY',
    CONSTRAINT fk_gate_card
        FOREIGN KEY (card_id) REFERENCES cards(card_id) ON DELETE RESTRICT,   -- ไม่ให้ประวัติรายได้หาย
    CONSTRAINT fk_gate_entry
        FOREIGN KEY (entry_station_id) REFERENCES stations(station_id),
    CONSTRAINT fk_gate_exit
        FOREIGN KEY (exit_station_id) REFERENCES stations(station_id),
    CONSTRAINT chk_fare_charged     CHECK (fare_charged >= 0),
    CONSTRAINT chk_gate_status      CHECK (status IN ('IN_JOURNEY', 'COMPLETED', 'CANCELLED')),
    CONSTRAINT chk_exit_after_entry CHECK (exit_time IS NULL OR exit_time >= entry_time),
    -- COMPLETED ต้องมีสถานีและเวลาขาออกครบ
    CONSTRAINT chk_completed_has_exit CHECK (
        status <> 'COMPLETED' OR (exit_station_id IS NOT NULL AND exit_time IS NOT NULL)
    )
);

-- 8. การเติมเงินบัตร (เชื่อม cards ↔ payments กลาง)
CREATE TABLE IF NOT EXISTS card_topups (
    topup_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    card_id       BIGINT         NOT NULL,
    payment_id    BIGINT         NOT NULL UNIQUE,   -- 1 การชำระ = 1 การเติมเงิน
    amount        NUMERIC(10, 2) NOT NULL,
    topped_up_at  TIMESTAMPTZ    NOT NULL DEFAULT now(),
    CONSTRAINT fk_topup_card
        FOREIGN KEY (card_id) REFERENCES cards(card_id) ON DELETE RESTRICT,
    CONSTRAINT fk_topup_payment
        FOREIGN KEY (payment_id) REFERENCES payments(payment_id) ON DELETE RESTRICT,
    CONSTRAINT chk_topup_amount CHECK (amount > 0)
);

-- Index สำหรับ FK ที่ใช้ JOIN บ่อย
CREATE INDEX IF NOT EXISTS idx_seq_station        ON station_sequences(station_id);
CREATE INDEX IF NOT EXISTS idx_cards_user         ON cards(user_id);
CREATE INDEX IF NOT EXISTS idx_cards_type         ON cards(card_type_id);
CREATE INDEX IF NOT EXISTS idx_fare_destination   ON fare_tables(destination_station_id);
CREATE INDEX IF NOT EXISTS idx_gate_card          ON gate_logs(card_id);
CREATE INDEX IF NOT EXISTS idx_gate_entry         ON gate_logs(entry_station_id);
CREATE INDEX IF NOT EXISTS idx_gate_exit          ON gate_logs(exit_station_id);
CREATE INDEX IF NOT EXISTS idx_gate_entry_time    ON gate_logs(entry_time);
CREATE INDEX IF NOT EXISTS idx_topup_card         ON card_topups(card_id);
