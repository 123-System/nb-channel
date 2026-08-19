-- ============================================================
-- NB频道 - 波动函数 v7（移除均值回归）
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 与 v6 的区别：删除"向全市场平均市值拉回 10%"的均值回归逻辑
--               （连带删除平均市值计算），波动 = 纯 ±2% 随机游走。
-- 保留：交易时段(8:00-20:00)、market_meta 8秒节流、
--       ±50% 涨跌停冻结与边界钳制、10000 保底。
-- 注意：无均值回归后行情会更"野"，涨跌停出现频率会比以前高（属预期）。
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
    v_day_open NUMERIC;
    v_last timestamptz;
BEGIN
    -- 交易时段判断（北京时间）：8:00 开盘 ~ 20:00 收盘，收盘后停止波动（冻结）
    IF (now() AT TIME ZONE 'Asia/Shanghai')::time < time '08:00'
       OR (now() AT TIME ZONE 'Asia/Shanghai')::time >= time '20:00' THEN
        RETURN;
    END IF;

    -- 全局节流：8 秒内已波动过则跳过（页面/定时任务共用）
    SELECT value::timestamptz INTO v_last FROM public.market_meta WHERE key = 'last_fluctuate';
    IF v_last IS NOT NULL AND v_last > now() - interval '8 seconds' THEN
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

        -- 随机波动：-2% ~ +2%（对称，纯随机游走，无均值回归）
        change_percent := (random() - 0.5) * 0.04;
        new_value := company.market_value + (company.market_value * change_percent);

        -- 涨跌停边界限制：波动后不得超出 [开盘价×0.5, 开盘价×1.5]
        IF v_day_open IS NOT NULL THEN
            IF new_value > v_day_open * 1.50 THEN
                new_value := floor(v_day_open * 1.50);
            ELSIF new_value < v_day_open * 0.50 THEN
                new_value := GREATEST(floor(v_day_open * 0.50), 10000);
            END IF;
        END IF;

        -- 最低市值保底 10000
        IF new_value < 10000 THEN new_value := 10000; END IF;

        UPDATE user_companies SET market_value = new_value WHERE id = company.id;
    END LOOP;

    -- 记录本次波动时间（节流依据）
    INSERT INTO public.market_meta (key, value) VALUES ('last_fluctuate', now()::text)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$;

-- 权限
GRANT EXECUTE ON FUNCTION public.random_fluctuate_market_values() TO anon;
