-- ============================================================
-- NB频道 - 私信消息管理：删除（自己视角）/ 撤回 / 取消撤回 / 清空聊天记录
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 功能：
--   1) 删除消息：仅自己视角隐藏（对方仍可见），仅限自己的消息
--   2) 撤回消息：发送 2 分钟内可撤回（双方不可见）
--      红包撤回自动退款：未领取 → 金额退回转出方；已领取 → 无法撤回
--   3) 取消撤回：撤回后 2 分钟内可复原（消息恢复双方可见；
--      红包复原 = 重新扣款并恢复为待领取）
--   4) 清空聊天记录：仅自己视角清空（会话保留，可继续聊天）
-- ============================================================

-- 1. messages 表加列
ALTER TABLE public.messages ADD COLUMN IF NOT EXISTS status      text NOT NULL DEFAULT 'active';  -- active / recalled
ALTER TABLE public.messages ADD COLUMN IF NOT EXISTS recalled_at timestamptz;                     -- 撤回时间（取消撤回窗口判断）
ALTER TABLE public.messages ADD COLUMN IF NOT EXISTS deleted_for uuid[] NOT NULL DEFAULT '{}';     -- 对自己视角不可见的用户列表

-- 2. 删除消息（自己视角，仅限自己的消息）
CREATE OR REPLACE FUNCTION public.delete_my_message(p_user uuid, p_message_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_conv    bigint;
    v_sender  uuid;
BEGIN
    SELECT conversation_id, sender_id INTO v_conv, v_sender
      FROM public.messages WHERE id = p_message_id;
    IF v_conv IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '消息不存在');
    END IF;
    IF v_sender <> p_user THEN
        RETURN jsonb_build_object('success', false, 'message', '只能删除自己发送的消息');
    END IF;
    IF NOT (p_user = ANY(
        (SELECT user_low FROM public.conversations WHERE id = v_conv)
        || (SELECT user_high FROM public.conversations WHERE id = v_conv)
    )) THEN
        RETURN jsonb_build_object('success', false, 'message', '不是会话成员');
    END IF;

    UPDATE public.messages
       SET deleted_for = array_append(deleted_for, p_user)
     WHERE id = p_message_id
       AND NOT (p_user = ANY(deleted_for));
    RETURN jsonb_build_object('success', true, 'message', '已删除（仅自己视角）');
END;
$$;

-- 3. 撤回消息（2 分钟内，双方不可见；红包撤回自动退款）
CREATE OR REPLACE FUNCTION public.recall_message(p_user uuid, p_message_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_conv        bigint;
    v_sender      uuid;
    v_created     timestamptz;
    v_status      text;
    v_content     text;
    v_transfer_id bigint;
    v_amount      integer;
    v_t_status    text;
BEGIN
    SELECT conversation_id, sender_id, created_at, status, content
      INTO v_conv, v_sender, v_created, v_status, v_content
      FROM public.messages WHERE id = p_message_id;
    IF v_conv IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '消息不存在');
    END IF;
    IF v_sender <> p_user THEN
        RETURN jsonb_build_object('success', false, 'message', '只能撤回自己发送的消息');
    END IF;
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'message', '消息已撤回');
    END IF;
    IF v_created < now() - interval '2 minutes' THEN
        RETURN jsonb_build_object('success', false, 'message', '超过2分钟，无法撤回');
    END IF;

    -- 红包消息：检查转账状态
    IF v_content LIKE '[redpacket%' THEN
        v_transfer_id := substring(v_content from '\[redpacket(?:_\w+)?\](\d+)\|')::bigint;
        IF v_transfer_id IS NOT NULL THEN
            SELECT status INTO v_t_status FROM public.transfers WHERE id = v_transfer_id;
            IF v_t_status = 'claimed' THEN
                RETURN jsonb_build_object('success', false, 'message', '红包已被对方领取，无法撤回');
            ELSIF v_t_status = 'pending' THEN
                -- 未领取：退款给转出方
                SELECT amount INTO v_amount FROM public.transfers WHERE id = v_transfer_id;
                UPDATE public.profiles SET nb_balance = nb_balance + v_amount WHERE id = v_sender;
                UPDATE public.transfers
                   SET status = 'refunded', refunded_at = now()
                 WHERE id = v_transfer_id;
            END IF;
            -- refunded（已超时退回）：钱已退，直接撤回消息即可
        END IF;
    END IF;

    UPDATE public.messages SET status = 'recalled', recalled_at = now() WHERE id = p_message_id;
    RETURN jsonb_build_object('success', true, 'message', '已撤回');
