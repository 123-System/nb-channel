-- ============================================================
-- NB频道 - 成就徽章系统（achievements）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 机制：
--   1) achievements 表：成就定义（key/名称/描述/奖励/图标）
--   2) user_achievements 表：用户已解锁成就（一人一次，天然防刷）
--   3) check_achievements(p_user_id)：检查全部条件，满足即发奖（前端登录后调用）
--   4) get_my_achievements(p_user_id)：成就页展示列表
-- ============================================================

-- ========== 1. 成就定义表 ==========
CREATE TABLE IF NOT EXISTS public.achievements (
    key         text PRIMARY KEY,
    name        text NOT NULL,
    description text NOT NULL,
    reward      integer NOT NULL DEFAULT 0,
    icon        text NOT NULL DEFAULT '🏆'
);

-- ========== 2. 用户已解锁成就 ==========
CREATE TABLE IF NOT EXISTS public.user_achievements (
    user_id         uuid NOT NULL,
    achievement_key text NOT NULL,
    claimed_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, achievement_key)
);

-- ========== 3. 权限：全部走 RPC，禁止直接读写 ==========
ALTER TABLE public.achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_achievements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.achievements FROM anon;
REVOKE ALL ON public.user_achievements FROM anon;

-- ========== 4. 成就定义（11个，可随时增改；重复执行以最新为准） ==========
INSERT INTO public.achievements (key, name, description, reward, icon) VALUES
('first_register', '初来乍到',   '完成注册，成为NB频道的一员',         500,  '🐣'),
('first_buy',      '初入股市',   '完成你的第一笔股票买入',             200,  '📈'),
('hold_100k',      '小有资产',   '持仓价值突破 100,000 NB币',          1000, '💰'),
('hold_1m',        '资产百万',   '持仓价值突破 1,000,000 NB币',        5000, '🏦'),
('first_comment',  '初试身手',   '发出你的第一条评论',                 200,  '📝'),
('first_product',  '崭露头角',   '上传你的第一个作品',                 200,  '📤'),
('first_sell',     '首单成交',   '你的作品第一次被别人购买',           500,  '🛍️'),
('first_friend',   '广结好友',   '添加你的第一个好友',                 200,  '👥'),
('checkin_7',      '风雨无阻',   '连续签到达到 7 天',                  1000, '📅'),
('lottery_10',     '十连抽选手', '累计抽奖达到 10 次',                 1000, '🎰'),
('master',         '成就大师',   '解锁全部其他成就',                   5000, '💎')
ON CONFLICT (key) DO UPDATE SET
    name = EXCLUDED.name, description = EXCLUDED.description,
    reward = EXCLUDED.reward, icon = EXCLUDED.icon;

-- ========== 5. 检查成就并发放奖励（前端登录后调用） ==========
CREATE OR REPLACE FUNCTION public.check_achievements(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_ach           record;
    v_unlocked      boolean;
    v_reward_total  integer := 0;
    v_new           jsonb := '[]'::jsonb;
BEGIN
    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object('new', v_new, 'new_count', 0, 'reward_total', 0);
    END IF;

    FOR v_ach IN SELECT * FROM public.achievements ORDER BY key LOOP
        -- 已领取过则跳过（一人一次）
        IF EXISTS (SELECT 1 FROM public.user_achievements
                    WHERE user_id = p_user_id AND achievement_key = v_ach.key) THEN
            CONTINUE;
        END IF;

        v_unlocked := false;
        CASE v_ach.key
            WHEN 'first_register' THEN
                SELECT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) INTO v_unlocked;
            WHEN 'first_buy' THEN
                SELECT EXISTS (SELECT 1 FROM public.transactions
                                WHERE user_id = p_user_id AND type = 'buy') INTO v_unlocked;
            WHEN 'hold_100k' THEN
                SELECT COALESCE(sum(h.principal * (uc.market_value::numeric / h.base_market_value)), 0) >= 100000
                  INTO v_unlocked
                  FROM public.holdings h
                  JOIN public.user_companies uc ON uc.id = h.company_id
                 WHERE h.user_id = p_user_id;
            WHEN 'hold_1m' THEN
                SELECT COALESCE(sum(h.principal * (uc.market_value::numeric / h.base_market_value)), 0) >= 1000000
                  INTO v_unlocked
                  FROM public.holdings h
                  JOIN public.user_companies uc ON uc.id = h.company_id
                 WHERE h.user_id = p_user_id;
            WHEN 'first_comment' THEN
                SELECT EXISTS (SELECT 1 FROM public.comments WHERE user_id = p_user_id) INTO v_unlocked;
            WHEN 'first_product' THEN
                SELECT EXISTS (SELECT 1 FROM public.products WHERE author_id = p_user_id) INTO v_unlocked;
            WHEN 'first_sell' THEN
                SELECT EXISTS (SELECT 1 FROM public.product_purchases WHERE seller_id = p_user_id) INTO v_unlocked;
            WHEN 'first_friend' THEN
                SELECT EXISTS (SELECT 1 FROM public.friendships
                                WHERE user_a = p_user_id OR user_b = p_user_id) INTO v_unlocked;
            WHEN 'checkin_7' THEN
                SELECT EXISTS (SELECT 1 FROM public.user_checkins
                                WHERE user_id = p_user_id AND consecutive_days >= 7) INTO v_unlocked;
            WHEN 'lottery_10' THEN
                SELECT (SELECT count(*) FROM public.lottery_records WHERE user_id = p_user_id) >= 10
                  INTO v_unlocked;
            WHEN 'master' THEN
                -- 全收集：已解锁数 >= 成就总数-1（其他成就刚解锁的也计入本次事务）
                SELECT (SELECT count(*) FROM public.user_achievements WHERE user_id = p_user_id)
                     >= (SELECT count(*) - 1 FROM public.achievements) INTO v_unlocked;
            ELSE
                v_unlocked := false;
        END CASE;

        IF v_unlocked THEN
            -- 发奖励（一次性）
            UPDATE public.profiles SET nb_balance = nb_balance + v_ach.reward
             WHERE id = p_user_id;
            INSERT INTO public.user_achievements (user_id, achievement_key)
            VALUES (p_user_id, v_ach.key);
            v_reward_total := v_reward_total + v_ach.reward;
            v_new := v_new || jsonb_build_object(
                'key', v_ach.key, 'name', v_ach.name, 'reward', v_ach.reward, 'icon', v_ach.icon
            );
        END IF;
    END LOOP;

    RETURN jsonb_build_object('new', v_new, 'new_count', jsonb_array_length(v_new), 'reward_total', v_reward_total);
END;
$$;

-- ========== 6. 成就列表（成就页展示用） ==========
CREATE OR REPLACE FUNCTION public.get_my_achievements(p_user_id uuid)
RETURNS TABLE (key text, name text, description text, reward integer, icon text,
               unlocked boolean, claimed_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT a.key, a.name, a.description, a.reward, a.icon,
           (ua.claimed_at IS NOT NULL) AS unlocked,
           ua.claimed_at
      FROM public.achievements a
      LEFT JOIN public.user_achievements ua
        ON ua.achievement_key = a.key AND ua.user_id = p_user_id
     ORDER BY a.key;
END;
$$;

-- ========== 7. 权限 ==========
GRANT EXECUTE ON FUNCTION public.check_achievements(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_my_achievements(uuid) TO anon;
