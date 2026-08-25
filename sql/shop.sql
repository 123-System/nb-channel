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
('checkin_fix',    '补签卡',         '📝', 20000, 'function', NULL, true, false, 5,  '补回最近漏签的1天，恢复连续签到（最多持有5张，最多补前5天，每月最多补5次；补签不计入签到总数/热力图）'),
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
        -- 时长叠加：只顺延"最晚到期"的那一条（避免历史多条记录被重复顺延）
        IF v_item.auto_renew THEN
            UPDATE public.user_items
               SET expires_at = GREATEST(now(), expires_at) + v_duration
             WHERE id = (SELECT id FROM public.user_items
                          WHERE user_id = p_user_id AND item_key = p_item_key
                            AND expires_at > now()
                          ORDER BY expires_at DESC LIMIT 1);
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
       SET settings = coalesce(settings, '{}'::jsonb) || p_settings
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
        -- 手续费减免：在股票买卖时勾选使用（use 接口仅提示）
        RETURN jsonb_build_object('success', true, 'message', '请在股票买卖弹窗中勾选"使用手续费减免券"（5%→2%）');
    ELSIF v_item.item_key = 'checkin_fix' THEN
        RETURN jsonb_build_object('success', false, 'message', '补签请到签到页面使用（选择要补的日期）');
    ELSE
        RETURN jsonb_build_object('success', false, 'message', '该道具不支持此方式使用');
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.use_shop_item(uuid, bigint) TO anon;

-- ========== 8. 补签（补签卡） ==========
-- 补签记录写入独立表 checkin_fix_records（不写入 check_in_records）：
--   - 不刷"签到之神"称号的累计签到次数（称号按 check_in_records 统计）
--   - 不刷签到热力图（热力图按 check_in_records 统计）
--   - 连续天数按"真实签到"往前数（补签日 + 之前连续的真实签到）
CREATE TABLE IF NOT EXISTS public.checkin_fix_records (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    check_in_date date NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, check_in_date)
);
ALTER TABLE public.checkin_fix_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.checkin_fix_records FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.use_checkin_fix(p_user_id uuid, p_target_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_today date := (now() AT TIME ZONE 'Asia/Shanghai')::date;
    v_card_id bigint;
    v_new_consecutive integer;
    v_idx integer;
    v_month_count integer;
BEGIN
    -- 校验目标日期：只能补今天之前的 1~5 天
    IF p_target_date IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '请选择要补签的日期');
    END IF;
    IF p_target_date >= v_today OR p_target_date < v_today - 5 THEN
        RETURN jsonb_build_object('success', false, 'message', '只能补签前 5 天内的漏签');
    END IF;
    -- 每自然月最多补签 5 次（防止买卡无限补）
    SELECT count(*) INTO v_month_count FROM public.checkin_fix_records
     WHERE user_id = p_user_id
       AND date_trunc('month', check_in_date) = date_trunc('month', p_target_date);
    IF v_month_count >= 5 THEN
        RETURN jsonb_build_object('success', false, 'message', '本月补签次数已达上限（5次），下个月再来吧');
    END IF;
    -- 该日期已真实签到 或 已补签过 → 不能重复补
    IF EXISTS (SELECT 1 FROM public.check_in_records WHERE user_id = p_user_id AND check_in_date = p_target_date) THEN
        RETURN jsonb_build_object('success', false, 'message', '该日期已签到，无需补签');
    END IF;
    IF EXISTS (SELECT 1 FROM public.checkin_fix_records WHERE user_id = p_user_id AND check_in_date = p_target_date) THEN
        RETURN jsonb_build_object('success', false, 'message', '该日期已补签过，不能重复补');
    END IF;

    -- 消耗一张补签卡
    SELECT id INTO v_card_id FROM public.user_items
     WHERE user_id = p_user_id AND item_key = 'checkin_fix'
       AND used = false AND (expires_at IS NULL OR expires_at > now())
     ORDER BY id LIMIT 1;
    IF v_card_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '没有可用的补签卡');
    END IF;

    -- 写入补签记录（独立表）
    INSERT INTO public.checkin_fix_records (user_id, check_in_date)
    VALUES (p_user_id, p_target_date);

    -- 连续天数：补签日本身算 1 天 + 从补签日前一天往前数"真实签到"的连续天数
    v_new_consecutive := 1;
    v_idx := 1;
    WHILE v_idx <= 365 LOOP
        IF EXISTS (SELECT 1 FROM public.check_in_records
                    WHERE user_id = p_user_id AND check_in_date = p_target_date - v_idx) THEN
            v_new_consecutive := v_new_consecutive + 1;
            v_idx := v_idx + 1;
        ELSE
            EXIT;
        END IF;
    END LOOP;

    UPDATE public.user_checkins
       SET last_checkin_date = GREATEST(coalesce(last_checkin_date, p_target_date), p_target_date),
           consecutive_days = v_new_consecutive
     WHERE user_id = p_user_id;
    IF NOT FOUND THEN
        INSERT INTO public.user_checkins (user_id, last_checkin_date, consecutive_days)
        VALUES (p_user_id, p_target_date, v_new_consecutive);
    END IF;

    UPDATE public.user_items SET used = true WHERE id = v_card_id;

    RETURN jsonb_build_object('success', true, 'message',
        format('补签成功：%s（消耗 1 张补签卡，连续 %s 天；补签不计入签到总数/热力图）',
               p_target_date::text, v_new_consecutive));
