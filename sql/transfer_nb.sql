-- ============================================================
-- NB频道 - NB币转账（好友之间）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 规则：
--   1) 仅好友之间可转账
--   2) 单次最低 1、最高 100000
--   3) 每日转出上限 500000（北京时间算天）
--   4) 记录留痕（transfers 表），防刷
--   5) 转账成功后自动在双方私信会话插入一条"红包"提醒消息
--      （content 为 [redpacket]金额[/redpacket]，前端渲染成红包卡片）
-- ============================================================

-- 1. 转账记录表
CREATE TABLE IF NOT EXISTS public.transfers (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_user  uuid NOT NULL,
    to_user    uuid NOT NULL,
    amount     integer NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_transfers_from ON public.transfers (from_user, created_at);
CREATE INDEX IF NOT EXISTS idx_transfers_to   ON public.transfers (to_user, created_at);

ALTER TABLE public.transfers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.transfers FROM anon;

-- 2. 转账函数
CREATE OR REPLACE FUNCTION public.transfer_nb(p_from uuid, p_to uuid, p_amount integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_daily_limit constant integer := 500000;
    v_today       date := (now() AT TIME ZONE 'Asia/Shanghai')::date;
    v_sent_today  bigint;
    v_conv        bigint;
BEGIN
    IF p_from IS NULL OR p_to IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '参数错误');
    END IF;
    IF p_from = p_to THEN
        RETURN jsonb_build_object('success', false, 'message', '不能给自己转账');
    END IF;
    IF p_amount IS NULL OR p_amount < 1 THEN
        RETURN jsonb_build_object('success', false, 'message', '转账金额必须大于0');
    END IF;
    IF p_amount > 100000 THEN
        RETURN jsonb_build_object('success', false, 'message', '单次转账不能超过100000 NB币');
    END IF;

    -- 仅好友可转
    IF NOT public.is_friend(p_from, p_to) THEN
        RETURN jsonb_build_object('success', false, 'message', '只能给好友转账');
    END IF;

    -- 每日转出上限
    SELECT coalesce(sum(amount), 0) INTO v_sent_today
      FROM public.transfers
     WHERE from_user = p_from AND (created_at AT TIME ZONE 'Asia/Shanghai')::date = v_today;
    IF v_sent_today + p_amount > v_daily_limit THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('今日转出已达上限（%s/天），当前已转 %s', v_daily_limit, v_sent_today));
    END IF;

    -- 扣款 + 收款（原子）
    UPDATE public.profiles SET nb_balance = nb_balance - p_amount
     WHERE id = p_from AND nb_balance >= p_amount;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('NB币余额不足（需 %s NB币）', p_amount));
    END IF;
    UPDATE public.profiles SET nb_balance = nb_balance + p_amount WHERE id = p_to;

    INSERT INTO public.transfers (from_user, to_user, amount)
    VALUES (p_from, p_to, p_amount);

    -- 3. 红包提醒：找到或自动创建双方会话，插入红包消息
    SELECT id INTO v_conv
      FROM public.conversations
     WHERE user_low = LEAST(p_from, p_to)
       AND user_high = GREATEST(p_from, p_to);
    IF v_conv IS NULL THEN
        INSERT INTO public.conversations (user_low, user_high)
        VALUES (LEAST(p_from, p_to), GREATEST(p_from, p_to))
        RETURNING id INTO v_conv;
    END IF;

    INSERT INTO public.messages (conversation_id, sender_id, content)
    VALUES (v_conv, p_from, '[redpacket]' || p_amount || '[/redpacket]');

    -- 会话复活：双方都可见（微信同款）
    UPDATE public.conversations
       SET last_message_at = now(),
           a_hidden = false,
           b_hidden = false
     WHERE id = v_conv;

    RETURN jsonb_build_object('success', true, 'amount', p_amount,
        'sent_today', v_sent_today + p_amount, 'daily_limit', v_daily_limit);
END;
$$;

-- 3. 转账记录查询（最近 50 条，供前端展示"我的转账"）
CREATE OR REPLACE FUNCTION public.get_my_transfers(p_user uuid)
RETURNS TABLE (direction text, other_username text, amount integer, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT CASE WHEN t.from_user = p_user THEN 'out' ELSE 'in' END,
           pr.username,
           t.amount,
           t.created_at
      FROM public.transfers t
      JOIN public.profiles pr
        ON pr.id = CASE WHEN t.from_user = p_user THEN t.to_user ELSE t.from_user END
     WHERE t.from_user = p_user OR t.to_user = p_user
     ORDER BY t.id DESC
     LIMIT 50;
END;
$$;

-- 4. 权限
GRANT EXECUTE ON FUNCTION public.transfer_nb(uuid, uuid, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.get_my_transfers(uuid) TO anon;
