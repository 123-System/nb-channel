-- ============================================================
-- NB频道 - 停用 pg_cron 波动方案（有锁问题），改用 Actions 长任务
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 原因：market_tick_loop 把 6 次波动 + pg_sleep 放在同一事务里，
--       行锁要等整个函数结束（最长60秒）才释放，导致访客的
--       random_fluctuate_market_values / support_company 等请求
--       排队等锁超过语句超时上限（57014 / 500 错误）。
-- 替代：.github/workflows/market_live.yml —— GitHub Actions 长任务
--       每个 tick 独立请求/独立事务，行锁即时释放。
-- ============================================================

-- 1. 停用 pg_cron 任务（任务不存在时忽略报错）
DO $$
BEGIN
    BEGIN
        PERFORM cron.unschedule('market-10s-tick');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END $$;

-- 2. 删除自循环函数
DROP FUNCTION IF EXISTS public.market_tick_loop();

-- 验证：SELECT * FROM cron.job; 应不再有 market-10s-tick
