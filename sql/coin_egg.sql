-- ============================================================
-- NB频道 - 随机金币彩蛋（coin_egg）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 机制：
--   前端在随机时间（15~40分钟）、随机页面、随机位置出现一枚金币，
--   点击时调用 claim_coin 领取随机 NB币。
--   防刷：冷却（默认20分钟/次）+ 每日上限（默认5次/天），
--   参数在 admin_config 表可调：
--     coin_cooldown_min = 20（冷却分钟）
--     coin_daily_limit  = 5 （每日次数）
--     coin_min / coin_max = 10 / 100（奖励区间，5的倍数）
-- ============================================================

-- ========== 1. 领取记录表 ==========
CREATE TABLE IF NOT EXISTS public.coin_claims (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    uuid NOT NULL,
    amount     integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_coin_claims_user ON public.coin_claims (user_id, created_at);

ALTER TABLE public.coin_claims ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.coin_claims FROM anon;

-- ========== 2. 能否领取（前端出现金币前先问） ==========
CREATE OR REPLACE FUNCTION public.can_claim_coin(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_cooldown_min integer;
    v_daily_limit  integer;
    v_today_count  integer;
    v_last_at      timestamptz;
    v_elapsed_min  integer;
    v_today        date := (now() AT TIME ZONE 'Asia/Shanghai')::date;
BEGIN
    SELECT value::integer INTO v_cooldown_min FROM public.admin_config WHERE key = 'coin_cooldown_min';
    IF v_cooldown_min IS NULL OR v_cooldown_min < 1 THEN v_cooldown_min := 20; END IF;
    SELECT value::integer INTO v_daily_limit FROM public.admin_config WHERE key = 'coin_daily_limit';
    IF v_daily_limit IS NULL OR v_daily_limit < 1 THEN v_daily_limit := 5; END IF;

    SELECT count(*) INTO v_today_count FROM public.coin_claims
     WHERE user_id = p_user_id AND (created_at AT TIME ZONE 'Asia/Shanghai')::date = v_today;
    SELECT max(created_at) INTO v_last_at FROM public.coin_claims WHERE user_id = p_user_id;

    IF v_last_at IS NULL THEN
        RETURN jsonb_build_object('can', true, 'cooldown_left_min', 0,
            'daily_count', v_today_count, 'daily_limit', v_daily_limit);
    END IF;
    v_elapsed_min := floor(extract(epoch FROM (now() - v_last_at)) / 60)::integer;
    RETURN jsonb_build_object(
        'can', v_elapsed_min >= v_cooldown_min AND v_today_count < v_daily_limit,
        'cooldown_left_min', GREATEST(v_cooldown_min - v_elapsed_min, 0),
        'daily_count', v_today_count,
        'daily_limit', v_daily_limit
    );
END;
$$;

-- ========== 3. 领取金币 ==========
CREATE OR REPLACE FUNCTION public.claim_coin(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_cooldown_min integer;
    v_daily_limit  integer;
    v_min_amount   integer;
    v_max_amount   integer;
    v_today_count  integer;
    v_last_at      timestamptz;
    v_elapsed_min  integer;
    v_amount       integer;
    v_today        date := (now() AT TIME ZONE 'Asia/Shanghai')::date;
BEGIN
    -- 读配置（可调）
    SELECT value::integer INTO v_cooldown_min FROM public.admin_config WHERE key = 'coin_cooldown_min';
    IF v_cooldown_min IS NULL OR v_cooldown_min < 1 THEN v_cooldown_min := 20; END IF;
    SELECT value::integer INTO v_daily_limit FROM public.admin_config WHERE key = 'coin_daily_limit';
    IF v_daily_limit IS NULL OR v_daily_limit < 1 THEN v_daily_limit := 5; END IF;
    SELECT value::integer INTO v_min_amount FROM public.admin_config WHERE key = 'coin_min';
    IF v_min_amount IS NULL OR v_min_amount < 1 THEN v_min_amount := 10; END IF;
    SELECT value::integer INTO v_max_amount FROM public.admin_config WHERE key = 'coin_max';
    IF v_max_amount IS NULL OR v_max_amount < v_min_amount THEN v_max_amount := 100; END IF;

    -- 冷却检查
    SELECT max(created_at) INTO v_last_at FROM public.coin_claims WHERE user_id = p_user_id;
    IF v_last_at IS NOT NULL THEN
        v_elapsed_min := floor(extract(epoch FROM (now() - v_last_at)) / 60)::integer;
        IF v_elapsed_min < v_cooldown_min THEN
            RETURN jsonb_build_object('success', false, 'message',
                format('金币还在冷却中，%s 分钟后再来', v_cooldown_min - v_elapsed_min));
        END IF;
    END IF;

    -- 每日上限
    SELECT count(*) INTO v_today_count FROM public.coin_claims
     WHERE user_id = p_user_id AND (created_at AT TIME ZONE 'Asia/Shanghai')::date = v_today;
    IF v_today_count >= v_daily_limit THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('今日金币已达上限（%s次），明天再来', v_daily_limit));
    END IF;

    -- 随机奖励（5 的倍数，不超过上限）
    v_amount := v_min_amount + floor(random() * ((v_max_amount - v_min_amount) / 5 + 1)) * 5;
    v_amount := LEAST(v_amount, v_max_amount);

    UPDATE public.profiles SET nb_balance = nb_balance + v_amount WHERE id = p_user_id;
    INSERT INTO public.coin_claims (user_id, amount) VALUES (p_user_id, v_amount);

    RETURN jsonb_build_object('success', true, 'amount', v_amount,
        'daily_count', v_today_count + 1, 'daily_limit', v_daily_limit);
END;
$$;

-- ========== 4. 权限 ==========
GRANT EXECUTE ON FUNCTION public.can_claim_coin(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.claim_coin(uuid) TO anon;
