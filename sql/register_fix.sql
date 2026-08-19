-- ============================================================
-- NB频道 - 注册函数修复（404 问题）
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 原因：register_user 曾被重建为依赖 pgcrypto 扩展的版本
--       （gen_random_bytes / sha256），而数据库未启用 pgcrypto，
--       导致调用时 PostgREST 返回 404。
-- 修复：删除所有 register_user 重载，重建为"仅用 PostgreSQL 内置函数"
--       （md5 / random / clock_timestamp）的版本，保留 20 字限制、
--       零宽字符清洗、仿冒字符拒绝；哈希方案与 login_user 一致
--       （salt + md5），不影响已有账号登录。
-- ============================================================

-- 1. 删除所有 register_user 重载（两参数版、三参数版等）
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS sig
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'register_user'
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig;
    END LOOP;
END $$;

-- 2. 重建注册函数（仅内置函数，不依赖 pgcrypto）
CREATE OR REPLACE FUNCTION public.register_user(input_username text, input_password text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    new_salt TEXT;
    new_hash TEXT;
    new_id UUID;
    clean_name TEXT;
BEGIN
    -- 清洗零宽/不可见字符（含全角空格等，防伪装同名账号）
    clean_name := regexp_replace(
        input_username,
        '[' || chr(8203) || chr(8204) || chr(8205) || chr(8206) || chr(8207)
             || chr(65279) || chr(173) || chr(8288) || chr(12288) || chr(9)
             || chr(10) || chr(13) || chr(32) || ']',
        '', 'g'
    );
    clean_name := btrim(clean_name);

    -- 拒绝仿冒字符：希腊字母 / 西里尔字母 / 全角字母（如 Β 冒充 B、а 冒充 a）
    IF clean_name ~ ('[' || chr(880) || '-' || chr(1279) || chr(65313) || '-' || chr(65338) || chr(65345) || '-' || chr(65370) || ']') THEN
        RAISE EXCEPTION '用户名包含仿冒字符（希腊/西里尔/全角字母），请使用中文、英文和数字';
    END IF;

    -- 用户名长度限制（1~20字，按清洗后计算）
    IF clean_name IS NULL OR length(clean_name) < 1 OR length(clean_name) > 20 THEN
        RAISE EXCEPTION '用户名长度需在 1~20 字之间';
    END IF;
    IF EXISTS (SELECT 1 FROM profiles WHERE username = clean_name) THEN
        RETURN NULL;
    END IF;

    -- 用内置函数生成盐和哈希（不依赖 pgcrypto，避免 404）
    new_salt := substr(md5(random()::text || clock_timestamp()::text), 1, 16);
    new_hash := md5(new_salt || input_password);

    INSERT INTO profiles (username, password_hash, salt)
    VALUES (clean_name, new_hash, new_salt)
    RETURNING id INTO new_id;

    RETURN new_id;
END;
$$;

-- 3. 补权限（anon 可调用）
GRANT EXECUTE ON FUNCTION public.register_user(text, text) TO anon;

-- 验证：SELECT public.register_user('测试用户123', 'test123456');
-- 返回一个 uuid 即成功；重复执行会返回 NULL（用户名已存在）。