END;
$$;

GRANT EXECUTE ON FUNCTION public.use_checkin_fix(uuid, date) TO anon;

-- ========== 8.5 出售道具（按购买价 80% 回收，同一道具可多张一起卖） ==========
CREATE OR REPLACE FUNCTION public.sell_shop_item(p_user_id uuid, p_item_key text, p_quantity integer DEFAULT 1)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_item record;
    v_qty integer := GREATEST(coalesce(p_quantity, 1), 1);
    v_sold integer := 0;
    v_refund bigint := 0;
    v_ids bigint[];
BEGIN
    IF p_user_id IS NULL OR p_item_key IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '参数错误');
    END IF;

    -- 收集该道具下可卖（未使用、未过期）的记录，按 id 升序取前 v_qty 条
    SELECT array_agg(id) INTO v_ids FROM (
        SELECT ui.id
          FROM public.user_items ui
         WHERE ui.user_id = p_user_id
           AND ui.item_key = p_item_key
           AND ui.used = false
           AND (ui.expires_at IS NULL OR ui.expires_at > now())
         ORDER BY ui.id
         LIMIT v_qty
    ) t;

    IF v_ids IS NULL OR array_length(v_ids, 1) = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '没有可出售的该道具');
    END IF;
    IF array_length(v_ids, 1) < v_qty THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('可出售数量不足（当前仅 %s 个）', array_length(v_ids, 1)));
    END IF;

    -- 逐条计算退款（购买价 × 80%，向下取整）
    FOR v_item IN
        SELECT ui.id, s.price
          FROM public.user_items ui
          JOIN public.shop_items s ON s.key = ui.item_key
         WHERE ui.id = ANY(v_ids)
    LOOP
        v_refund := v_refund + floor(v_item.price * 0.8);
    END LOOP;

    -- 删除并退款
    DELETE FROM public.user_items WHERE id = ANY(v_ids);
    UPDATE public.profiles SET nb_balance = nb_balance + v_refund WHERE id = p_user_id;

    RETURN jsonb_build_object('success', true,
        'message', format('已出售 %s 个道具，回收 %s NB币（购买价80%%）', array_length(v_ids, 1), v_refund),
        'refund', v_refund, 'sold', array_length(v_ids, 1));
END;
$$;

GRANT EXECUTE ON FUNCTION public.sell_shop_item(uuid, text, integer) TO anon;

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

