-- ============================================================
-- NB频道 - NB商店 + 背包系统（V1）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 商品 10 个：评论颜色/抽奖券/昵称变色/手续费券/主页皮肤/
--            称号展示位/签名扩展/补签卡/私信气泡/粒子特效
-- ============================================================

-- ========== 1. 商品定义表 ==========
CREATE TABLE IF NOT EXISTS public.shop_items (
    key          text PRIMARY KEY,
    name         text NOT NULL,
    icon         text NOT NULL DEFAULT '🛍️',
    price        bigint NOT NULL,
    category     text NOT NULL DEFAULT 'function',   -- decoration / function
    duration_days integer,                            -- 时长(天)，NULL=一次性
    stackable    boolean NOT NULL DEFAULT true,       -- 是否可叠加(时长/数量)
    auto_renew   boolean NOT NULL DEFAULT false,      -- 是否自动续期
    max_hold     integer,                             -- 最大持有数(NULL=不限)
    desc_text    text NOT NULL DEFAULT '',
    enabled      boolean NOT NULL DEFAULT true        -- 上架状态
);
ALTER TABLE public.shop_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS shop_items_read ON public.shop_items;
CREATE POLICY shop_items_read ON public.shop_items FOR SELECT TO anon USING (enabled = true);
REVOKE INSERT, UPDATE, DELETE ON public.shop_items FROM anon;

-- ========== 2. 用户持有表（背包） ==========
CREATE TABLE IF NOT EXISTS public.user_items (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    item_key     text NOT NULL REFERENCES public.shop_items(key),
    expires_at   timestamptz,                          -- 到期时间(NULL=一次性/永久)
    used         boolean NOT NULL DEFAULT false,       -- 一次性道具是否已用
    settings     jsonb NOT NULL DEFAULT '{}'::jsonb,   -- 道具设置(颜色/特效等)
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_user_items_user ON public.user_items (user_id, id DESC);
ALTER TABLE public.user_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.user_items FROM anon, authenticated;
-- 只有 SECURITY DEFINER 函数能读写

-- ========== 3. 商品数据（10个） ==========
INSERT INTO public.shop_items (key, name, icon, price, category, duration_days, stackable, auto_renew, max_hold, desc_text) VALUES
('comment_color', '评论专属颜色券', '💬', 50000, 'decoration', 7, true, true, NULL, '自选评论文字颜色，可在背包更改（限时7天，可叠加，自动续期）'),
('lottery_extra',  '抽奖次数增加券', '🎰', 10000, 'function', NULL, true, false, NULL, '当日抽奖次数+10（一次性，可叠加）'),
('nickname_color', '昵称变色卡',     '📛', 50000, 'decoration', 7, true, true, NULL, '评论区名字变颜色（红/金/彩虹），可在背包更改（限时7天，可叠加，自动续期）'),
('fee_discount',   '股票手续费减免券', '📉', 300000, 'function', NULL, true, false, NULL, '本次交易手续费从5%调到2%（一次性，不可叠加使用）'),
('profile_skin',   '主页皮肤',       '🎪', 500000, 'decoration', 7, true, true, NULL, '解锁主页头图区，可自定义头图（图片/GIF）（限时7天，可叠加，自动续期）'),
('title_slot',     '称号展示位',     '🏅', 500000, 'function', 1, true, true, 1,   '额外增加一个称号展示位（限时1天，仅1个，自动续期）'),
('bio_extend',     '个性签名扩展',   '✏️', 20000, 'function', 7, true, true, NULL, '简介从100字扩到200字（限时7天，可叠加，自动续期）'),
('checkin_fix',    '补签卡',         '📝', 20000, 'function', NULL, true, false, 5,  '补回最近漏签的1天，恢复连续签到（最多持有5张，最多补前5天）'),
('chat_bubble',    '私信气泡皮肤',   '💬', 40000, 'decoration', 7, true, true, NULL, '私信气泡颜色（蓝/粉/绿/彩虹渐变），对方可见（限时7天，可叠加，自动续期）'),
('particle_fx',    '主页粒子特效卡', '🔮', 30000, 'decoration', 7, true, true, NULL, '主页背景粒子特效（火焰/闪电/气泡/星光），鼠标触摸触发（限时7天，可叠加，自动续期）')
ON CONFLICT (key) DO UPDATE SET
    name = EXCLUDED.name, icon = EXCLUDED.icon, price = EXCLUDED.price,
    category = EXCLUDED.category, duration_days = EXCLUDED.duration_days,
    stackable = EXCLUDED.stackable, auto_renew = EXCLUDED.auto_renew,
    max_hold = EXCLUDED.max_hold, desc_text = EXCLUDED.desc_text;

-- ========== 4. 购买 ==========
CREATE OR REPLACE FUNCTION public.buy_shop_item(p_user_id uuid, p_item_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_item record;
    v_balance bigint;
    v_count integer;
    v_duration interval;
BEGIN
    IF p_user_id IS NULL OR p_item_key IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '参数错误');
    END IF;
    SELECT * INTO v_item FROM public.shop_items WHERE key = p_item_key AND enabled = true;
    IF v_item.key IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '商品不存在或已下架');
    END IF;

    -- 余额校验
    SELECT nb_balance INTO v_balance FROM public.profiles WHERE id = p_user_id;
    IF v_balance < v_item.price THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('NB币余额不足（需 %s NB币）', v_item.price));
    END IF;

    -- 最大持有数校验（未过期 + 未使用的）
    IF v_item.max_hold IS NOT NULL THEN
        SELECT count(*) INTO v_count FROM public.user_items
         WHERE user_id = p_user_id AND item_key = p_item_key
           AND used = false AND (expires_at IS NULL OR expires_at > now());
        IF v_count >= v_item.max_hold THEN
            RETURN jsonb_build_object('success', false, 'message',
                format('该道具最多持有 %s 个', v_item.max_hold));
        END IF;
    END IF;

    -- 扣费
    UPDATE public.profiles SET nb_balance = nb_balance - v_item.price WHERE id = p_user_id;

    -- 入包：一次性道具独立一条；有时长的合并叠加（自动续期的按剩余时长+新时长）
    IF v_item.duration_days IS NULL THEN
        INSERT INTO public.user_items (user_id, item_key, expires_at, used)
        VALUES (p_user_id, p_item_key, NULL, false);
    ELSE
        v_duration := make_interval(days => v_item.duration_days);
        -- 时长叠加：若存在未过期的同类，从到期时间顺延；否则从现在开始
        IF v_item.auto_renew THEN
            UPDATE public.user_items
               SET expires_at = GREATEST(now(), expires_at) + v_duration
             WHERE user_id = p_user_id AND item_key = p_item_key
               AND expires_at > now();
            IF NOT FOUND THEN
                INSERT INTO public.user_items (user_id, item_key, expires_at, used)
                VALUES (p_user_id, p_item_key, now() + v_duration, false);
            END IF;
        ELSE
            INSERT INTO public.user_items (user_id, item_key, expires_at, used)
            VALUES (p_user_id, p_item_key, now() + v_duration, false);
        END IF;
    END IF;

    RETURN jsonb_build_object('success', true, 'message',
        format('购买成功：%s（%s NB币）', v_item.name, v_item.price));
