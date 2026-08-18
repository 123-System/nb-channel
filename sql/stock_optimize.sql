-- ============================================================
-- NB频道 - 虚拟股票波动规则 v2（±2% 波动 / 30秒节流 / 3%均值回归）
-- 在 Supabase SQL Editor 中执行（幂等）
-- 规则：
--   1) 波动幅度：每轮 -2% ~ +2%（对称）
--   2) 全局节流：stock_latest 30 秒内有更新则跳过本轮波动
--   3) 均值回归：每轮向"全市场平均市值"拉回 3%（防止两极分化）
--   4) 市值保底 10000 不变
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
        --    市值高于均值 → 往下拉；低于均值 → 往上提
        new_value := new_value + ((v_avg - new_value) * 0.03);

        -- ③ 最低市值保底 10000
        IF new_value < 10000 THEN new_value := 10000; END IF;

        UPDATE user_companies SET market_value = new_value WHERE id = company.id;
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.random_fluctuate_market_values() TO anon;

-- ========== 说明 ==========
-- 玩家行为（支持/买入）注入的资金会直接提高市值，不受均值回归影响（回归只作用于自然波动）。
-- 若要调整参数：±X% 改 (random()-0.5)*0.04 中的 0.04（=2*X%）；回归强度改 0.03；节流改 interval。