END;
$$;

-- 3.5 取消撤回（撤回后 2 分钟内可复原；红包复原 = 重新扣款恢复待领取）
CREATE OR REPLACE FUNCTION public.unrecall_message(p_user uuid, p_message_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_conv        bigint;
    v_sender      uuid;
    v_recalled_at timestamptz;
    v_status      text;
    v_content     text;
    v_transfer_id bigint;
    v_amount      integer;
    v_t_status    text;
BEGIN
    SELECT conversation_id, sender_id, recalled_at, status, content
      INTO v_conv, v_sender, v_recalled_at, v_status, v_content
      FROM public.messages WHERE id = p_message_id;
    IF v_conv IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '消息不存在');
    END IF;
    IF v_sender <> p_user THEN
        RETURN jsonb_build_object('success', false, 'message', '只能复原自己撤回的消息');
    END IF;
    IF v_status <> 'recalled' THEN
        RETURN jsonb_build_object('success', false, 'message', '消息未被撤回');
    END IF;
    IF v_recalled_at IS NULL OR v_recalled_at < now() - interval '2 minutes' THEN
        RETURN jsonb_build_object('success', false, 'message', '已超过2分钟，无法取消撤回');
    END IF;

    -- 红包消息：撤回时若已退款（transfers = refunded），复原需重新扣款恢复 pending
    IF v_content LIKE '[redpacket%' THEN
        v_transfer_id := substring(v_content from '\[redpacket(?:_\w+)?\](\d+)\|')::bigint;
        IF v_transfer_id IS NOT NULL THEN
            SELECT status INTO v_t_status FROM public.transfers WHERE id = v_transfer_id;
            IF v_t_status = 'refunded' THEN
                SELECT amount INTO v_amount FROM public.transfers WHERE id = v_transfer_id;
                UPDATE public.profiles SET nb_balance = nb_balance - v_amount
                 WHERE id = v_sender AND nb_balance >= v_amount;
                IF NOT FOUND THEN
                    RETURN jsonb_build_object('success', false, 'message',
                        format('余额不足，无法恢复红包（需 %s NB币）', v_amount));
                END IF;
                UPDATE public.transfers
                   SET status = 'pending', refunded_at = NULL
                 WHERE id = v_transfer_id;
            END IF;
            -- claimed：撤回时根本不允许撤，不可能出现
        END IF;
    END IF;

    UPDATE public.messages SET status = 'active', recalled_at = NULL WHERE id = p_message_id;
    RETURN jsonb_build_object('success', true, 'message', '已取消撤回');
END;
$$;

