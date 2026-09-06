-- ============================================================
-- api_logs.sql  API 访问日志(表 + 函数)
-- 用途:PythonAnywhere 后端把每次 /api/* 请求批量写入本表,
--       后台页(admin-api-logs.html)用管理员会话查询。
-- 执行:在 Supabase SQL Editor 整段运行一次即可。
-- 依赖:sql/admin_security.sql 中的 _admin_token_valid(p_token)
-- ============================================================

CREATE TABLE IF NOT EXISTS public.api_logs (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts       timestamptz NOT NULL DEFAULT now(),
    endpoint text NOT NULL,
    method   text NOT NULL DEFAULT 'GET',
    ip       text,
    status   smallint,
    ua       text
);

CREATE INDEX IF NOT EXISTS idx_api_logs_ts       ON public.api_logs (ts DESC);
CREATE INDEX IF NOT EXISTS idx_api_logs_ip       ON public.api_logs (ip);
CREATE INDEX IF NOT EXISTS idx_api_logs_endpoint ON public.api_logs (endpoint);
CREATE INDEX IF NOT EXISTS idx_api_logs_status   ON public.api_logs (status);

ALTER TABLE public.api_logs ENABLE ROW LEVEL SECURITY;
-- 不开放表的直接读写,一切经函数(写:后端批量 RPC;读:管理员会话函数)

-- ---------- 写入:后端批量落库(匿名可执行;参数为普通字段,不可注入) ----------
CREATE OR REPLACE FUNCTION public.log_api_requests(p_rows jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    INSERT INTO public.api_logs (endpoint, method, ip, status, ua)
    SELECT left((r ->> 'endpoint')::text, 200),
           COALESCE(NULLIF(left((r ->> 'method')::text, 10), ''), 'GET'),
           NULLIF(left((r ->> 'ip')::text, 60), ''),
           NULLIF((r ->> 'status')::text, '')::smallint,
           NULLIF(left((r ->> 'ua')::text, 200), '')
    FROM jsonb_array_elements(p_rows) AS r
    WHERE (r ->> 'endpoint') IS NOT NULL;
END $$;

-- ---------- 查询:日志明细 ----------
CREATE OR REPLACE FUNCTION public.admin_get_api_logs(
    p_token text,
    p_limit int DEFAULT 200,
    p_endpoint text DEFAULT NULL,
    p_ip text DEFAULT NULL,
    p_status int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_rows jsonb;
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('ok', false, 'message', '无效或过期的管理会话');
    END IF;
    SELECT jsonb_agg(x) INTO v_rows FROM (
        SELECT id,
               to_char(ts AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI:SS') AS ts,
               endpoint, method, ip, status, ua
        FROM public.api_logs
        WHERE (p_endpoint IS NULL OR endpoint LIKE '%' || p_endpoint || '%')
          AND (p_ip IS NULL OR ip = p_ip)
          AND (p_status IS NULL OR status = p_status)
        ORDER BY ts DESC, id DESC
        LIMIT GREATEST(1, LEAST(p_limit, 1000))
    ) x;
    RETURN jsonb_build_object('ok', true, 'rows', COALESCE(v_rows, '[]'::jsonb));
END $$;

-- ---------- 汇总:今日请求 / 429 / 端点 TOP / IP TOP ----------
CREATE OR REPLACE FUNCTION public.admin_api_log_summary(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_today int; v_429 int; v_total bigint;
    v_ep jsonb; v_ip jsonb; v_last text;
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('ok', false, 'message', '无效或过期的管理会话');
    END IF;
    SELECT count(*) INTO v_total FROM public.api_logs;
    SELECT count(*) INTO v_today FROM public.api_logs
        WHERE ts >= date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai';
    SELECT count(*) INTO v_429 FROM public.api_logs WHERE status = 429;
    SELECT jsonb_agg(x) INTO v_ep FROM (
        SELECT endpoint, count(*) AS n FROM public.api_logs
        GROUP BY endpoint ORDER BY n DESC LIMIT 12) x;
    SELECT jsonb_agg(x) INTO v_ip FROM (
        SELECT ip, count(*) AS n FROM public.api_logs
        WHERE ip IS NOT NULL GROUP BY ip ORDER BY n DESC LIMIT 12) x;
    SELECT to_char(max(ts) AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI:SS') INTO v_last FROM public.api_logs;
    RETURN jsonb_build_object('ok', true,
        'total', v_total, 'today', v_today, 'rate_limited', v_429,
        'endpoints', COALESCE(v_ep, '[]'::jsonb), 'ips', COALESCE(v_ip, '[]'::jsonb),
        'last', v_last);
END $$;

-- ---------- 清理:删除 N 天前的日志(默认保留 30 天) ----------
CREATE OR REPLACE FUNCTION public.admin_api_logs_purge(p_token text, p_keep_days int DEFAULT 30)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_deleted bigint;
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('ok', false, 'message', '无效或过期的管理会话');
    END IF;
    DELETE FROM public.api_logs
     WHERE ts < now() - make_interval(days => GREATEST(1, LEAST(p_keep_days, 365)));
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'deleted', v_deleted);
END $$;

-- ---------- 权限:函数对 anon 可执行(内部自行校验管理员会话) ----------
GRANT EXECUTE ON FUNCTION public.log_api_requests(jsonb) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_get_api_logs(text, int, text, text, int) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_api_log_summary(text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_api_logs_purge(text, int) TO anon;
