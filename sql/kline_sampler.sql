-- ============================================================
-- NB频道 - 全天自动采样（保证每天K线数据完整，含休市平线）
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 配套：.github/workflows/market_sample.yml 全天每5分钟执行一轮
--       "记录开盘价 → 全市场波动 → 采样快照"的完整市场循环
-- 功能：
--   1) sample_market_snapshot：全天采集全市场快照（不分交易时段），
--      写入 stock_history_full 并同步聚合当日K线 —— 不依赖访客打开页面；
--      交易时段记真实走势，休市时段记平线（市值冻结，值不变）
--   2) record_daily_kline 加固：trade_date 改用"北京时间日期"，
--      避免数据库时区导致凌晨时段写到前一天的行
--   3) 历史快照保留量 2000 → 5000
-- ============================================================

-- ========== 1. 采样函数 ==========
CREATE OR REPLACE FUNCTION public.sample_market_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_names  text[] := ARRAY[]::text[];
    v_values bigint[] := ARRAY[]::bigint[];
    v_total  bigint := 0;
    v_count  integer := 0;
    r RECORD;
BEGIN
    -- 全天采样（不再限制交易时段）：交易时段记真实走势，休市时段记平线
    FOR r IN SELECT company_name, market_value FROM public.user_companies ORDER BY id LOOP
        v_names  := v_names || r.company_name;
        v_values := v_values || r.market_value;
        v_total  := v_total + r.market_value;
        v_count  := v_count + 1;
    END LOOP;

    IF v_count = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '暂无公司');
    END IF;

    INSERT INTO public.stock_history_full (recorded_at, total_value, snapshot)
    VALUES (now(), v_total, jsonb_build_object('names', to_jsonb(v_names), 'values', to_jsonb(v_values)));

    -- 同步聚合当日K线（open 首次插入，close/high/low 逐步更新）
    PERFORM public.record_daily_kline();

    RETURN jsonb_build_object('success', true, 'companies', v_count, 'total', v_total);
END;
$$;

-- ========== 2. record_daily_kline 加固版（trade_date 用北京时间日期） ==========
CREATE OR REPLACE FUNCTION public.record_daily_kline()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r RECORD;
    v_date date := (now() AT TIME ZONE 'Asia/Shanghai')::date;
    v_company_count integer := 0;
    v_row_count integer;
BEGIN
    -- 逐公司 upsert 当日K线（trade_date = 北京时间日期）
    FOR r IN SELECT id, market_value FROM public.user_companies LOOP
        INSERT INTO public.stock_daily_kline AS k (company_id, trade_date, open, close, high, low, volume)
        VALUES (r.id, v_date, r.market_value, r.market_value, r.market_value, r.market_value, 0)
        ON CONFLICT (company_id, trade_date) DO UPDATE SET
            close = EXCLUDED.close,
            high  = GREATEST(k.high, EXCLUDED.high),
            low   = LEAST(k.low, EXCLUDED.low);
        v_company_count := v_company_count + 1;
    END LOOP;

    -- 成交量：按当天交易记录汇总（交易只发生在北京时间8:00-20:00，created_at::date 与北京时间日期一致）
    UPDATE public.stock_daily_kline k
       SET volume = COALESCE((
           SELECT SUM(COALESCE(t.total_amount, 0))::integer
             FROM public.transactions t
            WHERE t.company_id = k.company_id
              AND t.created_at::date = k.trade_date
       ), 0);
    GET DIAGNOSTICS v_row_count = ROW_COUNT;

    RAISE NOTICE 'record_daily_kline: 处理 % 家公司，更新成交量 % 行', v_company_count, v_row_count;
END;
$$;

-- ========== 3. 历史快照保留量提升（2000 → 5000，约7个交易日的完整数据） ==========
CREATE OR REPLACE FUNCTION public.delete_old_history_full()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    row_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO row_count FROM public.stock_history_full;
    IF row_count > 5000 THEN
        DELETE FROM public.stock_history_full
        WHERE recorded_at = (SELECT recorded_at FROM public.stock_history_full ORDER BY recorded_at ASC LIMIT 1);
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_clean_history_full ON public.stock_history_full;
CREATE TRIGGER trg_clean_history_full
AFTER INSERT ON public.stock_history_full
FOR EACH ROW EXECUTE FUNCTION public.delete_old_history_full();

-- ========== 4. 权限 ==========
GRANT EXECUTE ON FUNCTION public.sample_market_snapshot() TO anon;
GRANT EXECUTE ON FUNCTION public.record_daily_kline() TO anon;

-- 验证（可选，以 anon 身份手动触发一次采样）
-- SET ROLE anon;
-- SELECT sample_market_snapshot();
-- RESET ROLE;
-- 应返回 {"success": true, "companies": 54, "total": ...}（全天均可采样）
