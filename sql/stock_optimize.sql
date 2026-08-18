-- ============================================================
-- NB频道 - 虚拟股票波动规则 v3（±2% / 30秒 / 3%回归 / 涨跌停±10%）
-- 在 Supabase SQL Editor 中执行（幂等）
-- 规则：
--   1) 波动幅度：每轮 -2% ~ +2%（对称）
--   2) 全局节流：stock_latest 30 秒内有更新则跳过本轮波动
--   3) 均值回归：每轮向"全市场平均市值"拉回 3%
--   4) 涨跌停：以当日首次市值（stock_daily_kline.open）为基准，
--      当日累计涨跌限制在 ±10% 内（涨停/跌停后自然波动被卡住，
--      但玩家支持/买入注入的资金不受限——推高的公司照常波动）
--   5) 市值保底 10000 不变
-- ============================================================

CREATE OR REPLACE FUNCTION public.random_fluctuate_market_values()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    company RECORD;
    change_percent FLOAT;
    new_value BIGINT;
    v_avg NUMERIC;
    v_day_open NUMERIC;
    v_last timestamptz;
BEGIN
    -- 全局节流：stock_latest 30 秒内有更新则跳过本轮波动
    SELECT max(created_at) INTO v_last FROM public.stock_latest;
    IF v_last IS NOT NULL AND v_last > now() - interval '30 seconds' THEN
        RETURN;
    END IF;

    -- 全市场平均市值（均值回归的锚点）
    SELECT AVG(market_value) INTO v_avg FROM public.user_companies;
    IF v_avg IS NULL THEN
        RETURN;
    END IF;

    FOR company IN SELECT id, market_value FROM user_companies LOOP
        -- ① 随机波动：-2% ~ +2%（对称）
        change_percent := (random() - 0.5) * 0.04;
        new_value := company.market_value + (company.market_value * change_percent);

        -- ② 均值回归：向市场平均值拉回 3%
        new_value := new_value + ((v_avg - new_value) * 0.03);

        -- ③ 涨跌停：当日累计 ±10%（以当日 open 为基准）
        --    仅当"当前市值还在涨跌停区间内"时生效；
        --    被玩家支持/买入推超 10% 的公司不受限（玩家资金不消失）
        SELECT open INTO v_day_open
          FROM public.stock_daily_kline
         WHERE company_id = company.id AND trade_date = current_date;
        IF v_day_open IS NOT NULL
           AND company.market_value <= floor(v_day_open * 1.10)
           AND company.market_value >= floor(v_day_open * 0.90) THEN
            IF new_value > floor(v_day_open * 1.10) THEN
                new_value := floor(v_day_open * 1.10);   -- 涨停封板
            ELSIF new_value < floor(v_day_open * 0.90) THEN
                new_value := GREATEST(floor(v_day_open * 0.90), 10000);  -- 跌停封板
            END IF;
        END IF;

        -- ④ 最低市值保底 10000
        IF new_value < 10000 THEN new_value := 10000; END IF;

        UPDATE user_companies SET market_value = new_value WHERE id = company.id;
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.random_fluctuate_market_values() TO anon;

-- ========== 说明 ==========
-- 涨跌停基准 = stock_daily_kline 当天的 open（首次快照市值），由 record_daily_kline 维护。
-- 若当天还没有快照（v_day_open IS NULL），涨跌停自动跳过。
-- 参数调整：幅度改 0.04；回归强度改 0.03；涨跌停改 1.10 / 0.90。
