-- ============================================================
-- NB频道 - 波动节流修复 v6（恢复"页面开着时市场正常波动"）
-- 在 Supabase SQL Editor 中执行（幂等，可重复执行）
-- 背景：V0.7.3 把节流窗口改为 30 秒，但节流依据是 stock_latest（页面每10秒就写一次），
--       导致窗口永远被"刚写过"占住 → 页面开着时市场反而不波动。
-- 修复：节流依据改为专门的"上次波动时间"（market_meta.last_fluctuate），
--       访客（10秒/轮）与 Actions 定时任务（每5分钟）共用同一节流，互不冲突。
-- 节流窗口：8 秒（≈ 早期"10秒左右波动一次"的节奏），可自行改 interval '8 seconds'。
-- ============================================================

-- 1. 市场元信息表（只允许 SECURITY DEFINER 函数访问）
CREATE TABLE IF NOT EXISTS public.market_meta (
    key   text PRIMARY KEY,
    value text NOT NULL
);

ALTER TABLE public.market_meta ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.market_meta FROM anon, authenticated;

-- 2. 波动函数 v6：8 秒全局节流（依据 market_meta.last_fluctuate）
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
    -- 交易时段判断（北京时间）：8:00 开盘 ~ 20:00 收盘，收盘后停止波动（冻结）
    IF (now() AT TIME ZONE 'Asia/Shanghai')::time < time '08:00'
       OR (now() AT TIME ZONE 'Asia/Shanghai')::time >= time '20:00' THEN
        RETURN;
    END IF;

    -- 全局节流：8 秒内已波动过则跳过（依据 market_meta.last_fluctuate，页面/定时任务共用）
    SELECT value::timestamptz INTO v_last FROM public.market_meta WHERE key = 'last_fluctuate';
    IF v_last IS NOT NULL AND v_last > now() - interval '8 seconds' THEN
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

        -- 涨跌停冻结：相对当日开盘价超过 ±50% → 该公司停止波动（冻结）
        IF v_day_open IS NOT NULL THEN
            IF company.market_value > v_day_open * 1.50
               OR company.market_value < v_day_open * 0.50 THEN
                CONTINUE;  -- 跳过该公司，保持冻结，第二天开盘自动恢复
            END IF;
        END IF;

        -- ① 随机波动：-2% ~ +2%（对称）
        change_percent := (random() - 0.5) * 0.04;
        new_value := company.market_value + (company.market_value * change_percent);

        -- ② 均值回归：向市场平均值拉回 10%
        new_value := new_value + ((v_avg - new_value) * 0.1);

        -- ③ 涨跌停边界限制：波动后不得超出 [开盘价×0.5, 开盘价×1.5]
        IF v_day_open IS NOT NULL THEN
            IF new_value > v_day_open * 1.50 THEN
                new_value := floor(v_day_open * 1.50);
            ELSIF new_value < v_day_open * 0.50 THEN
                new_value := GREATEST(floor(v_day_open * 0.50), 10000);
            END IF;
        END IF;

        -- ④ 最低市值保底 10000
        IF new_value < 10000 THEN new_value := 10000; END IF;

        UPDATE user_companies SET market_value = new_value WHERE id = company.id;
    END LOOP;

    -- 记录本次波动时间（节流依据）
    INSERT INTO public.market_meta (key, value) VALUES ('last_fluctuate', now()::text)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$;

-- 3. 权限
GRANT EXECUTE ON FUNCTION public.random_fluctuate_market_values() TO anon;

-- 说明：
-- 节流窗口调整：改 interval '8 seconds' 即可（如 '15 seconds' / '30 seconds'）。
-- 交易时段 / 涨跌停 / 均值回归参数与 v5 一致，未改动。
