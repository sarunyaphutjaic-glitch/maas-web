-- =====================================================
-- 08: ฟังก์ชันรัน SQL ที่ LLM สร้าง (ระบบ Chat วิธี B: Text-to-SQL)
--
-- ชั้นป้องกัน
--   1. ตรวจข้อความ: ต้องขึ้นต้นด้วย SELECT/WITH, คำสั่งเดียว, ไม่มีคำสั่งแก้ไขข้อมูล
--   2. ห้ามอ้างตารางจริงใน public และห้ามเข้า schema ระบบ → ใช้ได้เฉพาะ View
--   3. STABLE → PostgreSQL ไม่ยอมให้ INSERT/UPDATE/DELETE ภายในฟังก์ชันนี้
--      และ PostgREST รันฟังก์ชัน STABLE ใน transaction แบบ READ ONLY
--   4. SECURITY INVOKER → รันด้วยสิทธิ์ผู้ถาม RLS จึงยังบังคับใช้
--      (ผู้โดยสารถามได้เฉพาะข้อมูลของตัวเอง)
--   5. จำกัดเวลา 5 วินาที และไม่เกิน 100 แถว
-- =====================================================
-- ลบของเดิมก่อน เพราะเปลี่ยนชนิดผลลัพธ์จาก JSONB เป็น JSON (คงลำดับคอลัมน์ตาม SQL)
DROP FUNCTION IF EXISTS public.run_chat_query(TEXT);

CREATE OR REPLACE FUNCTION public.run_chat_query(p_sql TEXT)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
SET statement_timeout = '5s'
AS $$
DECLARE
    v_sql    TEXT := regexp_replace(trim(p_sql), ';\s*$', '');   -- ตัด ; ท้ายคำสั่ง
    v_lower  TEXT;
    v_ref    TEXT;
    v_result JSON;
BEGIN
    v_lower := lower(v_sql);

    IF v_lower !~ '^(select|with)\s' THEN
        RAISE EXCEPTION 'อนุญาตเฉพาะคำสั่ง SELECT เท่านั้น';
    END IF;

    IF position(';' IN v_sql) > 0 THEN
        RAISE EXCEPTION 'อนุญาตให้รันได้ครั้งละหนึ่งคำสั่งเท่านั้น';
    END IF;

    IF v_lower ~ '\m(insert|update|delete|merge|drop|alter|create|truncate|grant|revoke|copy|call|execute|vacuum|reindex|cluster|lock|listen|notify|refresh)\M' THEN
        RAISE EXCEPTION 'พบคำสั่งที่แก้ไขข้อมูลหรือโครงสร้าง ซึ่งไม่อนุญาต';
    END IF;

    IF v_lower ~ '(pg_|information_schema|\mauth\.|\mstorage\.|\mextensions\.|\mvault\.|dblink|lo_import|lo_export|set_config|current_setting)' THEN
        RAISE EXCEPTION 'ไม่อนุญาตให้เข้าถึงตารางหรือฟังก์ชันของระบบ';
    END IF;

    -- ชื่อที่ตามหลัง FROM / JOIN ต้องไม่ใช่ตารางจริง (ใช้ได้เฉพาะ View หรือ CTE)
    FOR v_ref IN
        SELECT (regexp_matches(v_lower, '\m(?:from|join)\s+(?:public\.)?([a-z_][a-z0-9_]*)', 'g'))[1]
    LOOP
        IF EXISTS (
            SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relname = v_ref AND c.relkind IN ('r', 'p', 'f')
        ) THEN
            RAISE EXCEPTION 'ไม่อนุญาตให้อ่านตาราง % โดยตรง ให้ใช้ View (v_...) แทน', v_ref;
        END IF;
    END LOOP;

    EXECUTE format(
        'SELECT COALESCE(json_agg(t), ''[]''::json) FROM (SELECT * FROM (%s) q LIMIT 100) t',
        v_sql
    ) INTO v_result;

    RETURN json_build_object('rows', v_result);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.run_chat_query(TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.run_chat_query(TEXT) TO authenticated;
