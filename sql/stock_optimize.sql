-- ============================================================
-- NB频道 - 虚拟股票波动规则 v4（±2% / 30秒 / 3%回归 / 涨跌停±30%冻结）
-- 在 Supabase SQL Editor 中执行（幂等）
-- 规则：
--   1) 波动幅度：每轮 -2% ~ +2%（对称）
--   2) 全局节流：stock_latest 30 秒内有更新则跳过本轮波动
--   3) 均值回归：每轮向"全市场平均市值"拉回 3%
--   4) 涨跌停：以当日开盘价（stock_daily_kline.open）为基准，
--      上下 ±30% 空间；整体涨跌超过 ±30% 的公司的【波动被冻结】
--      （不再参与波动），第二天开盘（open 更新）后自动恢复波动
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
        -- 当日开盘价基准
        SELECT open INTO v_day_open
          FROM public.stock_daily_kline
         WHERE company_id = company.id AND trade_date = current_date;

        -- 涨跌停冻结：相对当日开盘价超过 ±30% → 该公司停止波动（冻结）
        IF v_day_open IS NOT NULL THEN
            IF company.market_value > v_day_open * 1.30
               OR company.market_value < v_day_open * 0.70 THEN
                CONTINUE;  -- 跳过该公司，保持冻结，第二天开盘自动恢复
            END IF;
        END IF;

        -- ① 随机波动：-2% ~ +2%（对称）
        change_percent := (random() - 0.5) * 0.04;
        new_value := company.market_value + (company.market_value * change_percent);

        -- ② 均值回归：向市场平均值拉回 3%
        new_value := new_value + ((v_avg - new_value) * 0.03);

        -- ③ 涨跌停边界限制：波动后不得超出 [开盘价×0.7, 开盘价×1.3]
        IF v_day_open IS NOT NULL THEN
            IF new_value > v_day_open * 1.30 THEN
                new_value := floor(v_day_open * 1.30);
            ELSIF new_value < v_day_open * 0.70 THEN
                new_value := GREATEST(floor(v_day_open * 0.70), 10000);
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
-- 冻结期间玩家支持/买入仍可改变市值（直接操作，不经波动函数），与真实"资金推动"一致。
-- 参数调整：幅度改 0.04；回归强度改 0.03；涨跌停空间改 1.30 / 0.70。
