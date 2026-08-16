-- ============================================================
-- NB频道 - 虚拟股票防刷优化（基于你的真实函数体重写）
-- 说明：原 random_fluctuate_market_values 逻辑完全保留
--       （±5% 对称波动、市值保底 10000、浮点计算后取整），
--       仅增加"全局节流"：stock_latest 8 秒内有更新则跳过本次波动。
--       无论多少用户同时在线，数据库层面 8 秒内最多波动一次。
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
    v_last timestamptz;
BEGIN
    -- 全局节流：stock_latest 8 秒内有更新则跳过本次波动
    SELECT max(created_at) INTO v_last FROM public.stock_latest;
    IF v_last IS NOT NULL AND v_last > now() - interval '8 seconds' THEN
        RETURN;
    END IF;

    -- 原波动逻辑（完全保留）：-5% ~ +5% 对称波动，最低市值 10000
    FOR company IN SELECT id, market_value FROM user_companies LOOP
        change_percent := (random() - 0.5) * 0.1;
        new_value := company.market_value + (company.market_value * change_percent);
        IF new_value < 10000 THEN new_value := 10000; END IF;
        UPDATE user_companies SET market_value = new_value WHERE id = company.id;
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.random_fluctuate_market_values() TO anon;

-- ========== 附带说明 ==========
-- 历史快照由 delete_old_history / delete_old_history_full 触发器自动清理（保留30条），无需手动清理。
-- 前端已做写入降频（最新快照3秒节流、历史快照55秒节流），与此函数配合效果最佳。
