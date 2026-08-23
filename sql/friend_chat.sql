-- ============================================================
-- NB频道 - 好友系统 + 实时私信（全套）
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 功能：
--   1) 好友：搜索/申请/同意/拒绝/删除/拉黑
--   2) 私信：会话/发送/历史/已读/未读（Realtime 实时）
-- 安全：所有写操作走 SECURITY DEFINER RPC，校验好友关系与封禁/拉黑状态
-- ============================================================

-- ========== 1. 表结构 ==========

-- 拉黑
CREATE TABLE IF NOT EXISTS public.blocked_users (
    user_id    uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    blocked_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, blocked_id)
);

-- 好友申请
CREATE TABLE IF NOT EXISTS public.friend_requests (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    to_user_id   uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    status       text NOT NULL DEFAULT 'pending',   -- pending / accepted / rejected
    created_at   timestamptz NOT NULL DEFAULT now(),
    responded_at timestamptz
);

-- 好友关系（user_a < user_b 规范化存储，双向查询）
CREATE TABLE IF NOT EXISTS public.friendships (
    user_a     uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    user_b     uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_a, user_b),
    CHECK (user_a < user_b)
);

-- 会话（user_low < user_high）
CREATE TABLE IF NOT EXISTS public.conversations (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_low       uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    user_high      uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    last_message_at timestamptz NOT NULL DEFAULT now(),
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_low, user_high)
);

