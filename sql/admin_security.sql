-- ============================================================
-- NB频道 - 安全加固（管理后台鉴权）
-- 在 Supabase 后台 SQL Editor 中执行本文件
-- 功能：
--   1) 管理后台改用"服务端会话 token"鉴权（30分钟有效），不再信任前端 sessionStorage
--   2) 登录限频（同一 IP 10分钟内最多尝试 5 次）
--   3) 所有 admin_* 操作 RPC 增加 token 校验
--   4) 收紧 reports 表的 DELETE 权限（普通用户不能直接删举报）
-- ============================================================

-- ========== 1. 会话表 ==========
CREATE TABLE IF NOT EXISTS public.admin_sessions (
    token      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_admin_sessions_expires
    ON public.admin_sessions (expires_at);

ALTER TABLE public.admin_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_sessions FROM anon, authenticated;
-- 只有 SECURITY DEFINER 函数能访问该表

-- ========== 2. 登录尝试记录表（限频） ==========
CREATE TABLE IF NOT EXISTS public.admin_login_attempts (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ip_address text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_login_attempts_ip
    ON public.admin_login_attempts (ip_address, created_at);

ALTER TABLE public.admin_login_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_login_attempts FROM anon, authenticated;

-- ========== 3. RPC：admin_create_session（创建会话） ==========
-- 说明：内部复用你现有的 check_admin_password_plain(input_pwd) 校验密码。
-- 如果你的该函数返回的不是 boolean，执行本脚本会报类型错误，请把函数签名发给我调整。
CREATE OR REPLACE FUNCTION public.admin_create_session(p_pwd text, p_ip text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_ok      boolean;
    v_token   uuid;
    v_attempt integer;
BEGIN
    -- 限频：同一 IP 10分钟内最多 5 次尝试
    SELECT count(*) INTO v_attempt
      FROM public.admin_login_attempts
     WHERE ip_address = coalesce(p_ip, 'unknown')
       AND created_at > now() - interval '10 minutes';
    IF v_attempt >= 5 THEN
        RETURN jsonb_build_object('success', false, 'message', '尝试次数过多，请10分钟后再试');
    END IF;

    -- 校验密码（复用原函数）
    SELECT public.check_admin_password_plain(p_pwd) INTO v_ok;
    IF NOT coalesce(v_ok, false) THEN
        INSERT INTO public.admin_login_attempts (ip_address) VALUES (coalesce(p_ip, 'unknown'));
        RETURN jsonb_build_object('success', false, 'message', '密码错误');
    END IF;

    -- 密码正确：清空该 IP 的失败记录，创建 30 分钟会话
    DELETE FROM public.admin_login_attempts WHERE ip_address = coalesce(p_ip, 'unknown');

    v_token := gen_random_uuid();
    INSERT INTO public.admin_sessions (token, expires_at)
    VALUES (v_token, now() + interval '30 minutes');

    RETURN jsonb_build_object('success', true, 'token', v_token::text);
END;
$$;

-- ========== 4. RPC：admin_check_session（校验会话） ==========
CREATE OR REPLACE FUNCTION public.admin_check_session(p_token text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- 清理过期会话
    DELETE FROM public.admin_sessions WHERE expires_at < now();
    RETURN EXISTS (
        SELECT 1 FROM public.admin_sessions
        WHERE token::text = p_token AND expires_at > now()
    );
END;
$$;

-- ========== 5. 内部校验函数（供各操作 RPC 复用） ==========
CREATE OR REPLACE FUNCTION public._admin_token_valid(p_token text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DELETE FROM public.admin_sessions WHERE expires_at < now();
    RETURN EXISTS (
        SELECT 1 FROM public.admin_sessions
        WHERE token::text = p_token AND expires_at > now()
    );
END;
$$;

-- ========== 6. 改造操作类 RPC（增加 token 校验） ==========

-- 6.1 忽略举报
CREATE OR REPLACE FUNCTION public.admin_ignore_report(p_report_id bigint, p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('success', false, 'message', '登录已过期，请重新登录');
    END IF;
    DELETE FROM public.reports WHERE id = p_report_id;
    RETURN jsonb_build_object('success', true);
END;
$$;

-- 6.2 封禁用户
CREATE OR REPLACE FUNCTION public.admin_ban_user(p_user_id uuid, p_reason text, p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('success', false, 'message', '登录已过期，请重新登录');
    END IF;
    UPDATE public.profiles
       SET is_banned = true,
           banned_reason = coalesce(p_reason, '经管理员核实，违规操作')
     WHERE id = p_user_id;
    RETURN jsonb_build_object('success', true);
END;
$$;

-- 6.3 删除虚拟公司（保留原有清理逻辑：规则/举报/蓝标 + 新增股东持仓清理 + token 校验）
CREATE OR REPLACE FUNCTION public.admin_delete_company(p_company_id bigint, p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID;
    v_company_name TEXT;
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('success', false, 'message', '登录已过期，请重新登录');
    END IF;

    -- 查找公司
    SELECT user_id, company_name INTO v_user_id, v_company_name
    FROM public.user_companies
    WHERE id = p_company_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', format('公司 ID %s 不存在', p_company_id));
    END IF;

    -- 删除公司
    DELETE FROM public.user_companies WHERE id = p_company_id;
    -- 删除自动支持规则
    DELETE FROM public.support_rules WHERE company_id = p_company_id;
    -- 删除该公司的所有举报（target_type = 'company'）
    DELETE FROM public.reports WHERE company_id = p_company_id AND target_type = 'company';
    -- 删除蓝标
    DELETE FROM public.verified_users WHERE user_id = v_user_id;
    -- 清空该公司的股东持仓（股票作废）
    DELETE FROM public.holdings WHERE company_id = p_company_id;

    RETURN jsonb_build_object('success', true, 'message', format('公司「%s」已删除', v_company_name));
END;
$$;

-- 6.4 公司认证审核（approve / reject；保留原有 IF NOT EXISTS 蓝标逻辑 + token 校验）
CREATE OR REPLACE FUNCTION public.admin_verify_company(p_company_id bigint, p_approved boolean, p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID;
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('success', false, 'message', '登录已过期，请重新登录');
    END IF;

    SELECT user_id INTO v_user_id FROM user_companies WHERE id = p_company_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', '公司不存在');
    END IF;

    IF p_approved THEN
        UPDATE user_companies
           SET verified = true, verification_status = 'approved'
         WHERE id = p_company_id;
        -- 若用户尚未在 verified_users 中则添加（保留原逻辑）
        IF NOT EXISTS (SELECT 1 FROM verified_users WHERE user_id = v_user_id) THEN
            INSERT INTO verified_users (user_id) VALUES (v_user_id);
        END IF;
    ELSE
        UPDATE user_companies
           SET verified = false, verification_status = 'rejected'
         WHERE id = p_company_id;
        -- 删除蓝标
        DELETE FROM verified_users WHERE user_id = v_user_id;
    END IF;
    RETURN jsonb_build_object('success', true);
END;
$$;

-- ========== 7. 批量操作 RPC ==========
-- 7.1 批量忽略举报
CREATE OR REPLACE FUNCTION public.admin_batch_ignore(p_report_ids bigint[], p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('success', false, 'message', '登录已过期，请重新登录');
    END IF;
    DELETE FROM public.reports WHERE id = ANY(p_report_ids);
    RETURN jsonb_build_object('success', true, 'deleted', coalesce(array_length(p_report_ids, 1), 0));
END;
$$;

-- 7.2 批量删除评论（含其举报）
CREATE OR REPLACE FUNCTION public.admin_batch_delete_comments(p_comment_ids bigint[], p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('success', false, 'message', '登录已过期，请重新登录');
    END IF;
    DELETE FROM public.reports WHERE comment_id = ANY(p_comment_ids);
    DELETE FROM public.comment_reactions WHERE comment_id = ANY(p_comment_ids);
    DELETE FROM public.notifications WHERE source_comment_id = ANY(p_comment_ids);
    DELETE FROM public.comments WHERE id = ANY(p_comment_ids);
    RETURN jsonb_build_object('success', true, 'deleted', coalesce(array_length(p_comment_ids, 1), 0));
END;
$$;

-- 7.3 批量封禁用户
CREATE OR REPLACE FUNCTION public.admin_batch_ban_users(p_user_ids uuid[], p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('success', false, 'message', '登录已过期，请重新登录');
    END IF;
    UPDATE public.profiles
       SET is_banned = true, banned_reason = '经管理员核实，批量违规'
     WHERE id = ANY(p_user_ids);
    RETURN jsonb_build_object('success', true);
END;
$$;

-- 7.4 解封用户
CREATE OR REPLACE FUNCTION public.admin_unban_user(p_user_id uuid, p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('success', false, 'message', '登录已过期，请重新登录');
    END IF;
    UPDATE public.profiles
       SET is_banned = false, banned_reason = null
     WHERE id = p_user_id;
    RETURN jsonb_build_object('success', true);
END;
$$;

-- ========== 8. 权限 ==========
GRANT EXECUTE ON FUNCTION public.admin_create_session(text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_check_session(text) TO anon;
GRANT EXECUTE ON FUNCTION public._admin_token_valid(text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_ignore_report(bigint, text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_ban_user(uuid, text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_company(bigint, text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_verify_company(bigint, boolean, text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_batch_ignore(bigint[], text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_batch_delete_comments(bigint[], text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_batch_ban_users(uuid[], text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_unban_user(uuid, text) TO anon;

-- ========== 9. 收紧权限：普通用户不能直接删除举报/评论 ==========
REVOKE DELETE ON public.reports FROM anon;
REVOKE DELETE ON public.comments FROM anon;
REVOKE UPDATE, DELETE ON public.comments FROM anon;
-- 注意：评论的插入仍保留（评论区发评论用）；如需完全走 RPC 可再收紧。

-- ========== 10. 可选：清理历史过期会话 ==========
DELETE FROM public.admin_sessions WHERE expires_at < now();
