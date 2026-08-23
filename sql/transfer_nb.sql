-- ============================================================
-- NB频道 - NB币转账（好友之间）· 红包领取模式 v3
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 规则：
--   1) 仅好友之间可转账
--   2) 单次最低 1、最高 100000
--   3) 每日转出上限 500000（北京时间算天）
--   4) 记录留痕（transfers 表），防刷
--   5) 红包模式：转账金额先挂起（不入账），收款方在私信里
--      点击红包领取后才存入钱包；24 小时未领取自动退回转出方
--   6) 转账成功后自动在双方私信会话插入一条"红包"消息
--      （content 为 [redpacket]转账id|金额[/redpacket]，
--       领取后更新为 [redpacket_claimed]...[/redpacket_claimed]，
--       超时退回后更新为 [redpacket_refunded]...[/redpacket_refunded]）
-- ============================================================

-- 1. 转账记录表（含状态：pending 待领取 / claimed 已领取 / refunded 已退回）
CREATE TABLE IF NOT EXISTS public.transfers (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_user   uuid NOT NULL,
    to_user     uuid NOT NULL,
    amount      integer NOT NULL,
    status      text NOT NULL DEFAULT 'pending',
    claimed_at  timestamptz,
    refunded_at timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.transfers ADD COLUMN IF NOT EXISTS status      text NOT NULL DEFAULT 'pending';
ALTER TABLE public.transfers ADD COLUMN IF NOT EXISTS claimed_at  timestamptz;
ALTER TABLE public.transfers ADD COLUMN IF NOT EXISTS refunded_at timestamptz;
CREATE INDEX IF NOT EXISTS idx_transfers_from  ON public.transfers (from_user, created_at);
CREATE INDEX IF NOT EXISTS idx_transfers_to    ON public.transfers (to_user, created_at);
CREATE INDEX IF NOT EXISTS idx_transfers_pend  ON public.transfers (status, created_at);

ALTER TABLE public.transfers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.transfers FROM anon;

-- 2. 转账函数（红包模式：只扣款挂起，不直接入账）
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
    v_transfer_id bigint;
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

    -- 扣款（只扣转出方，金额挂起待领取）
    UPDATE public.profiles SET nb_balance = nb_balance - p_amount
     WHERE id = p_from AND nb_balance >= p_amount;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('NB币余额不足（需 %s NB币）', p_amount));
    END IF;

    INSERT INTO public.transfers (from_user, to_user, amount, status)
    VALUES (p_from, p_to, p_amount, 'pending')
    RETURNING id INTO v_transfer_id;

    -- 红包提醒：找到或自动创建双方会话，插入红包消息
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
    VALUES (v_conv, p_from, '[redpacket]' || v_transfer_id || '|' || p_amount || '[/redpacket]');

    -- 会话复活：双方都可见（微信同款）
    UPDATE public.conversations
       SET last_message_at = now(),
           a_hidden = false,
           b_hidden = false
     WHERE id = v_conv;

    RETURN jsonb_build_object('success', true, 'amount', p_amount,
        'transfer_id', v_transfer_id,
        'sent_today', v_sent_today + p_amount, 'daily_limit', v_daily_limit);
END;
$$;

-- 3. 领取红包（仅收款方本人可领，原子操作）
CREATE OR REPLACE FUNCTION public.claim_redpacket(p_transfer_id bigint, p_user uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_amount integer;
    v_from   uuid;
    v_conv   bigint;
BEGIN
    -- 原子：仅 pending 且收款人本人可领
    UPDATE public.transfers
       SET status = 'claimed', claimed_at = now()
     WHERE id = p_transfer_id AND to_user = p_user AND status = 'pending'
     RETURNING amount, from_user INTO v_amount, v_from;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', '红包不存在、已领取或已退回');
    END IF;

    -- 入账收款方
    UPDATE public.profiles SET nb_balance = nb_balance + v_amount WHERE id = p_user;

    -- 同步更新私信里的红包消息为"已领取"
    SELECT id INTO v_conv
      FROM public.conversations
     WHERE user_low = LEAST(v_from, p_user)
       AND user_high = GREATEST(v_from, p_user);
    UPDATE public.messages
       SET content = '[redpacket_claimed]' || p_transfer_id || '|' || v_amount || '[/redpacket_claimed]'
     WHERE conversation_id = v_conv
       AND sender_id = v_from
       AND content = '[redpacket]' || p_transfer_id || '|' || v_amount || '[/redpacket]';

    RETURN jsonb_build_object('success', true, 'amount', v_amount);
END;
$$;

-- 4. 超时退回：超过 24 小时未领取的红包自动退回转出方
CREATE OR REPLACE FUNCTION public.refund_expired_redpackets()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_refunded integer := 0;
    v_rec      record;
    v_conv     bigint;
BEGIN
    FOR v_rec IN
        SELECT t.id, t.from_user, t.to_user, t.amount
          FROM public.transfers t
         WHERE t.status = 'pending'
           AND t.created_at < now() - interval '24 hours'
    LOOP
        -- 退回转出方
        UPDATE public.profiles SET nb_balance = nb_balance + v_rec.amount
         WHERE id = v_rec.from_user;
        UPDATE public.transfers
           SET status = 'refunded', refunded_at = now()
         WHERE id = v_rec.id;

        -- 同步更新私信里的红包消息为"已退回"
        SELECT id INTO v_conv
          FROM public.conversations
         WHERE user_low = LEAST(v_rec.from_user, v_rec.to_user)
           AND user_high = GREATEST(v_rec.from_user, v_rec.to_user);
        UPDATE public.messages
           SET content = '[redpacket_refunded]' || v_rec.id || '|' || v_rec.amount || '[/redpacket_refunded]'
         WHERE conversation_id = v_conv
           AND sender_id = v_rec.from_user
           AND content = '[redpacket]' || v_rec.id || '|' || v_rec.amount || '[/redpacket]';

        v_refunded := v_refunded + 1;
    END LOOP;
    RETURN v_refunded;
END;
$$;

-- 5. 定时任务：每天自动退回过期红包（北京时间 02:00 = UTC 18:00）
DO $$
BEGIN
    BEGIN
        PERFORM cron.schedule('redpacket-refund-daily', '0 18 * * *',
            'SELECT public.refund_expired_redpackets()');
    EXCEPTION WHEN others THEN
        NULL;   -- pg_cron 不可用时跳过（不影响主功能）
    END;
END $$;

-- 6. 转账记录查询（最近 50 条，含状态）
-- 注意：旧版返回类型无 status 列，必须先 DROP 再重建
DROP FUNCTION IF EXISTS public.get_my_transfers(uuid);
CREATE OR REPLACE FUNCTION public.get_my_transfers(p_user uuid)
RETURNS TABLE (direction text, other_username text, amount integer,
               status text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT CASE WHEN t.from_user = p_user THEN 'out' ELSE 'in' END,
           pr.username,
           t.amount,
           t.status,
           t.created_at
      FROM public.transfers t
      JOIN public.profiles pr
        ON pr.id = CASE WHEN t.from_user = p_user THEN t.to_user ELSE t.from_user END
     WHERE t.from_user = p_user OR t.to_user = p_user
     ORDER BY t.id DESC
     LIMIT 50;
END;
$$;

-- 7. 权限
GRANT EXECUTE ON FUNCTION public.transfer_nb(uuid, uuid, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.claim_redpacket(bigint, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.refund_expired_redpackets() TO anon;
GRANT EXECUTE ON FUNCTION public.get_my_transfers(uuid) TO anon;
