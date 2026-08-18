-- ============================================================
-- NB频道 - 幸运转盘抽奖（每次 50 NB币，奖池 10~2000）
-- 在 Supabase SQL Editor 中执行
-- 扇区（8格等概率）：
--   谢谢惠顾 / 10 / 50 / 100 / 谢谢惠顾 / 200 / 500 / 2000
-- ============================================================

-- 1. 抽奖记录表
CREATE TABLE IF NOT EXISTS public.lottery_records (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    uuid NOT NULL,
    result     text NOT NULL,          -- 'win' 中奖 / 'none' 谢谢惠顾
    amount     integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_lottery_user ON public.lottery_records (user_id, created_at);

ALTER TABLE public.lottery_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lottery_records FROM anon;

-- 2. 抽奖函数
CREATE OR REPLACE FUNCTION public.do_lottery(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_cost constant integer := 50;
    v_roll NUMERIC;
    v_amount integer := 0;
    v_result text := 'none';
    v_sector integer := 0;
    v_balance integer;
    v_today_count integer;
    v_limit integer;
BEGIN
    -- 每日抽奖上限（从 admin_config 读取，key=lottery_daily_limit，默认 10）
    SELECT value::integer INTO v_limit FROM public.admin_config WHERE key = 'lottery_daily_limit';
    IF v_limit IS NULL OR v_limit < 1 THEN
        v_limit := 10;
    END IF;

    SELECT count(*) INTO v_today_count FROM public.lottery_records
     WHERE user_id = p_user_id AND created_at::date = current_date;
    IF v_today_count >= v_limit THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('今日抽奖次数已达上限（%s次），明天再来吧', v_limit));
    END IF;

    -- 扣 50 NB币（原子扣款）
    UPDATE public.profiles SET nb_balance = nb_balance - v_cost
     WHERE id = p_user_id AND nb_balance >= v_cost;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'NB币余额不足（每次抽奖需 50 NB币）');
    END IF;

    -- 抽奖：8 个扇区等概率（0~7）
    -- 0=谢谢 1=10 2=50 3=100 4=谢谢 5=200 6=500 7=2000
    v_sector := floor(random() * 8)::integer;

    IF v_sector = 1 THEN v_amount := 10;
    ELSIF v_sector = 2 THEN v_amount := 50;
    ELSIF v_sector = 3 THEN v_amount := 100;
    ELSIF v_sector = 5 THEN v_amount := 200;
    ELSIF v_sector = 6 THEN v_amount := 500;
    ELSIF v_sector = 7 THEN v_amount := 2000;
    END IF;

    IF v_amount > 0 THEN
        v_result := 'win';
        UPDATE public.profiles SET nb_balance = nb_balance + v_amount WHERE id = p_user_id;
    END IF;

    INSERT INTO public.lottery_records (user_id, result, amount)
    VALUES (p_user_id, v_result, v_amount);

    SELECT nb_balance INTO v_balance FROM public.profiles WHERE id = p_user_id;

    RETURN jsonb_build_object(
        'success', true,
        'result', v_result,
        'amount', v_amount,
        'sector', v_sector,
        'balance', v_balance,
        'today_count', v_today_count + 1,
        'daily_limit', v_limit
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.do_lottery(uuid) TO anon;