-- 4. 清空聊天记录（仅自己视角）
CREATE OR REPLACE FUNCTION public.clear_conversation(p_user uuid, p_conversation_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_low  uuid;
    v_high uuid;
BEGIN
    SELECT user_low, user_high INTO v_low, v_high
      FROM public.conversations WHERE id = p_conversation_id;
    IF v_low IS NULL OR p_user NOT IN (v_low, v_high) THEN
        RETURN jsonb_build_object('success', false, 'message', '会话不存在');
    END IF;

    UPDATE public.messages
       SET deleted_for = array_append(deleted_for, p_user)
     WHERE conversation_id = p_conversation_id
       AND NOT (p_user = ANY(deleted_for));
    RETURN jsonb_build_object('success', true, 'message', '已清空聊天记录（仅自己视角）');
END;
$$;

-- 5. 重定义消息查询：过滤"已撤回"和"对自己隐藏"的消息
CREATE OR REPLACE FUNCTION public.get_messages(p_user uuid, p_conversation_id bigint, p_before_id bigint DEFAULT NULL, p_limit integer DEFAULT 50)
RETURNS TABLE (id bigint, sender_id uuid, content text, is_read boolean, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_low uuid;
    v_high uuid;
BEGIN
    -- 注意：必须用表别名限定 id（RETURNS TABLE 输出列也叫 id，未限定会 ambiguous）
    SELECT c.user_low, c.user_high INTO v_low, v_high
      FROM public.conversations c WHERE c.id = p_conversation_id;
    IF v_low IS NULL OR p_user NOT IN (v_low, v_high) THEN
        RAISE EXCEPTION '不是会话成员';
    END IF;
    RETURN QUERY
    SELECT m.id, m.sender_id, m.content, m.is_read, m.created_at
      FROM public.messages m
     WHERE m.conversation_id = p_conversation_id
       AND m.status <> 'recalled'
       AND NOT (p_user = ANY(m.deleted_for))
       AND (p_before_id IS NULL OR m.id < p_before_id)
     ORDER BY m.id DESC
     LIMIT p_limit;
END;
$$;

-- 6. 重定义会话列表：last_message / 未读数过滤"撤回"和"对自己隐藏"
CREATE OR REPLACE FUNCTION public.get_conversations(p_user uuid)
RETURNS TABLE (conversation_id bigint, other_user_id uuid, other_username text, other_avatar text,
               last_message text, last_message_at timestamptz, unread_count bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT c.id,
           CASE WHEN c.user_low = p_user THEN c.user_high ELSE c.user_low END,
           pr.username, pr.avatar_url,
           (SELECT m.content FROM public.messages m
             WHERE m.conversation_id = c.id
               AND m.status <> 'recalled'
               AND NOT (p_user = ANY(m.deleted_for))
             ORDER BY m.id DESC LIMIT 1),
           c.last_message_at,
           (SELECT count(*) FROM public.messages m
             WHERE m.conversation_id = c.id AND m.sender_id <> p_user AND NOT m.is_read
               AND m.status <> 'recalled'
               AND NOT (p_user = ANY(m.deleted_for)))
      FROM public.conversations c
      JOIN public.profiles pr
        ON pr.id = CASE WHEN c.user_low = p_user THEN c.user_high ELSE c.user_low END
     WHERE p_user IN (c.user_low, c.user_high)
       AND NOT (c.user_low = p_user AND c.a_hidden)
       AND NOT (c.user_high = p_user AND c.b_hidden)
     ORDER BY c.last_message_at DESC;
END;
$$;

-- 7. 重定义未读总数：同样过滤
CREATE OR REPLACE FUNCTION public.get_unread_messages(p_user uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_count bigint;
BEGIN
    SELECT count(*) INTO v_count
      FROM public.messages m
      JOIN public.conversations c ON c.id = m.conversation_id
     WHERE m.sender_id <> p_user AND NOT m.is_read
       AND m.status <> 'recalled'
       AND NOT (p_user = ANY(m.deleted_for))
       AND p_user IN (c.user_low, c.user_high)
       AND NOT (c.user_low = p_user AND c.a_hidden)
       AND NOT (c.user_high = p_user AND c.b_hidden);
    RETURN jsonb_build_object('count', v_count);
END;
$$;

-- 8. 权限
GRANT EXECUTE ON FUNCTION public.delete_my_message(uuid, bigint) TO anon;
GRANT EXECUTE ON FUNCTION public.recall_message(uuid, bigint) TO anon;
GRANT EXECUTE ON FUNCTION public.unrecall_message(uuid, bigint) TO anon;
GRANT EXECUTE ON FUNCTION public.clear_conversation(uuid, bigint) TO anon;
GRANT EXECUTE ON FUNCTION public.get_messages(uuid, bigint, bigint, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.get_conversations(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_unread_messages(uuid) TO anon;
