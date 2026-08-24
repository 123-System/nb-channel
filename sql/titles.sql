-- ============================================================
-- NB频道 - 称号系统（titles）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 功能：
--   1) titles 表：12 个称号定义（获取方式：auto 自动 / buy 购买 / manual 手动颁发）
--   2) user_titles 表：用户拥有的称号 + 星级
--   3) profiles.equipped_title_id：当前佩戴（只能一个）
--   4) 自动称号星级 = 实时计算（数据源都是现有表）
--   5) 现金为王 = 逐级购买（1星1万 → 2星再10万 → 3星再100万 → 4星再1000万 → 5星再1亿）
--   6) 至尊皇冠 = 手动颁发（B站充电，管理员 token）
-- 图片：images/titles/<名称>.png（每称号一张横幅图，星级用前端叠加）
-- ============================================================

-- ========== 1. 称号定义表 ==========
CREATE TABLE IF NOT EXISTS public.titles (
    key            text PRIMARY KEY,          -- 唯一 key（英文）
    name           text NOT NULL,             -- 称号名（中文）
    icon           text NOT NULL DEFAULT '',  -- 图标（emoji 占位或图片URL）
    image_url      text NOT NULL DEFAULT '',  -- 横幅图 URL（images/titles/xxx.png）
    acquire_type   text NOT NULL DEFAULT 'auto',  -- auto 自动 / buy 购买 / manual 手动
    acquire_desc   text NOT NULL DEFAULT '',  -- 获取方式描述
    price          bigint NOT NULL DEFAULT 0, -- 购买称号：1星价格（NB币）
    star_prices    bigint[] NOT NULL DEFAULT '{}', -- 购买称号：2~5星每级再花价格
    star_thresholds bigint[] NOT NULL DEFAULT '{}', -- 自动称号：1~5星达标值
    display_order  integer NOT NULL DEFAULT 0
);

-- 插入 12 个称号（幂等：ON CONFLICT 更新）
-- 图片：Supabase 公开桶 images/titles/<英文key>.png（key 不支持中文）
INSERT INTO public.titles (key, name, icon, image_url, acquire_type, acquire_desc, price, star_prices, star_thresholds, display_order) VALUES
('checkin_god',    '签到之神', '📅', 'https://pbaafgjkwdbwcmsikcmg.supabase.co/storage/v1/object/public/images/titles/checkin_god.png', 'auto',   '首次签到即可获得', 0, '{}', '{7,30,100,200,365}', 1),
('comment_master', '评论大师', '💬', 'https://pbaafgjkwdbwcmsikcmg.supabase.co/storage/v1/object/public/images/titles/comment_master.png', 'auto',   '累计发布 10 条评论', 0, '{}', '{10,50,200,800,1000}', 2),
('redpacket_hero', '红包豪侠', '🧧', 'https://pbaafgjkwdbwcmsikcmg.supabase.co/storage/v1/object/public/images/titles/redpacket_hero.png', 'auto',   '累计发出红包 1000 NB币', 0, '{}', '{1000,10000,100000,500000,1000000}', 3),
('like_master',    '点赞大师', '👍', 'https://pbaafgjkwdbwcmsikcmg.supabase.co/storage/v1/object/public/images/titles/like_master.png', 'auto',   '累计点赞 10 次', 0, '{}', '{10,50,100,200,500}', 4),
('boss',           '霸道总裁', '🏢', 'https://pbaafgjkwdbwcmsikcmg.supabase.co/storage/v1/object/public/images/titles/boss.png', 'auto',   '注册一家公司', 0, '{}', '{10000,100000,1000000,10000000,100000000}', 5),
('chem_maniac',    '化学狂人', '🔬', 'https://pbaafgjkwdbwcmsikcmg.supabase.co/storage/v1/object/public/images/titles/chem_maniac.png', 'auto',   '配平成功 20 次', 0, '{}', '{20,100,300,1000,3000}', 6),
('product_tycoon', '作品大亨', '📦', 'https://pbaafgjkwdbwcmsikcmg.supabase.co/storage/v1/object/public/images/titles/product_tycoon.png', 'auto',   '上传 5 个作品', 0, '{}', '{5,15,50,100,200}', 7),
('achievement_hunter', '成就猎人', '🏆', 'https://pbaafgjkwdbwcmsikcmg.supabase.co/storage/v1/object/public/images/titles/achievement_hunter.png', 'auto', '获得 5 个成就', 0, '{}', '{5,7,9,10,11}', 8),
('social_butterfly','人脉达人', '🤝', 'https://pbaafgjkwdbwcmsikcmg.supabase.co/storage/v1/object/public/images/titles/social_butterfly.png', 'auto',  '拥有 5 个好友', 0, '{}', '{5,10,25,50,100}', 9),
('lottery_king',   '抽奖欧皇', '🎰', 'https://pbaafgjkwdbwcmsikcmg.supabase.co/storage/v1/object/public/images/titles/lottery_king.png', 'auto',   '累计抽奖 10 次', 0, '{}', '{10,20,50,200,500}', 10),
('cash_king',      '现金为王', '💎', 'https://pbaafgjkwdbwcmsikcmg.supabase.co/storage/v1/object/public/images/titles/cash_king.png', 'buy',    '购买获得（逐级升级）', 10000, '{100000,1000000,10000000,100000000}', '{}', 11),
('crown',          '至尊皇冠', '👑', 'https://pbaafgjkwdbwcmsikcmg.supabase.co/storage/v1/object/public/images/titles/crown.png', 'manual', '去 B 站给 UP 主充电（管理员颁发）', 0, '{}', '{}', 12)
ON CONFLICT (key) DO UPDATE SET
    name = EXCLUDED.name, icon = EXCLUDED.icon, image_url = EXCLUDED.image_url,
    acquire_type = EXCLUDED.acquire_type, acquire_desc = EXCLUDED.acquire_desc,
    price = EXCLUDED.price, star_prices = EXCLUDED.star_prices,
    star_thresholds = EXCLUDED.star_thresholds, display_order = EXCLUDED.display_order;

