-- ============================================================
-- 手动补发成就：Utw（曾有百万持仓，成就系统上线后当前持仓不足，手动补发）
-- 在 Supabase SQL Editor 中执行（幂等：已领过会自动跳过）
-- 补发：hold_100k（小有资产 +1000）、hold_1m（资产百万 +5000）
-- ============================================================
DO $$
DECLARE
    v_uid uuid;
BEGIN
    SELECT id INTO v_uid FROM public.profiles WHERE username = 'Utw';
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户 Utw 不存在';
    END IF;

    -- 1. 小有资产（持仓价值 10万）
    IF NOT EXISTS (SELECT 1 FROM public.user_achievements
                    WHERE user_id = v_uid AND achievement_key = 'hold_100k') THEN
        UPDATE public.profiles SET nb_balance = nb_balance + 1000 WHERE id = v_uid;
        INSERT INTO public.user_achievements (user_id, achievement_key) VALUES (v_uid, 'hold_100k');
        RAISE NOTICE '已补发 hold_100k（+1000 NB）';
    ELSE
        RAISE NOTICE 'hold_100k 已领过，跳过';
    END IF;

    -- 2. 资产百万（持仓价值 100万）
    IF NOT EXISTS (SELECT 1 FROM public.user_achievements
                    WHERE user_id = v_uid AND achievement_key = 'hold_1m') THEN
        UPDATE public.profiles SET nb_balance = nb_balance + 5000 WHERE id = v_uid;
        INSERT INTO public.user_achievements (user_id, achievement_key) VALUES (v_uid, 'hold_1m');
        RAISE NOTICE '已补发 hold_1m（+5000 NB）';
    ELSE
        RAISE NOTICE 'hold_1m 已领过，跳过';
    END IF;
END $$;
