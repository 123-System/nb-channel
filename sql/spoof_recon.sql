-- ============================================================
-- NB频道 - 侦察：找出注册IP记录表 + 两个冒充号的IP
-- 在 Supabase SQL Editor 中执行，把输出结果发我
-- ============================================================

-- 1) 先看 can_register / record_registration 的函数定义（确认用哪张表）
SELECT p.proname, pg_get_functiondef(p.oid) AS def
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('can_register', 'record_registration');

-- 2) 找出所有带 IP 列的表，并打印每个表最近 10 条记录
DO $$
DECLARE
    t text;
    r record;
    v_cnt integer;
BEGIN
    FOR t IN
        SELECT DISTINCT table_name
          FROM information_schema.columns
         WHERE table_schema = 'public'
           AND column_name IN ('ip', 'ip_address', 'client_ip', 'register_ip')
    LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', t) INTO v_cnt;
        RAISE NOTICE '===== 表: % (共 % 条) =====', t, v_cnt;
        FOR r IN EXECUTE format('SELECT * FROM public.%I ORDER BY 1 DESC LIMIT 10', t)
        LOOP
            RAISE NOTICE '  %', r::text;
        END LOOP;
    END LOOP;
END $$;

-- 3) 两个冒充号的基本信息（确认 ID）
SELECT id, username, created_at FROM public.profiles
WHERE username = 'NB公司'
   OR username ~ ('[' || chr(11392) || '-' || chr(11519) || ']');
