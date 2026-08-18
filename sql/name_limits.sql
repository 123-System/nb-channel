-- ============================================================
-- NB频道 - 用户名/公司名字数限制（不超过20字）
-- 在 Supabase SQL Editor 中执行
-- 覆盖：register_user（注册）、update_username（改名）、
--       register_company（注册公司）、admin_rename_company（后台改公司名）
-- ============================================================

-- ========== 1. 注册用户名（两参数版）加 20 字限制 ==========
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
BEGIN
    -- 用户名长度限制（1~20字）
    IF input_username IS NULL OR length(input_username) < 1 OR length(input_username) > 20 THEN
        RAISE EXCEPTION '用户名长度需在 1~20 字之间';
    END IF;
    IF EXISTS (SELECT 1 FROM profiles WHERE username = input_username) THEN
        RETURN NULL;
    END IF;
    new_salt := encode(gen_random_bytes(16), 'hex');
    new_hash := encode(sha256(concat(new_salt, input_password)::bytea), 'hex');
    INSERT INTO profiles (username, password_hash, salt)
    VALUES (input_username, new_hash, new_salt)
    RETURNING id INTO new_id;
    RETURN new_id;
END;
$$;

-- 补权限（防止 CREATE OR REPLACE 后 anon 无法调用导致 404）
GRANT EXECUTE ON FUNCTION public.register_user(text, text) TO anon;

-- ========== 2. 修改用户名（update_username）加 20 字限制 ==========
CREATE OR REPLACE FUNCTION public.update_username(user_id uuid, new_username text, old_password text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    stored_hash TEXT;
    stored_salt TEXT;
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
    -- 用户名长度限制（1~20字）
    IF new_username IS NULL OR length(new_username) < 1 OR length(new_username) > 20 THEN
        RETURN json_build_object('success', false, 'message', '用户名长度需在 1~20 字之间');
    END IF;
    IF EXISTS (SELECT 1 FROM profiles WHERE username = new_username AND id != user_id) THEN
        RETURN json_build_object('success', false, 'message', '用户名已被占用');
    END IF;
    UPDATE profiles SET username = new_username WHERE id = user_id;
    RETURN json_build_object('success', true, 'message', '用户名修改成功');
END;
$$;

-- ========== 3. 注册公司名加 20 字限制 ==========
CREATE OR REPLACE FUNCTION public.register_company(p_user_id uuid, p_company_name text, p_need_verify boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_is_verified_user BOOLEAN;
BEGIN
    -- 公司名称长度限制（1~20字）
    IF p_company_name IS NULL OR length(p_company_name) < 1 OR length(p_company_name) > 20 THEN
        RETURN jsonb_build_object('success', false, 'message', '公司名称需在 1~20 字之间');
    END IF;
    IF EXISTS (SELECT 1 FROM user_companies WHERE user_id = p_user_id) THEN
        RETURN jsonb_build_object('success', false, 'message', '您已经注册过公司');
    END IF;

    -- 检查用户是否是蓝标用户
    SELECT EXISTS (
        SELECT 1 FROM verified_users WHERE user_id = p_user_id
    ) INTO v_is_verified_user;

    IF v_is_verified_user THEN
        INSERT INTO user_companies (user_id, company_name, market_value, verified, verification_status)
        VALUES (p_user_id, p_company_name, 20000, true, 'approved');
        RETURN jsonb_build_object('success', true, 'message', '公司注册成功（已自动认证）', 'need_verify', false);
    END IF;

    IF p_need_verify THEN
        INSERT INTO user_companies (user_id, company_name, market_value, verified, verification_status)
        VALUES (p_user_id, p_company_name, 20000, false, 'pending');
        RETURN jsonb_build_object('success', true, 'message', '公司注册申请已提交，等待管理员审核', 'need_verify', true);
    ELSE
        INSERT INTO user_companies (user_id, company_name, market_value, verified, verification_status)
        VALUES (p_user_id, p_company_name, 20000, false, 'none');
        RETURN jsonb_build_object('success', true, 'message', '公司注册成功', 'need_verify', false);
    END IF;
END;
$$;

-- ========== 4. 后台重命名公司加 20 字限制（顺带） ==========
CREATE OR REPLACE FUNCTION public.admin_rename_company(company_id bigint, new_name text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF new_name IS NULL OR length(new_name) < 1 OR length(new_name) > 20 THEN
        RAISE EXCEPTION '公司名称需在 1~20 字之间';
    END IF;
    UPDATE user_companies SET company_name = new_name WHERE id = company_id;
    RETURN FOUND;
END;
$$;

-- 说明：三参数版 register_user（含 email）未改动（该版本依赖 email 列，当前表结构无此列，不应被使用）
