-- ============================================================
-- NB频道 - 交易时段内"约每10秒波动一次"（无人访问也生效）
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 原理：GitHub Actions 定时最小粒度为 1 分钟，无法做到 10 秒；
--       改用数据库内置 pg_cron：每分钟唤醒一次 market_tick_loop()，
--       函数内循环 6 次 × pg_sleep(10) = 60 秒，每 10 秒波动一轮。
--       配合 random_fluctuate_market_values 自带的 8 秒节流，即使轮次重叠也安全。
-- 效果：交易时段（北京时间 8:00-20:00）内，无论有没有人看股票页面，
--       市场都保持约每 10 秒波动一次；休市时段函数直接返回，不空转。
-- 备注：Actions 的 5 分钟循环保留（采样 + 兜底），不受影响。
-- ============================================================

-- 1. 启用 pg_cron（若这里报错，请到 Dashboard → Database → Extensions 里启用 pg_cron）
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 2. 数据库内自循环函数：交易时段内每 10 秒波动一次
CREATE OR REPLACE FUNCTION public.market_tick_loop()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    i integer;
BEGIN
    -- 非交易时段（北京时间 8:00 前 / 20:00 后）直接返回，不空转
    IF (now() AT TIME ZONE 'Asia/Shanghai')::time < time '08:00'
       OR (now() AT TIME ZONE 'Asia/Shanghai')::time >= time '20:00' THEN
        RETURN;
    END IF;

    -- 6 次 × 10 秒 = 60 秒，正好覆盖 pg_cron 的每分钟唤醒
    FOR i IN 1..6 LOOP
        PERFORM public.random_fluctuate_market_values();
        PERFORM pg_sleep(10);
    END LOOP;
END;
$$;

-- 3. 注册每分钟任务（先删旧任务再建，保证幂等）
DO $$
BEGIN
    BEGIN
        PERFORM cron.unschedule('market-10s-tick');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END $$;

SELECT cron.schedule('market-10s-tick', '* * * * *', 'SELECT public.market_tick_loop()');

-- ============================================================
-- 验证：
-- 1) SELECT * FROM cron.job;           -- 应能看到 market-10s-tick
-- 2) SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;  -- 每分钟一条执行记录
-- 3) 交易时段内打开股票页面，观察市值变化节奏 ≈ 每 10 秒一次
-- 4) 想改频率：改第 2 步的 6（次数）和 pg_sleep(10)（秒数），
--    例如每 30 秒一次 → 2 次 × pg_sleep(30)
-- 5) 想停用：SELECT cron.unschedule('market-10s-tick');
-- ============================================================
