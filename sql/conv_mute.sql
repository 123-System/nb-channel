-- ============================================================
-- NB频道 - 私信会话消息免打扰
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 功能：
--   1) conversations 表加 mute_a / mute_b（分别对应 user_low / user_high 视角）
--   2) set_conversation_mute：开启/关闭免打扰
--   3) get_conversations 返回 muted（当前用户视角），前端免打扰会话
--      只显示小红点、不显示未读数字
-- ============================================================

-- 1. 表加列
ALTER TABLE public.conversations ADD COLUMN IF NOT EXISTS mute_a boolean NOT NULL DEFAULT false;
ALTER TABLE public.conversations ADD COLUMN IF NOT EXISTS mute_b boolean NOT NULL DEFAULT false;

-- 2. 设置免打扰
CREATE OR REPLACE FUNCTION public.set_conversation_mute(p_user uuid, p_conversation_id bigint, p_muted boolean)
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

    IF p_user = v_low THEN
        UPDATE public.conversations SET mute_a = coalesce(p_muted, false) WHERE id = p_conversation_id;
    ELSE
        UPDATE public.conversations SET mute_b = coalesce(p_muted, false) WHERE id = p_conversation_id;
    END IF;
    RETURN jsonb_build_object('success', true, 'muted', coalesce(p_muted, false));
END;
$$;

-- 3. 会话列表返回 muted（当前用户视角）
--    返回类型变更（新增 muted 列），需先 DROP 再重建
DROP FUNCTION IF EXISTS public.get_conversations(uuid);
CREATE OR REPLACE FUNCTION public.get_conversations(p_user uuid)
RETURNS TABLE (conversation_id bigint, other_user_id uuid, other_username text, other_avatar text,
               last_message text, last_message_at timestamptz, unread_count bigint, muted boolean)
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
               AND NOT (p_user = ANY(m.deleted_for))),
           CASE WHEN c.user_low = p_user THEN c.mute_a ELSE c.mute_b END
      FROM public.conversations c
      JOIN public.profiles pr
        ON pr.id = CASE WHEN c.user_low = p_user THEN c.user_high ELSE c.user_low END
     WHERE p_user IN (c.user_low, c.user_high)
       AND NOT (c.user_low = p_user AND c.a_hidden)
       AND NOT (c.user_high = p_user AND c.b_hidden)
     ORDER BY c.last_message_at DESC;
END;
$$;

-- 4. 权限
GRANT EXECUTE ON FUNCTION public.set_conversation_mute(uuid, bigint, boolean) TO anon;
GRANT EXECUTE ON FUNCTION public.get_conversations(uuid) TO anon;
