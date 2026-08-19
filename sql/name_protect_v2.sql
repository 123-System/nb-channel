-- ============================================================
-- NB频道 - 名字仿冒防护 v2（拦截科普特等更多仿冒字母）
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 背景：有账号用"科普特字母 Ⲃ (U+2C82)"冒充 B 注册成功（如"小NⲂ"），
--       旧规则只拦希腊/西里尔/全角，漏了科普特等仿冒块。
-- v2 新增拦截：科普特、IPA、修饰字母、音标扩展、希腊扩展、
--              西里尔补充、字母符号、数学字母数字符号。
-- register_user 保持 md5 内置函数方案（与 login_user 一致，不依赖 pgcrypto）。
-- ============================================================

-- ========== 1. 注册（含扩展仿冒拦截） ==========
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

    -- 拒绝仿冒字符：希腊/西里尔/西里尔补充/IPA/修饰字母/音标扩展/希腊扩展/
    --              字母符号/科普特/数学字母数字/全角字母（如 Ⲃ Β В 𝐁 冒充 B）
    IF clean_name ~ ('[' || chr(880)   || '-' || chr(1279)
                     || chr(1280)  || '-' || chr(1327)
                     || chr(592)   || '-' || chr(687)
                     || chr(688)   || '-' || chr(767)
                     || chr(7424)  || '-' || chr(7551)
                     || chr(7936)  || '-' || chr(8191)
                     || chr(8448)  || '-' || chr(8527)
                     || chr(11392) || '-' || chr(11519)
                     || chr(119808)|| '-' || chr(120831)
                     || chr(65313) || '-' || chr(65338)
                     || chr(65345) || '-' || chr(65370)
                     || ']') THEN
        RAISE EXCEPTION '用户名包含仿冒字符（希腊/西里尔/科普特/全角等仿冒字母），请使用中文、英文和数字';
    END IF;

    -- 长度限制（1~20字）
    IF clean_name IS NULL OR length(clean_name) < 1 OR length(clean_name) > 20 THEN
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

-- ========== 2. 修改用户名（含扩展仿冒拦截） ==========
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

    -- 拒绝仿冒字符（同注册）
    IF clean_name ~ ('[' || chr(880)   || '-' || chr(1279)
                     || chr(1280)  || '-' || chr(1327)
                     || chr(592)   || '-' || chr(687)
                     || chr(688)   || '-' || chr(767)
                     || chr(7424)  || '-' || chr(7551)
                     || chr(7936)  || '-' || chr(8191)
                     || chr(8448)  || '-' || chr(8527)
                     || chr(11392) || '-' || chr(11519)
                     || chr(119808)|| '-' || chr(120831)
                     || chr(65313) || '-' || chr(65338)
                     || chr(65345) || '-' || chr(65370)
                     || ']') THEN
        RETURN json_build_object('success', false, 'message', '用户名包含仿冒字符（希腊/西里尔/科普特/全角等仿冒字母），请使用中文、英文和数字');
    END IF;

    -- 长度限制（1~20字）
    IF clean_name IS NULL OR length(clean_name) < 1 OR length(clean_name) > 20 THEN
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