-- 消息
CREATE TABLE IF NOT EXISTS public.messages (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conversation_id bigint NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
    sender_id       uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    content         text NOT NULL,
    is_read         boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON public.messages (conversation_id, id);

-- RLS：全部关闭直接访问，只走 RPC
ALTER TABLE public.blocked_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.friend_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.friendships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.blocked_users FROM anon;
REVOKE ALL ON public.friend_requests FROM anon;
REVOKE ALL ON public.friendships FROM anon;
REVOKE ALL ON public.conversations FROM anon;
REVOKE ALL ON public.messages FROM anon;

-- ========== 2. 工具函数 ==========

-- 是否好友
CREATE OR REPLACE FUNCTION public.is_friend(p_a uuid, p_b uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.friendships
        WHERE (user_a = LEAST(p_a, p_b) AND user_b = GREATEST(p_a, p_b))
    );
$$;

-- 是否被拉黑（任一方向）
CREATE OR REPLACE FUNCTION public.is_blocked(p_a uuid, p_b uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.blocked_users
        WHERE (user_id = p_a AND blocked_id = p_b)
           OR (user_id = p_b AND blocked_id = p_a)
    );
$$;

-- ========== 3. 好友 RPC ==========

-- 搜索用户（按用户名模糊，排除自己和已拉黑）
CREATE OR REPLACE FUNCTION public.search_users(p_keyword text, p_user_id uuid)
RETURNS TABLE (id uuid, username text, avatar_url text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT pr.id, pr.username, pr.avatar_url
      FROM public.profiles pr
     WHERE pr.username ILIKE '%' || p_keyword || '%'
       AND pr.id <> p_user_id
       AND NOT pr.is_banned
       AND NOT public.is_blocked(p_user_id, pr.id)
     ORDER BY pr.username
     LIMIT 20;
END;
$$;

-- 发送好友申请
CREATE OR REPLACE FUNCTION public.send_friend_request(p_from uuid, p_to uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_exists boolean;
BEGIN
    IF p_from = p_to THEN
        RETURN jsonb_build_object('success', false, 'message', '不能添加自己为好友');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_to AND NOT is_banned) THEN
        RETURN jsonb_build_object('success', false, 'message', '用户不存在或已封禁');
    END IF;
    IF public.is_blocked(p_from, p_to) THEN
        RETURN jsonb_build_object('success', false, 'message', '无法发送申请');
    END IF;
    IF public.is_friend(p_from, p_to) THEN
        RETURN jsonb_build_object('success', false, 'message', '你们已经是好友了');
    END IF;
    SELECT EXISTS (
        SELECT 1 FROM public.friend_requests
        WHERE from_user_id = p_from AND to_user_id = p_to AND status = 'pending'
    ) INTO v_exists;
    IF v_exists THEN
        RETURN jsonb_build_object('success', false, 'message', '申请已发送，请等待对方处理');
    END IF;

    INSERT INTO public.friend_requests (from_user_id, to_user_id)
    VALUES (p_from, p_to);
    RETURN jsonb_build_object('success', true, 'message', '好友申请已发送');
END;
$$;

-- 收到的好友申请（pending）
CREATE OR REPLACE FUNCTION public.get_friend_requests(p_user_id uuid)
RETURNS TABLE (id bigint, from_user_id uuid, from_username text, from_avatar text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT fr.id, fr.from_user_id, pr.username, pr.avatar_url, fr.created_at
      FROM public.friend_requests fr
      JOIN public.profiles pr ON pr.id = fr.from_user_id
     WHERE fr.to_user_id = p_user_id AND fr.status = 'pending'
     ORDER BY fr.created_at DESC;
END;
$$;

-- 处理申请（同意/拒绝）
CREATE OR REPLACE FUNCTION public.respond_friend_request(p_request_id bigint, p_user_id uuid, p_accept boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_from uuid;
    v_to uuid;
    v_status text;
BEGIN
    SELECT from_user_id, to_user_id, status INTO v_from, v_to, v_status
      FROM public.friend_requests WHERE id = p_request_id;
    IF v_from IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '申请不存在');
    END IF;
    IF v_to <> p_user_id THEN
        RETURN jsonb_build_object('success', false, 'message', '无权处理该申请');
    END IF;
    IF v_status <> 'pending' THEN
        RETURN jsonb_build_object('success', false, 'message', '该申请已处理');
    END IF;

    IF p_accept THEN
        IF public.is_blocked(v_from, v_to) THEN
            RETURN jsonb_build_object('success', false, 'message', '无法接受（存在拉黑关系）');
        END IF;
        INSERT INTO public.friendships (user_a, user_b)
        VALUES (LEAST(v_from, v_to), GREATEST(v_from, v_to))
        ON CONFLICT DO NOTHING;
    END IF;

    UPDATE public.friend_requests
       SET status = CASE WHEN p_accept THEN 'accepted' ELSE 'rejected' END,
           responded_at = now()
     WHERE id = p_request_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN p_accept THEN '已同意，你们现在是好友了' ELSE '已拒绝' END);
END;
$$;

-- 好友列表
CREATE OR REPLACE FUNCTION public.get_friends(p_user_id uuid)
RETURNS TABLE (user_id uuid, username text, avatar_url text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT pr.id, pr.username, pr.avatar_url
      FROM public.friendships f
      JOIN public.profiles pr ON pr.id = CASE WHEN f.user_a = p_user_id THEN f.user_b ELSE f.user_a END
     WHERE p_user_id IN (f.user_a, f.user_b)
       AND NOT pr.is_banned
     ORDER BY pr.username;
END;
$$;

-- 删除好友
CREATE OR REPLACE FUNCTION public.remove_friend(p_user_id uuid, p_other uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DELETE FROM public.friendships
     WHERE (user_a = LEAST(p_user_id, p_other) AND user_b = GREATEST(p_user_id, p_other));
    RETURN jsonb_build_object('success', true, 'message', '已删除好友');
END;
$$;

-- 拉黑 / 取消拉黑
CREATE OR REPLACE FUNCTION public.block_user(p_user_id uuid, p_target uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_user_id = p_target THEN
        RETURN jsonb_build_object('success', false, 'message', '不能拉黑自己');
    END IF;
    INSERT INTO public.blocked_users (user_id, blocked_id) VALUES (p_user_id, p_target)
    ON CONFLICT DO NOTHING;
    -- 拉黑同时删除好友关系、拒绝双方 pending 申请
    DELETE FROM public.friendships
     WHERE (user_a = LEAST(p_user_id, p_target) AND user_b = GREATEST(p_user_id, p_target));
    UPDATE public.friend_requests SET status = 'rejected', responded_at = now()
     WHERE status = 'pending'
       AND ((from_user_id = p_user_id AND to_user_id = p_target)
         OR (from_user_id = p_target AND to_user_id = p_user_id));
    RETURN jsonb_build_object('success', true, 'message', '已拉黑');
END;
$$;

CREATE OR REPLACE FUNCTION public.unblock_user(p_user_id uuid, p_target uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DELETE FROM public.blocked_users WHERE user_id = p_user_id AND blocked_id = p_target;
    RETURN jsonb_build_object('success', true, 'message', '已取消拉黑');
END;
$$;

-- 黑名单列表（含用户名头像）
CREATE OR REPLACE FUNCTION public.get_blocked_users(p_user_id uuid)
RETURNS TABLE (blocked_id uuid, username text, avatar_url text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT bu.blocked_id, pr.username, pr.avatar_url
      FROM public.blocked_users bu
      JOIN public.profiles pr ON pr.id = bu.blocked_id
     WHERE bu.user_id = p_user_id
     ORDER BY pr.username;
END;
$$;

-- ========== 4. 私信 RPC ==========

-- 获取或创建会话（仅好友）
CREATE OR REPLACE FUNCTION public.get_or_create_conversation(p_user_a uuid, p_user_b uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_conv bigint;
    v_low uuid := LEAST(p_user_a, p_user_b);
    v_high uuid := GREATEST(p_user_a, p_user_b);
BEGIN
    IF NOT public.is_friend(p_user_a, p_user_b) THEN
        RAISE EXCEPTION '只能与好友私信';
    END IF;
    IF public.is_blocked(p_user_a, p_user_b) THEN
        RAISE EXCEPTION '无法私信';
    END IF;
    SELECT id INTO v_conv FROM public.conversations WHERE user_low = v_low AND user_high = v_high;
    IF v_conv IS NULL THEN
        INSERT INTO public.conversations (user_low, user_high) VALUES (v_low, v_high)
        RETURNING id INTO v_conv;
    END IF;
    RETURN v_conv;
END;
$$;

-- 发送消息
CREATE OR REPLACE FUNCTION public.send_message(p_sender uuid, p_conversation_id bigint, p_content text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_low uuid;
    v_high uuid;
    v_other uuid;
    v_id bigint;
BEGIN
    IF p_content IS NULL OR btrim(p_content) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', '消息不能为空');
    END IF;
    IF length(p_content) > 2000 THEN
        RETURN jsonb_build_object('success', false, 'message', '消息不能超过2000字');
    END IF;
    SELECT user_low, user_high INTO v_low, v_high
      FROM public.conversations WHERE id = p_conversation_id;
    IF v_low IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '会话不存在');
    END IF;
    IF p_sender NOT IN (v_low, v_high) THEN
        RETURN jsonb_build_object('success', false, 'message', '不是会话成员');
    END IF;
    IF EXISTS (SELECT 1 FROM public.profiles WHERE id = p_sender AND is_banned) THEN
        RETURN jsonb_build_object('success', false, 'message', '账号已被封禁');
    END IF;
    v_other := CASE WHEN v_low = p_sender THEN v_high ELSE v_low END;
    IF NOT public.is_friend(p_sender, v_other) THEN
        RETURN jsonb_build_object('success', false, 'message', '对方已不是你的好友');
    END IF;
    IF public.is_blocked(p_sender, v_other) THEN
        RETURN jsonb_build_object('success', false, 'message', '无法发送消息');
    END IF;

    INSERT INTO public.messages (conversation_id, sender_id, content)
    VALUES (p_conversation_id, p_sender, btrim(p_content))
    RETURNING id INTO v_id;
    UPDATE public.conversations SET last_message_at = now() WHERE id = p_conversation_id;

    RETURN jsonb_build_object('success', true, 'id', v_id);
END;
$$;

-- 拉取消息（分页：before_id 之前的 p_limit 条，倒序返回）
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
       AND (p_before_id IS NULL OR m.id < p_before_id)
     ORDER BY m.id DESC
     LIMIT p_limit;
END;
$$;

-- 会话列表（含对方信息、最后一条、未读数）
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
           (SELECT m.content FROM public.messages m WHERE m.conversation_id = c.id ORDER BY m.id DESC LIMIT 1),
           c.last_message_at,
           (SELECT count(*) FROM public.messages m
             WHERE m.conversation_id = c.id AND m.sender_id <> p_user AND NOT m.is_read)
      FROM public.conversations c
      JOIN public.profiles pr
        ON pr.id = CASE WHEN c.user_low = p_user THEN c.user_high ELSE c.user_low END
     WHERE p_user IN (c.user_low, c.user_high)
     ORDER BY c.last_message_at DESC;
END;
$$;

-- 标记会话已读
CREATE OR REPLACE FUNCTION public.mark_conversation_read(p_user uuid, p_conversation_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_low uuid;
    v_high uuid;
BEGIN
    SELECT user_low, user_high INTO v_low, v_high
      FROM public.conversations WHERE id = p_conversation_id;
    IF v_low IS NULL OR p_user NOT IN (v_low, v_high) THEN
        RETURN;
    END IF;
    UPDATE public.messages SET is_read = true
     WHERE conversation_id = p_conversation_id AND sender_id <> p_user AND NOT is_read;
END;
$$;

-- 未读消息总数
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
       AND p_user IN (c.user_low, c.user_high);
    RETURN jsonb_build_object('count', v_count);
END;
$$;

-- ========== 5. 权限 ==========
GRANT EXECUTE ON FUNCTION public.is_friend(uuid, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.is_blocked(uuid, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.search_users(text, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.send_friend_request(uuid, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_friend_requests(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.respond_friend_request(bigint, uuid, boolean) TO anon;
GRANT EXECUTE ON FUNCTION public.get_friends(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.remove_friend(uuid, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.block_user(uuid, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.unblock_user(uuid, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_blocked_users(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_or_create_conversation(uuid, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.send_message(uuid, bigint, text) TO anon;
GRANT EXECUTE ON FUNCTION public.get_messages(uuid, bigint, bigint, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.get_conversations(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.mark_conversation_read(uuid, bigint) TO anon;
GRANT EXECUTE ON FUNCTION public.get_unread_messages(uuid) TO anon;

-- ========== 6. Realtime 实时推送 ==========
DO $$
BEGIN
    BEGIN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
    EXCEPTION WHEN duplicate_object THEN NULL;
    END;
END $$;
