-- ============================================================
-- NB频道 - record_daily_kline 防御加固版
-- 修复：部分环境下 ON CONFLICT 更新引用写法可能异常
-- 在 Supabase SQL Editor 中执行（幂等，可重复执行）
-- ============================================================

CREATE OR REPLACE FUNCTION public.record_daily_kline()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r RECORD;
    v_date date := current_date;
    v_company_count integer := 0;
    v_row_count integer;
BEGIN
    -- 逐公司 upsert 当日K线（使用表别名 k，避免歧义）
    FOR r IN SELECT id, market_value FROM public.user_companies LOOP
        INSERT INTO public.stock_daily_kline AS k (company_id, trade_date, open, close, high, low, volume)
        VALUES (r.id, v_date, r.market_value, r.market_value, r.market_value, r.market_value, 0)
        ON CONFLICT (company_id, trade_date) DO UPDATE SET
            close = EXCLUDED.close,
            high  = GREATEST(k.high, EXCLUDED.high),
            low   = LEAST(k.low, EXCLUDED.low);
        v_company_count := v_company_count + 1;
    END LOOP;

    -- 成交量：按当天交易记录汇总（防 NULL）
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

GRANT EXECUTE ON FUNCTION public.record_daily_kline() TO anon;

-- 验证（以 anon 身份执行一次，看是否报错）
-- SET ROLE anon;
-- SELECT record_daily_kline();
-- RESET ROLE;
-- 若输出 NOTICE: record_daily_kline: 处理 54 家公司... 即正常
