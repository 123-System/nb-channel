-- ============================================================
-- NB频道 - 修复破产功能（外键约束）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 原因：破产删除公司时，transactions 等表的外键（无级联）阻止删除
-- 修复：所有引用 user_companies 的外键改为 ON DELETE CASCADE
-- ============================================================

-- 0. 【可选先查】哪些表引用了 user_companies
-- SELECT tc.table_name, kcu.column_name, tc.constraint_name
--   FROM information_schema.table_constraints tc
--   JOIN information_schema.key_column_usage kcu
--     ON tc.constraint_name = kcu.constraint_name AND tc.table_name = kcu.table_name
--  WHERE tc.constraint_type = 'FOREIGN KEY'
--    AND tc.constraint_name IN (
--        SELECT con.conname FROM pg_constraint con
--        WHERE con.confrelid = 'public.user_companies'::regclass AND con.contype = 'f'
--    );

-- 1. 动态把所有引用 user_companies 的外键改为 ON DELETE CASCADE
DO $$
DECLARE
    r     record;
    v_col text;
BEGIN
    FOR r IN
        SELECT tc.constraint_name, tc.table_name
        FROM information_schema.table_constraints tc
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND tc.constraint_name IN (
              SELECT con.conname FROM pg_constraint con
              WHERE con.confrelid = 'public.user_companies'::regclass AND con.contype = 'f'
          )
    LOOP
        SELECT kcu.column_name INTO v_col
        FROM information_schema.key_column_usage kcu
        WHERE kcu.constraint_name = r.constraint_name AND kcu.table_name = r.table_name
        LIMIT 1;
        EXECUTE format('ALTER TABLE %I DROP CONSTRAINT %I', r.table_name, r.constraint_name);
        EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES public.user_companies(id) ON DELETE CASCADE',
                       r.table_name, r.constraint_name, v_col);
        RAISE NOTICE '已改为CASCADE: %.%', r.table_name, r.constraint_name;
    END LOOP;
END $$;
