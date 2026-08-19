-- ============================================================
-- NB频道 - 波动自循环 v2（PROCEDURE + 每轮 COMMIT，解决行锁问题）
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 说明：
--   v1（函数 + pg_sleep）的问题：6 次波动与 pg_sleep 在同一事务里，
--   行锁要等整个函数结束（最长60秒）才释放，访客请求排队等锁 → 57014/500。
--   v2 改为存储过程：每波动一轮立即 COMMIT 释放行锁，再 sleep，
--   访客的波动/交易请求随时能拿到锁；同时把采样也挪进来：
--     交易时段（8:00-20:00）每 10 秒波动一次 + 每 15 分钟采样一次
--     休市时段      每分钟检查一次，每 60 分钟采样一次（平线）
--   Actions 仅保留每小时备份采样，私有仓库免费额度(2000分钟/月)够用。
-- ============================================================

-- 1. 停用旧的 pg_cron 任务并删除旧函数（不存在时忽略报错）
DO $$
BEGIN
    BEGIN
        PERFORM cron.unschedule('market-10s-tick');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END $$;

DROP FUNCTION IF EXISTS public.market_tick_loop();

-- 2. 自循环存储过程（每轮 COMMIT 释放行锁）
CREATE OR REPLACE PROCEDURE public.market_tick_loop()
LANGUAGE plpgsql
AS $$
DECLARE
    i integer;
    v_bjt time;
    v_in_session boolean;
    v_last_sample timestamptz;
    v_threshold interval;
BEGIN
    -- 循环总时长约 60 秒，先解除本会话的语句超时限制
    SET statement_timeout = 0;

    v_bjt := (now() AT TIME ZONE 'Asia/Shanghai')::time;
    v_in_session := v_bjt >= time '08:00' AND v_bjt < time '20:00';

    -- 采样节流：交易时段 15 分钟一次，休市时段 60 分钟一次
    SELECT value::timestamptz INTO v_last_sample FROM public.market_meta WHERE key = 'last_sample';
    v_threshold := CASE WHEN v_in_session THEN interval '15 minutes' ELSE interval '60 minutes' END;
    IF v_last_sample IS NULL OR v_last_sample <= now() - v_threshold THEN
        PERFORM public.sample_market_snapshot();
        INSERT INTO public.market_meta (key, value) VALUES ('last_sample', now()::text)
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
        COMMIT;  -- 采样行锁立即释放
    END IF;

    -- 交易时段：每 10 秒波动一轮，每轮 COMMIT 释放行锁
    IF v_in_session THEN
        FOR i IN 1..6 LOOP
            PERFORM public.random_fluctuate_market_values();
            COMMIT;              -- 关键：行锁立即释放，访客请求不再被堵
            IF i < 6 THEN
                PERFORM pg_sleep(10);
            END IF;
        END LOOP;
    END IF;
END;
$$;

-- 3. 注册每分钟任务（CALL 存储过程）
SELECT cron.schedule('market-10s-tick', '* * * * *', 'CALL public.market_tick_loop()');

-- ============================================================
-- 验证：
-- 1) SELECT * FROM cron.job;               → 有 market-10s-tick
-- 2) SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;
--    正常应显示 status='Succeeded'；若 status='Failed' 且错误含
--    "invalid transaction termination"，说明 pg_cron 不支持过程内 COMMIT，
--    把报错发我，我会降级为"每分钟波动一次"的备选方案。
-- 3) 交易时段内打开股票页面，市值应约每 10 秒波动一次，且不再出现 57014 超时。
-- ============================================================
