-- ============================================================
-- ban_api_ip.sql
-- 1) API 汇总单独统计"官网自用"(/api/bili-fans)
-- 2) 后台封禁/解封 IP(复用全站 banned_ips 表;封禁后该 IP 的
--    /api/* 请求会被 PythonAnywhere 后端拒绝,全站评论区等也受限)
-- 执行:在 Supabase SQL Editor 整段运行一次
-- ============================================================

-- ---------- 汇总:官网自用单独统计 ----------
CREATE OR REPLACE FUNCTION public.admin_api_log_summary(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_today int; v_429 int; v_total bigint; v_fans bigint;
    v_ep jsonb; v_ip jsonb; v_last text;
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('ok', false, 'message', '无效或过期的管理会话');
    END IF;
    SELECT count(*) INTO v_total FROM public.api_logs;
    SELECT count(*) INTO v_today FROM public.api_logs
        WHERE ts >= date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai';
    SELECT count(*) INTO v_429 FROM public.api_logs WHERE status = 429;
    SELECT count(*) INTO v_fans FROM public.api_logs WHERE endpoint = '/api/bili-fans';
    SELECT jsonb_agg(x) INTO v_ep FROM (
        SELECT endpoint, count(*) AS n FROM public.api_logs
        WHERE endpoint <> '/api/bili-fans'
        GROUP BY endpoint ORDER BY n DESC LIMIT 12) x;
    SELECT jsonb_agg(x) INTO v_ip FROM (
        SELECT ip, count(*) AS n FROM public.api_logs
        WHERE ip IS NOT NULL GROUP BY ip ORDER BY n DESC LIMIT 12) x;
    SELECT to_char(max(ts) AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI:SS') INTO v_last FROM public.api_logs;
    RETURN jsonb_build_object('ok', true,
        'total', v_total, 'today', v_today, 'rate_limited', v_429,
        'fans_total', v_fans,
        'endpoints', COALESCE(v_ep, '[]'::jsonb), 'ips', COALESCE(v_ip, '[]'::jsonb),
        'last', v_last);
END $$;

-- ---------- 封禁 IP(upsert 到全站 banned_ips) ----------
CREATE OR REPLACE FUNCTION public.admin_ban_api_ip(p_ip text, p_reason text, p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_exist int;
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('success', false, 'message', '登录已过期，请重新登录');
    END IF;
    IF p_ip IS NULL OR length(trim(p_ip)) < 7 THEN
        RETURN jsonb_build_object('success', false, 'message', 'IP 无效');
    END IF;
    SELECT count(*) INTO v_exist FROM public.banned_ips WHERE ip = trim(p_ip);
    IF v_exist > 0 THEN
        UPDATE public.banned_ips SET reason = COALESCE(NULLIF(p_reason, ''), reason)
        WHERE ip = trim(p_ip);
        RETURN jsonb_build_object('success', true, 'message', '该 IP 已在封禁名单,已更新原因');
    END IF;
    INSERT INTO public.banned_ips (ip, reason)
    VALUES (trim(p_ip), COALESCE(NULLIF(p_reason, ''), 'API 频繁访问/疑似爬虫'));
    RETURN jsonb_build_object('success', true, 'message', 'IP 已封禁(API 与全站访问均受限)');
END $$;

-- ---------- 解封 IP ----------
CREATE OR REPLACE FUNCTION public.admin_unban_api_ip(p_ip text, p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_deleted int;
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('success', false, 'message', '登录已过期，请重新登录');
    END IF;
    DELETE FROM public.banned_ips WHERE ip = trim(p_ip);
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    IF v_deleted = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '该 IP 不在封禁名单');
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'IP 已解封');
END $$;

-- ---------- 封禁名单 ----------
CREATE OR REPLACE FUNCTION public.admin_list_banned_api_ips(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_rows jsonb;
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('ok', false, 'message', '无效或过期的管理会话');
    END IF;
    SELECT jsonb_agg(x) INTO v_rows FROM (
        SELECT id, ip, reason, to_char(created_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI:SS') AS created_at
        FROM public.banned_ips ORDER BY id DESC LIMIT 200) x;
    RETURN jsonb_build_object('ok', true, 'rows', COALESCE(v_rows, '[]'::jsonb));
END $$;

GRANT EXECUTE ON FUNCTION public.admin_ban_api_ip(text, text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_unban_api_ip(text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_list_banned_api_ips(text) TO anon;