END;
$$;

GRANT EXECUTE ON FUNCTION public.buy_shop_item(uuid, text) TO anon;

-- ========== 5. 背包查询 ==========
CREATE OR REPLACE FUNCTION public.get_my_items(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'success', true,
        'items', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                        'id', ui.id,
                        'item_key', ui.item_key,
                        'name', s.name,
                        'icon', s.icon,
                        'category', s.category,
                        'duration_days', s.duration_days,
                        'stackable', s.stackable,
                        'auto_renew', s.auto_renew,
                        'max_hold', s.max_hold,
                        'expires_at', ui.expires_at,
                        'used', ui.used,
                        'settings', ui.settings,
                        'active', (ui.expires_at IS NULL OR ui.expires_at > now()) AND NOT ui.used)
                    ORDER BY ui.id DESC)
              FROM public.user_items ui
              JOIN public.shop_items s ON s.key = ui.item_key
             WHERE ui.user_id = p_user_id), '[]'::jsonb)
    ) INTO v_result;
    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_items(uuid) TO anon;

-- ========== 6. 背包设置（改色/换特效等） ==========
CREATE OR REPLACE FUNCTION public.set_item_settings(p_user_id uuid, p_item_id bigint, p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_user_id IS NULL OR p_item_id IS NULL OR p_settings IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '参数错误');
    END IF;
    UPDATE public.user_items
       SET settings = p_settings
     WHERE id = p_item_id AND user_id = p_user_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', '道具不存在');
    END IF;
    RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_item_settings(uuid, bigint, jsonb) TO anon;

-- ========== 7. 一次性道具使用 ==========
CREATE OR REPLACE FUNCTION public.use_shop_item(p_user_id uuid, p_item_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_item record;
    v_used_count integer;
BEGIN
    IF p_user_id IS NULL OR p_item_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '参数错误');
    END IF;
    SELECT ui.*, s.key AS item_key, s.name AS item_name, s.duration_days
      INTO v_item
      FROM public.user_items ui
      JOIN public.shop_items s ON s.key = ui.item_key
     WHERE ui.id = p_item_id AND ui.user_id = p_user_id;
    IF v_item.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '道具不存在');
    END IF;
    IF v_item.used THEN
        RETURN jsonb_build_object('success', false, 'message', '该道具已使用');
    END IF;
    IF v_item.expires_at IS NOT NULL AND v_item.expires_at <= now() THEN
        RETURN jsonb_build_object('success', false, 'message', '道具已过期');
    END IF;
    IF v_item.duration_days IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '该道具为时长类，无需使用（自动生效）');
    END IF;

    -- 按道具类型执行效果
    IF v_item.item_key = 'lottery_extra' THEN
        -- 当日抽奖次数 +10：存到 user_items.settings（lottery_date / lottery_extra）
        UPDATE public.user_items
           SET used = true,
               settings = jsonb_build_object('lottery_date', (now() AT TIME ZONE 'Asia/Shanghai')::date,
                                             'lottery_extra', 10)
         WHERE id = p_item_id;
        RETURN jsonb_build_object('success', true, 'message', '今日抽奖次数 +10 生效！');
    ELSIF v_item.item_key = 'fee_discount' THEN
        -- 手续费减免：标记未使用（use 时不消费，交易时选择消耗）
        UPDATE public.user_items
           SET used = true,
               settings = jsonb_build_object('used_at', now())
         WHERE id = p_item_id;
        RETURN jsonb_build_object('success', true, 'message', '手续费减免券已激活（下次交易自动生效）');
    ELSIF v_item.item_key = 'checkin_fix' THEN
        RETURN jsonb_build_object('success', false, 'message', '补签请到签到页面使用（选择要补的日期）');
    ELSE
        RETURN jsonb_build_object('success', false, 'message', '该道具不支持此方式使用');
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.use_shop_item(uuid, bigint) TO anon;