-- ========== 10. 生效效果查询（各页面读取当前生效的道具） ==========
-- 返回 { comment_color, nickname_color, chat_bubble, particle_fx, profile_skin,
--        title_slot, bio_extend, checkin_fix_count, lottery_extra_today }
CREATE OR REPLACE FUNCTION public.get_active_shop_effects(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result jsonb;
BEGIN
    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false);
    END IF;
    SELECT jsonb_build_object(
        'success', true,
        -- 评论颜色（取设置值）
        'comment_color', (SELECT settings->>'value' FROM public.user_items
                           WHERE user_id = p_user_id AND item_key = 'comment_color'
                             AND used = false AND expires_at > now()
                           ORDER BY expires_at DESC LIMIT 1),
        -- 昵称颜色
        'nickname_color', (SELECT settings->>'value' FROM public.user_items
                            WHERE user_id = p_user_id AND item_key = 'nickname_color'
                              AND used = false AND expires_at > now()
                            ORDER BY expires_at DESC LIMIT 1),
        -- 私信气泡
        'chat_bubble', (SELECT settings->>'value' FROM public.user_items
                         WHERE user_id = p_user_id AND item_key = 'chat_bubble'
                           AND used = false AND expires_at > now()
                         ORDER BY expires_at DESC LIMIT 1),
        -- 粒子特效
        'particle_fx', (SELECT settings->>'value' FROM public.user_items
                         WHERE user_id = p_user_id AND item_key = 'particle_fx'
                           AND used = false AND expires_at > now()
                         ORDER BY expires_at DESC LIMIT 1),
        -- 主页皮肤（settings 里含 banner 头图）
        'profile_skin', (SELECT settings FROM public.user_items
                          WHERE user_id = p_user_id AND item_key = 'profile_skin'
                            AND used = false AND expires_at > now()
                          ORDER BY expires_at DESC LIMIT 1),
        -- 称号展示位（含用户选择的展示称号 + 展示称号详情）
        'title_slot', (SELECT jsonb_build_object(
                            'count', count(*),
                            'chosen_title_key', (SELECT settings->>'chosen_title_key' FROM public.user_items
                                                  WHERE user_id = p_user_id AND item_key = 'title_slot'
                                                    AND used = false AND expires_at > now()
                                                  ORDER BY expires_at DESC LIMIT 1),
                            'slot_title', coalesce(
                                -- 1. 用户设置的展示称号（必须已拥有）
                                (SELECT jsonb_build_object(
                                            'title_key', t.key, 'name', t.name,
                                            'image_url', t.image_url, 'icon', t.icon, 'stars', ut.stars)
                                   FROM public.titles t
                                   JOIN public.user_titles ut ON ut.title_key = t.key AND ut.user_id = p_user_id
                                  WHERE t.key = (SELECT settings->>'chosen_title_key' FROM public.user_items
                                                  WHERE user_id = p_user_id AND item_key = 'title_slot'
                                                    AND used = false AND expires_at > now()
                                                  ORDER BY expires_at DESC LIMIT 1)
                                  LIMIT 1),
                                -- 2. 回退：最高星的未佩戴称号
                                (SELECT jsonb_build_object(
                                            'title_key', t.key, 'name', t.name,
                                            'image_url', t.image_url, 'icon', t.icon, 'stars', ut.stars)
                                   FROM public.user_titles ut
                                   JOIN public.titles t ON t.key = ut.title_key
                                   LEFT JOIN public.profiles p ON p.id = p_user_id
                                  WHERE ut.user_id = p_user_id
                                    AND t.key <> coalesce(p.equipped_title_id, '')
                                  ORDER BY ut.stars DESC, t.key
                                  LIMIT 1)
                            )
                        )
                        FROM public.user_items
                        WHERE user_id = p_user_id AND item_key = 'title_slot'
                          AND used = false AND expires_at > now()),
        -- 签名扩展是否生效
        'bio_extend', EXISTS (SELECT 1 FROM public.user_items
                               WHERE user_id = p_user_id AND item_key = 'bio_extend'
                                 AND used = false AND expires_at > now()),
        -- 可用补签卡数量
        'checkin_fix_count', (SELECT count(*) FROM public.user_items
                               WHERE user_id = p_user_id AND item_key = 'checkin_fix'
                                 AND used = false AND (expires_at IS NULL OR expires_at > now())),
        -- 可用手续费减免券数量
        'fee_discount_count', (SELECT count(*) FROM public.user_items
                                WHERE user_id = p_user_id AND item_key = 'fee_discount'
                                  AND used = false AND (expires_at IS NULL OR expires_at > now())),
        -- 今日抽奖额外次数（已使用的 lottery_extra 且日期=今天）
        'lottery_extra_today', coalesce((
            SELECT sum((settings->>'lottery_extra')::int)
              FROM public.user_items
             WHERE user_id = p_user_id AND item_key = 'lottery_extra' AND used = true
               AND settings->>'lottery_date' = (now() AT TIME ZONE 'Asia/Shanghai')::date::text), 0)
    ) INTO v_result;
    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_shop_effects(uuid) TO anon;

