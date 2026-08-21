-- ============================================================
-- NB频道 - 自动支持改为数据库驱动（人不在页面也生效）
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 背景：自动支持原来由前端页面定时器驱动（每10秒），
--       离开股票页面就停 → 自己的公司没人托底就会跌。
-- 修复：新增 run_auto_support()，由 pg_cron 市场循环（每10秒一轮）
--       顺带执行所有支持规则 —— 与访客/页面无关，7x24 生效。
-- 说明：仍遵守交易时段（支持函数内部校验 8:00-20:00）、
--       自支持 5% 手续费、单次上限 2000、余额不足自动删除规则
--       （与原前端行为一致）。
-- ============================================================

-- ========== 1. 自动支持执行器 ==========
CREATE OR REPLACE FUNCTION public.run_auto_support()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r RECORD;
    v_res jsonb;
    v_count integer := 0;
    v_deleted integer := 0;
BEGIN
    FOR r IN
        SELECT sr.id, sr.user_id, sr.company_id, sr.threshold, sr.amount,
               uc.market_value, p.nb_balance
          FROM public.support_rules sr
          JOIN public.user_companies uc ON uc.id = sr.company_id
          JOIN public.profiles p ON p.id = sr.user_id
    LOOP
        -- 与原前端逻辑一致：金额合法且余额够 → 执行支持；否则删除规则
        IF r.amount <= 0 OR r.amount > 2000 OR r.nb_balance < r.amount THEN
            DELETE FROM public.support_rules WHERE id = r.id;
            v_deleted := v_deleted + 1;
            CONTINUE;
        END IF;

        IF r.market_value < r.threshold THEN
            -- 复用 support_company：含交易时段校验、自支持 5% 手续费、扣款与日志
            SELECT public.support_company(r.user_id, r.company_id, r.amount) INTO v_res;
            IF v_res IS NOT NULL AND v_res->>'success' = 'true' THEN
                v_count := v_count + 1;
            END IF;
            -- 失败（如休市）不删规则，下轮再试
        END IF;
    END LOOP;
    RAISE NOTICE 'run_auto_support: 执行支持 % 条，清理失效规则 % 条', v_count, v_deleted;
END;
$$;

-- ========== 2. 市场循环 v3：每轮波动后顺带执行自动支持 ==========
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
        COMMIT;
    END IF;

    -- 交易时段：每 10 秒波动一轮 + 自动支持，每轮 COMMIT 释放行锁
    IF v_in_session THEN
        FOR i IN 1..6 LOOP
            PERFORM public.random_fluctuate_market_values();
            PERFORM public.run_auto_support();
            COMMIT;              -- 关键：行锁立即释放，访客请求不再被堵
            IF i < 6 THEN
                PERFORM pg_sleep(10);
            END IF;
        END LOOP;
    END IF;
END;
$$;

-- 验证：SELECT * FROM cron.job; 应仍有 market-10s-tick（任务无需重建，
-- 它调用 CALL public.market_tick_loop()，过程已被上面覆盖）。