ALTER TABLE public.titles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.titles FROM anon;

-- ========== 2. 用户称号表 ==========
CREATE TABLE IF NOT EXISTS public.user_titles (
    user_id      uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    title_key    text NOT NULL REFERENCES public.titles(key) ON DELETE CASCADE,
    stars        integer NOT NULL DEFAULT 1,   -- 当前星级 1~5（自动称号：实时算出的最高星）
    spent        bigint NOT NULL DEFAULT 0,    -- 购买称号累计花费（现金为王）
    purchased    boolean NOT NULL DEFAULT false, -- 是否购买过（buy 类型）
    unlocked_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, title_key)
);

ALTER TABLE public.user_titles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.user_titles FROM anon;

-- ========== 3. profiles 加佩戴字段 ==========
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS equipped_title_id text REFERENCES public.titles(key) ON DELETE SET NULL;

-- ========== 4. 自动称号判定（返回每个称号的星级） ==========
CREATE OR REPLACE FUNCTION public.compute_title_stars(p_user_id uuid, p_title_key text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_val       bigint := 0;
    v_thresholds bigint[];
    v_stars     integer := 0;
BEGIN
    SELECT star_thresholds INTO v_thresholds FROM public.titles WHERE key = p_title_key;
    IF v_thresholds IS NULL OR array_length(v_thresholds, 1) IS NULL THEN
        RETURN 0;   -- 非自动称号
    END IF;

    IF p_title_key = 'checkin_god' THEN
        SELECT count(*) INTO v_val FROM public.check_in_records WHERE user_id = p_user_id;
    ELSIF p_title_key = 'comment_master' THEN
        SELECT count(*) INTO v_val FROM public.comments WHERE user_id = p_user_id;
    ELSIF p_title_key = 'redpacket_hero' THEN
        SELECT coalesce(sum(amount), 0) INTO v_val FROM public.transfers WHERE from_user = p_user_id;
    ELSIF p_title_key = 'like_master' THEN
        SELECT count(*) INTO v_val FROM public.comment_reactions WHERE user_id = p_user_id AND reaction = 1;
    ELSIF p_title_key = 'boss' THEN
        SELECT coalesce(max(market_value), 0) INTO v_val FROM public.user_companies WHERE user_id = p_user_id;
    ELSIF p_title_key = 'chem_maniac' THEN
        SELECT count(*) INTO v_val FROM public.user_balance_counts WHERE user_id = p_user_id;
    ELSIF p_title_key = 'product_tycoon' THEN
        SELECT count(*) INTO v_val FROM public.products WHERE author_id = p_user_id;
    ELSIF p_title_key = 'achievement_hunter' THEN
        SELECT count(*) INTO v_val FROM public.user_achievements WHERE user_id = p_user_id;
    ELSIF p_title_key = 'social_butterfly' THEN
        SELECT count(*) INTO v_val FROM public.friendships
         WHERE user_a = p_user_id OR user_b = p_user_id;
    ELSIF p_title_key = 'lottery_king' THEN
        SELECT count(*) INTO v_val FROM public.lottery_records WHERE user_id = p_user_id;
    END IF;

    -- 星级 = 达标的最大档位
    FOR i IN 1..array_length(v_thresholds, 1) LOOP
        IF v_val >= v_thresholds[i] THEN v_stars := i; END IF;
    END LOOP;
    RETURN v_stars;
END;
$$;

-- ========== 4.5 当前进度值（各称号的实时数据量，前端显示"当前做到哪了"） ==========
CREATE OR REPLACE FUNCTION public.compute_title_value(p_user_id uuid, p_title_key text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_val bigint := 0;
BEGIN
    IF p_title_key = 'checkin_god' THEN
        SELECT count(*) INTO v_val FROM public.check_in_records WHERE user_id = p_user_id;
    ELSIF p_title_key = 'comment_master' THEN
        SELECT count(*) INTO v_val FROM public.comments WHERE user_id = p_user_id;
    ELSIF p_title_key = 'redpacket_hero' THEN
        SELECT coalesce(sum(amount), 0) INTO v_val FROM public.transfers WHERE from_user = p_user_id;
    ELSIF p_title_key = 'like_master' THEN
        SELECT count(*) INTO v_val FROM public.comment_reactions WHERE user_id = p_user_id AND reaction = 1;
    ELSIF p_title_key = 'boss' THEN
        SELECT coalesce(max(market_value), 0) INTO v_val FROM public.user_companies WHERE user_id = p_user_id;
    ELSIF p_title_key = 'chem_maniac' THEN
        SELECT count(*) INTO v_val FROM public.user_balance_counts WHERE user_id = p_user_id;
    ELSIF p_title_key = 'product_tycoon' THEN
        SELECT count(*) INTO v_val FROM public.products WHERE author_id = p_user_id;
    ELSIF p_title_key = 'achievement_hunter' THEN
        SELECT count(*) INTO v_val FROM public.user_achievements WHERE user_id = p_user_id;
    ELSIF p_title_key = 'social_butterfly' THEN
        SELECT count(*) INTO v_val FROM public.friendships
         WHERE user_a = p_user_id OR user_b = p_user_id;
    ELSIF p_title_key = 'lottery_king' THEN
        SELECT count(*) INTO v_val FROM public.lottery_records WHERE user_id = p_user_id;
    END IF;
    RETURN v_val;
END;
$$;

-- ========== 5. 同步我的称号（登录时/前端调用：刷新自动称号解锁+星级） ==========
CREATE OR REPLACE FUNCTION public.sync_my_titles(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_rec     record;
    v_stars   integer;
    v_new     integer := 0;
BEGIN
    FOR v_rec IN SELECT key FROM public.titles WHERE acquire_type = 'auto' LOOP
        v_stars := public.compute_title_stars(p_user_id, v_rec.key);
        IF v_stars > 0 THEN
            INSERT INTO public.user_titles (user_id, title_key, stars, purchased)
            VALUES (p_user_id, v_rec.key, v_stars, false)
            ON CONFLICT (user_id, title_key) DO UPDATE SET stars = EXCLUDED.stars;
            v_new := v_new + 1;
        END IF;
    END LOOP;
    RETURN jsonb_build_object('success', true, 'synced', v_new);
END;
$$;

-- ========== 6. 获取我的称号列表（含星级/是否拥有/是否佩戴/进度/升星要求/当前进度） ==========
DROP FUNCTION IF EXISTS public.get_my_titles(uuid);
CREATE OR REPLACE FUNCTION public.get_my_titles(p_user_id uuid)
RETURNS TABLE (title_key text, name text, icon text, image_url text, acquire_type text,
               acquire_desc text, price bigint, star_prices bigint[], star_thresholds bigint[],
               stars integer, owned boolean, purchased boolean, equipped boolean, equipped_stars integer,
               current_value bigint, spent bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_equipped text;
BEGIN
    SELECT equipped_title_id INTO v_equipped FROM public.profiles WHERE id = p_user_id;
    RETURN QUERY
    SELECT t.key, t.name, t.icon, t.image_url, t.acquire_type, t.acquire_desc, t.price, t.star_prices,
           t.star_thresholds,
           coalesce(ut.stars, 0),
           (ut.user_id IS NOT NULL) AS owned,
           coalesce(ut.purchased, false) AS purchased,
           (t.key = v_equipped) AS equipped,
           CASE WHEN t.key = v_equipped AND ut.stars IS NOT NULL THEN ut.stars ELSE 0 END,
           public.compute_title_value(p_user_id, t.key),
           coalesce(ut.spent, 0)
      FROM public.titles t
      LEFT JOIN public.user_titles ut ON ut.title_key = t.key AND ut.user_id = p_user_id
     ORDER BY t.display_order;
END;
$$;

-- ========== 7. 佩戴 / 取消佩戴 ==========
CREATE OR REPLACE FUNCTION public.equip_title(p_user_id uuid, p_title_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_owned boolean;
BEGIN
    IF p_title_key IS NULL OR p_title_key = '' THEN
        -- 取消佩戴
        UPDATE public.profiles SET equipped_title_id = NULL WHERE id = p_user_id;
        RETURN jsonb_build_object('success', true, 'message', '已取消佩戴');
    END IF;
    SELECT EXISTS (SELECT 1 FROM public.user_titles WHERE user_id = p_user_id AND title_key = p_title_key)
      INTO v_owned;
    IF NOT v_owned THEN
        RETURN jsonb_build_object('success', false, 'message', '尚未拥有该称号');
    END IF;
    UPDATE public.profiles SET equipped_title_id = p_title_key WHERE id = p_user_id;
    RETURN jsonb_build_object('success', true, 'message', '已佩戴');
END;
$$;

-- ========== 8. 购买称号（现金为王：逐级升级） ==========
CREATE OR REPLACE FUNCTION public.buy_title(p_user_id uuid, p_title_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_price      bigint;
    v_balance    bigint;
    v_cur_stars  integer := 0;
    v_spent      bigint := 0;
    v_prices     bigint[];
    v_new_stars  integer;
BEGIN
    SELECT price, star_prices INTO v_price, v_prices
      FROM public.titles WHERE key = p_title_key AND acquire_type = 'buy';
    IF v_price IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '该称号不可购买');
    END IF;

    -- 当前星级与累计花费
    SELECT coalesce(stars, 0), coalesce(spent, 0) INTO v_cur_stars, v_spent
      FROM public.user_titles WHERE user_id = p_user_id AND title_key = p_title_key;

    -- 计算本次花费：1星 = price；2~5星 = star_prices[i-1]
    IF v_cur_stars = 0 THEN
        v_price := v_price;
    ELSIF v_cur_stars >= 5 THEN
        RETURN jsonb_build_object('success', false, 'message', '该称号已满级');
    ELSE
        v_price := v_prices[v_cur_stars];
    END IF;
    IF v_price IS NULL OR v_price <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '价格配置错误');
    END IF;

    -- 余额检查
    SELECT nb_balance INTO v_balance FROM public.profiles WHERE id = p_user_id;
    IF v_balance < v_price THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('NB币不足（需 %s NB币）', v_price));
    END IF;

    -- 扣款 + 升级
    UPDATE public.profiles SET nb_balance = nb_balance - v_price WHERE id = p_user_id;
    v_new_stars := v_cur_stars + 1;
    INSERT INTO public.user_titles (user_id, title_key, stars, spent, purchased, unlocked_at)
    VALUES (p_user_id, p_title_key, v_new_stars, v_spent + v_price, true, now())
    ON CONFLICT (user_id, title_key) DO UPDATE SET
        stars = EXCLUDED.stars, spent = EXCLUDED.spent, purchased = true;

    RETURN jsonb_build_object('success', true, 'stars', v_new_stars,
        'spent', v_spent + v_price, 'message',
        format('购买成功！%s 升到 %s 星（累计花费 %s NB币）',
               (SELECT name FROM public.titles WHERE key = p_title_key),
               v_new_stars, v_spent + v_price));
END;
$$;

-- ========== 9. 手动颁发（至尊皇冠：B站充电，管理员操作） ==========
CREATE OR REPLACE FUNCTION public.admin_grant_title(p_user_id uuid, p_title_key text, p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_ok boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM public.admin_sessions WHERE token = p_token AND expires_at > now()
    ) INTO v_ok;
    IF NOT v_ok THEN
        RETURN jsonb_build_object('success', false, 'message', '管理员验证失败');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.titles WHERE key = p_title_key) THEN
        RETURN jsonb_build_object('success', false, 'message', '称号不存在');
    END IF;

    INSERT INTO public.user_titles (user_id, title_key, stars, purchased)
    VALUES (p_user_id, p_title_key, 5, false)
    ON CONFLICT (user_id, title_key) DO UPDATE SET stars = 5;
    RETURN jsonb_build_object('success', true, 'message', '已颁发');
END;
$$;

-- ========== 10. 化学狂人计数表 ==========
CREATE TABLE IF NOT EXISTS public.user_balance_counts (
    user_id    uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    count      integer NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id)
);
ALTER TABLE public.user_balance_counts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.user_balance_counts FROM anon;

-- 配平成功上报（前端 tools 页调用）
CREATE OR REPLACE FUNCTION public.record_balance_count(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.user_balance_counts (user_id, count, updated_at)
    VALUES (p_user_id, 1, now())
    ON CONFLICT (user_id) DO UPDATE SET
        count = user_balance_counts.count + 1, updated_at = now();
    RETURN jsonb_build_object('success', true);
END;
$$;

-- ========== 11. 获取用户佩戴的称号（评论区/私信展示用） ==========
CREATE OR REPLACE FUNCTION public.get_user_title(p_user_id uuid)
RETURNS TABLE (title_key text, name text, image_url text, icon text, stars integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT t.key, t.name, t.image_url, t.icon, ut.stars
      FROM public.profiles p
      JOIN public.titles t ON t.key = p.equipped_title_id
      LEFT JOIN public.user_titles ut
        ON ut.title_key = t.key AND ut.user_id = p_user_id
     WHERE p.id = p_user_id
       AND p.equipped_title_id IS NOT NULL;
END;
$$;

-- ========== 12. 权限 ==========
GRANT EXECUTE ON FUNCTION public.compute_title_stars(uuid, text) TO anon;
GRANT EXECUTE ON FUNCTION public.compute_title_value(uuid, text) TO anon;
GRANT EXECUTE ON FUNCTION public.sync_my_titles(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_my_titles(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.equip_title(uuid, text) TO anon;
GRANT EXECUTE ON FUNCTION public.buy_title(uuid, text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_grant_title(uuid, text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.record_balance_count(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_user_title(uuid) TO anon;
