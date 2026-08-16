-- ============================================================
-- NB频道 - 日K线数据表（大智慧式）
-- 设计：每天每家公司一行（open/close/high/low/volume），
--       由 record_daily_kline() 在保存快照时增量聚合，
--       历史自然积累，K线图直接读这张轻量表。
-- ============================================================

-- ========== 1. 日K线表 ==========
CREATE TABLE IF NOT EXISTS public.stock_daily_kline (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id bigint NOT NULL,
    trade_date date NOT NULL,
    open       integer NOT NULL,   -- 当日首次市值
    close      integer NOT NULL,   -- 当日最后市值
    high       integer NOT NULL,   -- 当日最高市值
    low        integer NOT NULL,   -- 当日最低市值
    volume     integer NOT NULL DEFAULT 0,  -- 当日成交额（NB币，从 transactions 聚合）
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (company_id, trade_date)
);

COMMENT ON TABLE public.stock_daily_kline IS '虚拟股票日K线（大智慧式：开高低收+成交量）';

CREATE INDEX IF NOT EXISTS idx_kline_company_date
    ON public.stock_daily_kline (company_id, trade_date);

-- RLS：匿名可读（K线图查询），写入只走 RPC
ALTER TABLE public.stock_daily_kline ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS kline_read_all ON public.stock_daily_kline;
CREATE POLICY kline_read_all ON public.stock_daily_kline
    FOR SELECT TO anon USING (true);
REVOKE INSERT, UPDATE, DELETE ON public.stock_daily_kline FROM anon;

-- ========== 2. record_daily_kline：增量聚合当天K线 ==========
-- 由前端 saveFullSnapshot 时调用（每次刷新市场数据后）。
-- 幂等：当天已有记录则更新 close/high/low/volume，否则新建（open=当前市值）。
CREATE OR REPLACE FUNCTION public.record_daily_kline()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r RECORD;
    v_date date := current_date;
BEGIN
    FOR r IN SELECT id, market_value FROM public.user_companies LOOP
        INSERT INTO public.stock_daily_kline (company_id, trade_date, open, close, high, low, volume)
        VALUES (r.id, v_date, r.market_value, r.market_value, r.market_value, r.market_value, 0)
        ON CONFLICT (company_id, trade_date) DO UPDATE SET
            close = EXCLUDED.close,
            high  = GREATEST(public.stock_daily_kline.high, EXCLUDED.high),
            low   = LEAST(public.stock_daily_kline.low, EXCLUDED.low);
    END LOOP;

    -- 成交量：按当天交易记录汇总（buy/sell 的 total_amount 之和）
    UPDATE public.stock_daily_kline k
       SET volume = COALESCE((
           SELECT SUM(t.total_amount)::integer
             FROM public.transactions t
            WHERE t.company_id = k.company_id
              AND t.created_at::date = k.trade_date
       ), 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_daily_kline() TO anon;

-- ========== 3. 说明 ==========
-- K线图查询直接读本表（anon SELECT 已授权）：
--   SELECT trade_date, open, close, high, low, volume
--   FROM stock_daily_kline WHERE company_id = X ORDER BY trade_date;
-- 旧 stock_history_full 仍用于"市值走势图"，不受影响。
