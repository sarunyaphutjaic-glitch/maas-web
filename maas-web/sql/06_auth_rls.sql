-- =====================================================
-- 06: เชื่อม Supabase Auth กับตาราง users + RLS Policies
-- รันหลัง 05_views_bts.sql
-- =====================================================

-- -----------------------------------------------------
-- 1. เมื่อมีคนสมัครสมาชิก (auth.users) → สร้างแถวใน users อัตโนมัติ
--    ถ้าอีเมลตรงกับผู้ใช้ในข้อมูลจำลองที่ยังไม่มีบัญชี → ผูกบัญชีเข้ากับแถวเดิม (ใช้ทดสอบ/เดโม)
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.users
       SET auth_id = NEW.id
     WHERE email = NEW.email AND auth_id IS NULL;

    IF NOT FOUND THEN
        INSERT INTO public.users (auth_id, full_name, email, phone, role)
        VALUES (
            NEW.id,
            COALESCE(NULLIF(NEW.raw_user_meta_data ->> 'full_name', ''), split_part(NEW.email, '@', 1)),
            NEW.email,
            NULLIF(NEW.raw_user_meta_data ->> 'phone', ''),
            'passenger'                       -- สมัครเองได้แค่ passenger เสมอ
        );
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

-- -----------------------------------------------------
-- 2. ฟังก์ชันช่วยสำหรับ Policy
--    SECURITY DEFINER → อ่าน users ได้โดยไม่ติด RLS ของ users เอง (กันวนลูป)
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.app_user_id()
RETURNS BIGINT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT user_id FROM public.users WHERE auth_id = auth.uid() $$;

CREATE OR REPLACE FUNCTION public.app_role()
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT role FROM public.users WHERE auth_id = auth.uid() $$;

-- -----------------------------------------------------
-- 3. ตารางข้อมูลอ้างอิง: ทุกคนที่ login อ่านได้, admin แก้ไขได้
-- -----------------------------------------------------
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['locations','lines','stations','station_sequences','card_types','fare_tables'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_admin', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)', t || '_read', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                        USING (public.app_role() = ''admin'') WITH CHECK (public.app_role() = ''admin'')',
                       t || '_admin', t);
    END LOOP;
END $$;

-- -----------------------------------------------------
-- 4. users: เห็นแถวของตัวเอง, staff/admin เห็นทุกคน, admin แก้ไขได้
--    (ผู้ใช้ทั่วไปแก้แถวตัวเองไม่ได้ ป้องกันการเปลี่ยน role ตัวเองเป็น admin)
-- -----------------------------------------------------
DROP POLICY IF EXISTS users_read  ON users;
DROP POLICY IF EXISTS users_admin ON users;
CREATE POLICY users_read ON users FOR SELECT TO authenticated
    USING (auth_id = auth.uid() OR public.app_role() IN ('staff', 'admin'));
CREATE POLICY users_admin ON users FOR ALL TO authenticated
    USING (public.app_role() = 'admin') WITH CHECK (public.app_role() = 'admin');

-- -----------------------------------------------------
-- 5. cards: เจ้าของเห็นบัตรตัวเอง, staff เห็นและแก้สถานะได้, admin จัดการทั้งหมด
-- -----------------------------------------------------
DROP POLICY IF EXISTS cards_read        ON cards;
DROP POLICY IF EXISTS cards_staff_update ON cards;
DROP POLICY IF EXISTS cards_admin       ON cards;
CREATE POLICY cards_read ON cards FOR SELECT TO authenticated
    USING (user_id = public.app_user_id() OR public.app_role() IN ('staff', 'admin'));
CREATE POLICY cards_staff_update ON cards FOR UPDATE TO authenticated
    USING (public.app_role() = 'staff') WITH CHECK (public.app_role() = 'staff');
CREATE POLICY cards_admin ON cards FOR ALL TO authenticated
    USING (public.app_role() = 'admin') WITH CHECK (public.app_role() = 'admin');

-- -----------------------------------------------------
-- 6. gate_logs: เจ้าของบัตรเห็นประวัติตัวเอง, staff แก้สถานะได้, admin จัดการทั้งหมด
-- -----------------------------------------------------
DROP POLICY IF EXISTS gate_logs_read         ON gate_logs;
DROP POLICY IF EXISTS gate_logs_staff_update ON gate_logs;
DROP POLICY IF EXISTS gate_logs_admin        ON gate_logs;
CREATE POLICY gate_logs_read ON gate_logs FOR SELECT TO authenticated
    USING (public.app_role() IN ('staff', 'admin')
           OR card_id IN (SELECT card_id FROM cards WHERE user_id = public.app_user_id()));
CREATE POLICY gate_logs_staff_update ON gate_logs FOR UPDATE TO authenticated
    USING (public.app_role() = 'staff') WITH CHECK (public.app_role() = 'staff');
CREATE POLICY gate_logs_admin ON gate_logs FOR ALL TO authenticated
    USING (public.app_role() = 'admin') WITH CHECK (public.app_role() = 'admin');

-- -----------------------------------------------------
-- 7. payments / card_topups: เจ้าของเห็นของตัวเอง, admin จัดการทั้งหมด
-- -----------------------------------------------------
DROP POLICY IF EXISTS payments_read  ON payments;
DROP POLICY IF EXISTS payments_admin ON payments;
CREATE POLICY payments_read ON payments FOR SELECT TO authenticated
    USING (user_id = public.app_user_id() OR public.app_role() = 'admin');
CREATE POLICY payments_admin ON payments FOR ALL TO authenticated
    USING (public.app_role() = 'admin') WITH CHECK (public.app_role() = 'admin');

DROP POLICY IF EXISTS card_topups_read  ON card_topups;
DROP POLICY IF EXISTS card_topups_admin ON card_topups;
CREATE POLICY card_topups_read ON card_topups FOR SELECT TO authenticated
    USING (public.app_role() = 'admin'
           OR card_id IN (SELECT card_id FROM cards WHERE user_id = public.app_user_id()));
CREATE POLICY card_topups_admin ON card_topups FOR ALL TO authenticated
    USING (public.app_role() = 'admin') WITH CHECK (public.app_role() = 'admin');

-- -----------------------------------------------------
-- 8. chat_logs: เห็นและบันทึกของตัวเอง, admin เห็นทั้งหมด
-- -----------------------------------------------------
DROP POLICY IF EXISTS chat_logs_read   ON chat_logs;
DROP POLICY IF EXISTS chat_logs_insert ON chat_logs;
CREATE POLICY chat_logs_read ON chat_logs FOR SELECT TO authenticated
    USING (user_id = public.app_user_id() OR public.app_role() = 'admin');
CREATE POLICY chat_logs_insert ON chat_logs FOR INSERT TO authenticated
    WITH CHECK (user_id = public.app_user_id());
