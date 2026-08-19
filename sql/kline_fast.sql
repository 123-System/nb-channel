-- ============================================================
-- NB频道 - K线图提速：服务器端提取单家公司采样点
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 背景：前端原来拉取全部快照（每条含所有公司，约15MB）再本地筛选，
--       切换公司很慢。本函数在数据库内只提取目标公司的时间+市值点，
--       传输量降到约 150KB（5000 个点）。
-- 返回：t = 采样时间（倒序），v = 该公司当时的市值
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_company_kline(p_company_id bigint)
RETURNS TABLE (t timestamptz, v bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_name text;
BEGIN
    SELECT company_name INTO v_name FROM public.user_companies WHERE id = p_company_id;
    IF v_name IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT h.recorded_at,
           ((h.snapshot->'values')->(h.pos - 1)::int)::text::bigint AS v
    FROM (
        SELECT h2.recorded_at, h2.snapshot,
               -- 找到该公司名在 names 数组中的位置（1 基），每行独立计算，
               -- 公司改名/增删后位置漂移也能正确对应
               array_position(
                   ARRAY(SELECT jsonb_array_elements_text(h2.snapshot->'names')),
                   v_name
               ) AS pos
          FROM public.stock_history_full h2
    ) h
    WHERE h.pos IS NOT NULL
    ORDER BY h.recorded_at DESC;
END;
$$;

-- 权限（前端 anon 可调用）
GRANT EXECUTE ON FUNCTION public.get_company_kline(bigint) TO anon;

-- 验证（可选，替换成实际公司ID）：
-- SELECT * FROM public.get_company_kline(1) LIMIT 5;
