-- ============================================================
-- NB频道 - 用户名白名单（只能包含中文、字母、数字）
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 规则：用户名仅允许 [一-龥]（CJK基本区）+ [a-zA-Z] + [0-9]，
--       从根源上杜绝一切仿冒字符（希腊/西里尔/科普特/IPA/全角等）。
-- 覆盖：register_user（注册）、update_username（改名）。
-- register_user 保持 md5 内置函数方案（与 login_user 一致）。
-- ============================================================

-- ========== 1. 注册 ==========
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
    -- 清洗零宽/不可见字符
    clean_name := regexp_replace(
        input_username,
        '[' || chr(8203) || chr(8204) || chr(8205) || chr(8206) || chr(8207)
             || chr(65279) || chr(173) || chr(8288) || chr(12288) || chr(9)
             || chr(10) || chr(13) || chr(32) || ']',
        '', 'g'
    );
    clean_name := btrim(clean_name);

    -- 白名单：只允许中文（CJK基本区 一-龥）、字母、数字
    IF clean_name !~ ('^[' || chr(19968) || '-' || chr(40869) || 'a-zA-Z0-9]+$') THEN
        RAISE EXCEPTION '用户名只能包含中文、字母和数字';
    END IF;

    -- 长度限制（1~20字）
    IF length(clean_name) < 1 OR length(clean_name) > 20 THEN
        RAISE EXCEPTION '用户名长度需在 1~20 字之间';
    END IF;
    IF EXISTS (SELECT 1 FROM profiles WHERE username = clean_name) THEN
        RETURN NULL;
    END IF;

    -- 内置函数生成盐和哈希（不依赖 pgcrypto）
    new_salt := substr(md5(random()::text || clock_timestamp()::text), 1, 16);
    new_hash := md5(new_salt || input_password);

    INSERT INTO profiles (username, password_hash, salt)
    VALUES (clean_name, new_hash, new_salt)
    RETURNING id INTO new_id;

    RETURN new_id;
END;
$$;

-- ========== 2. 修改用户名 ==========
CREATE OR REPLACE FUNCTION public.update_username(user_id uuid, new_username text, old_password text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    stored_hash TEXT;
    stored_salt TEXT;
    clean_name TEXT;
BEGIN
    SELECT password_hash, salt INTO stored_hash, stored_salt
    FROM profiles
    WHERE id = user_id;
    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'message', '用户不存在');
    END IF;
    IF encode(sha256(concat(stored_salt, old_password)::bytea), 'hex') != stored_hash THEN
        RETURN json_build_object('success', false, 'message', '密码错误');
    END IF;

    -- 清洗零宽/不可见字符
    clean_name := regexp_replace(
        new_username,
        '[' || chr(8203) || chr(8204) || chr(8205) || chr(8206) || chr(8207)
             || chr(65279) || chr(173) || chr(8288) || chr(12288) || chr(9)
             || chr(10) || chr(13) || chr(32) || ']',
        '', 'g'
    );
    clean_name := btrim(clean_name);

    -- 白名单：只允许中文（CJK基本区 一-龥）、字母、数字
    IF clean_name !~ ('^[' || chr(19968) || '-' || chr(40869) || 'a-zA-Z0-9]+$') THEN
        RETURN json_build_object('success', false, 'message', '用户名只能包含中文、字母和数字');
    END IF;

    -- 长度限制（1~20字）
    IF length(clean_name) < 1 OR length(clean_name) > 20 THEN
        RETURN json_build_object('success', false, 'message', '用户名长度需在 1~20 字之间');
    END IF;
    IF EXISTS (SELECT 1 FROM profiles WHERE username = clean_name AND id != user_id) THEN
        RETURN json_build_object('success', false, 'message', '用户名已被占用');
    END IF;
    UPDATE profiles SET username = clean_name WHERE id = user_id;
    RETURN json_build_object('success', true, 'message', '用户名修改成功');
END;
$$;

-- ========== 3. 权限 ==========
GRANT EXECUTE ON FUNCTION public.register_user(text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.update_username(uuid, text, text) TO anon;