-- ========== 11. 抽奖次数：计入抽奖券 ==========
-- 说明：do_lottery 的每日上限 = 基础上限 + 今日已使用抽奖券的 +10/张
-- 在 do_lottery 内读取 get_active_shop_effects 不便，直接内联查询。
-- 此函数返回今日剩余可抽次数（含券加成），供前端显示。
CREATE OR REPLACE FUNCTION public.get_lottery_today(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_limit integer;
    v_extra integer := 0;
    v_used_today integer;
BEGIN
    SELECT value::integer INTO v_limit FROM public.admin_config WHERE key = 'lottery_daily_limit';
    IF v_limit IS NULL OR v_limit < 1 THEN v_limit := 10; END IF;

    SELECT coalesce(sum((settings->>'lottery_extra')::int), 0) INTO v_extra
      FROM public.user_items
     WHERE user_id = p_user_id AND item_key = 'lottery_extra' AND used = true
       AND settings->>'lottery_date' = (now() AT TIME ZONE 'Asia/Shanghai')::date::text;

    SELECT count(*) INTO v_used_today FROM public.lottery_records
     WHERE user_id = p_user_id AND created_at::date = current_date;

    RETURN jsonb_build_object('success', true,
        'limit', v_limit, 'extra', v_extra,
        'used_today', v_used_today,
        'remaining', GREATEST(v_limit + v_extra - v_used_today, 0));
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_lottery_today(uuid) TO anon;

-- ========== 12. 修改 do_lottery：上限 = 基础 + 抽奖券加成 ==========
CREATE OR REPLACE FUNCTION public.do_lottery(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_cost constant integer := 50;
    v_amount integer := 0;
    v_result text := 'none';
    v_sector integer := 0;
    v_balance bigint;
    v_today_count integer;
    v_limit integer;
    v_extra integer := 0;
BEGIN
    SELECT value::integer INTO v_limit FROM public.admin_config WHERE key = 'lottery_daily_limit';
    IF v_limit IS NULL OR v_limit < 1 THEN
        v_limit := 10;
    END IF;

    -- 今日抽奖券加成（已使用且日期=今天的 lottery_extra 道具）
    SELECT coalesce(sum((settings->>'lottery_extra')::int), 0) INTO v_extra
      FROM public.user_items
     WHERE user_id = p_user_id AND item_key = 'lottery_extra' AND used = true
       AND settings->>'lottery_date' = (now() AT TIME ZONE 'Asia/Shanghai')::date::text;

    SELECT count(*) INTO v_today_count FROM public.lottery_records
     WHERE user_id = p_user_id AND created_at::date = current_date;
    IF v_today_count >= v_limit + v_extra THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('今日抽奖次数已达上限（%s次），明天再来吧', v_limit + v_extra));
    END IF;

    UPDATE public.profiles SET nb_balance = nb_balance - v_cost
     WHERE id = p_user_id AND nb_balance >= v_cost;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'NB币余额不足（每次抽奖需 50 NB币）');
    END IF;

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
        'daily_limit', v_limit + v_extra
    );