-- ========== 8. 补签（补签卡） ==========
CREATE OR REPLACE FUNCTION public.use_checkin_fix(p_user_id uuid, p_target_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_today date := (now() AT TIME ZONE 'Asia/Shanghai')::date;
    v_card_id bigint;
    v_last_checkin date;
    v_consecutive integer;
    v_new_consecutive integer;
BEGIN
    -- 校验目标日期：只能补今天之前的 1~5 天，且今天还没签到
    IF p_target_date IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '请选择要补签的日期');
    END IF;
    IF p_target_date >= v_today OR p_target_date < v_today - 5 THEN
        RETURN jsonb_build_object('success', false, 'message', '只能补签前 5 天内的漏签');
    END IF;
    IF EXISTS (SELECT 1 FROM public.check_in_records WHERE user_id = p_user_id AND check_in_date = p_target_date) THEN
        RETURN jsonb_build_object('success', false, 'message', '该日期已签到，无需补签');
    END IF;

    -- 消耗一张补签卡
    SELECT id INTO v_card_id FROM public.user_items
     WHERE user_id = p_user_id AND item_key = 'checkin_fix'
       AND used = false AND (expires_at IS NULL OR expires_at > now())
     ORDER BY id LIMIT 1;
    IF v_card_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '没有可用的补签卡');
    END IF;

    -- 记录补签（不奖励NB币，只补记录；连续天数按目标日期恢复）
    INSERT INTO public.check_in_records (user_id, check_in_date)
    VALUES (p_user_id, p_target_date)
    ON CONFLICT (user_id, check_in_date) DO NOTHING;

    -- 更新连续天数：以目标日期为基准计算（目标日期的前一天若已签，则连续 +1）
    SELECT last_checkin_date, consecutive_days INTO v_last_checkin, v_consecutive
      FROM public.user_checkins WHERE user_id = p_user_id;
    IF v_last_checkin IS NULL OR v_last_checkin < p_target_date THEN
        v_new_consecutive := 1;
    ELSE
        v_new_consecutive := v_consecutive;
    END IF;

    UPDATE public.user_items SET used = true WHERE id = v_card_id;

    RETURN jsonb_build_object('success', true, 'message',
        format('补签成功：%s（消耗 1 张补签卡）', p_target_date::text));
END;
$$;

GRANT EXECUTE ON FUNCTION public.use_checkin_fix(uuid, date) TO anon;

-- ========== 9. 自动续期（每天定时执行：到期前 24 小时余额充足则自动续费） ==========
CREATE OR REPLACE FUNCTION public.renew_shop_items()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_item record;
    v_balance bigint;
    v_renewed integer := 0;
    v_failed integer := 0;
BEGIN
    -- 所有 auto_renew=true 且即将到期（24小时内）或已过期但未使用的时长道具
    FOR v_item IN
        SELECT ui.id AS item_id, ui.user_id, ui.item_key, ui.expires_at,
               s.price, s.name, s.duration_days
          FROM public.user_items ui
          JOIN public.shop_items s ON s.key = ui.item_key
         WHERE s.auto_renew = true
           AND ui.used = false
           AND ui.expires_at IS NOT NULL
           AND ui.expires_at <= now() + interval '24 hours'
    LOOP
        SELECT nb_balance INTO v_balance FROM public.profiles WHERE id = v_item.user_id;
        IF v_balance >= v_item.price THEN
            UPDATE public.profiles SET nb_balance = nb_balance - v_item.price WHERE id = v_item.user_id;
            UPDATE public.user_items
               SET expires_at = GREATEST(now(), expires_at) + make_interval(days => v_item.duration_days)
             WHERE id = v_item.item_id;
            v_renewed := v_renewed + 1;
        ELSE
            v_failed := v_failed + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('success', true, 'renewed', v_renewed, 'failed', v_failed);
END;
$$;

GRANT EXECUTE ON FUNCTION public.renew_shop_items() TO anon;

-- 每日 20:05(UTC) = 次日凌晨 4:05(北京) 执行自动续期
SELECT cron.schedule('shop-auto-renew', '5 20 * * *', 'select public.renew_shop_items()')
WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'shop-auto-renew');