END;
$function$;

-- ========== 13. 签名扩展：有 bio_extend 生效时简介上限 200 字 ==========
CREATE OR REPLACE FUNCTION public.update_bio(p_user_id uuid, p_bio text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_max integer := 100;
BEGIN
    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '参数错误');
    END IF;
    IF EXISTS (SELECT 1 FROM public.user_items
                WHERE user_id = p_user_id AND item_key = 'bio_extend'
                  AND used = false AND expires_at > now()) THEN
        v_max := 200;
    END IF;
    UPDATE public.profiles SET bio = left(coalesce(p_bio, ''), v_max) WHERE id = p_user_id;
    RETURN jsonb_build_object('success', true, 'max', v_max);
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_bio(uuid, text) TO anon;

-- ========== 15. 股票手续费券使用记录 ==========
-- 消耗一张手续费减免券（交易时由 buy_stock/sell_stock 调用）
CREATE OR REPLACE FUNCTION public.consume_fee_discount(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_id bigint;
BEGIN
    SELECT id INTO v_id FROM public.user_items
     WHERE user_id = p_user_id AND item_key = 'fee_discount'
       AND used = false AND (expires_at IS NULL OR expires_at > now())
     ORDER BY id LIMIT 1;
    IF v_id IS NULL THEN
        RETURN false;
    END IF;
    UPDATE public.user_items SET used = true, settings = jsonb_build_object('used_at', now())
     WHERE id = v_id;
    RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.consume_fee_discount(uuid) TO anon;

-- ========== 14. 主页皮肤头图设置 ==========
-- 上传头图后更新 profile_skin 道具的 settings.banner
CREATE OR REPLACE FUNCTION public.set_profile_banner(p_user_id uuid, p_url text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_item_id bigint;
BEGIN
    IF p_user_id IS NULL OR p_url IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '参数错误');
    END IF;
    SELECT id INTO v_item_id FROM public.user_items
     WHERE user_id = p_user_id AND item_key = 'profile_skin'
       AND used = false AND expires_at > now()
     ORDER BY expires_at DESC LIMIT 1;
    IF v_item_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '主页皮肤未生效（请先购买）');
    END IF;
    UPDATE public.user_items
       SET settings = jsonb_build_object('banner', p_url)
     WHERE id = v_item_id;
    RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_profile_banner(uuid, text) TO anon;

-- ========== 14.5 称号展示位：设置要展示的第二个称号 ==========
CREATE OR REPLACE FUNCTION public.set_title_slot(p_user_id uuid, p_title_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_item_id bigint;
BEGIN
    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '参数错误');
    END IF;
    -- 找到生效中的称号展示位道具
    SELECT id INTO v_item_id FROM public.user_items
     WHERE user_id = p_user_id AND item_key = 'title_slot'
       AND used = false AND expires_at > now()
     ORDER BY expires_at DESC LIMIT 1;
    IF v_item_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '称号展示位未生效（请先在商店购买）');
    END IF;
    -- 清空 = 取消展示位称号（回退为自动选最高星）
    IF p_title_key IS NULL OR p_title_key = '' THEN
        UPDATE public.user_items SET settings = '{}'::jsonb WHERE id = v_item_id;
        RETURN jsonb_build_object('success', true, 'message', '已取消展示位称号');
    END IF;
    -- 校验：该称号必须已拥有
    IF NOT EXISTS (SELECT 1 FROM public.user_titles WHERE user_id = p_user_id AND title_key = p_title_key) THEN
        RETURN jsonb_build_object('success', false, 'message', '你还没有这个称号');
    END IF;
    UPDATE public.user_items
       SET settings = coalesce(settings, '{}'::jsonb) || jsonb_build_object('chosen_title_key', p_title_key)
     WHERE id = v_item_id;
    RETURN jsonb_build_object('success', true, 'message', '展示位称号已设置');
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_title_slot(uuid, text) TO anon;
