-- ============================================================
-- NB频道 - 消息中心修复：全部已读 / 删除已读
-- 原因：notifications 表 RLS 只允许 authenticated 角色 UPDATE，
--       自建登录（anon）直接 update 会被静默拒绝 → 全部已读无效。
--       改用 SECURITY DEFINER RPC 解决。
-- 在 Supabase SQL Editor 中执行
-- ============================================================

-- 1. 全部标记已读（按类型，p_type 传 NULL 则全部）
CREATE OR REPLACE FUNCTION public.mark_all_notifications_read(
    p_user_id uuid,
    p_type    text DEFAULT NULL::text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_count integer;
BEGIN
    UPDATE public.notifications
       SET is_read = true
     WHERE user_id = p_user_id
       AND (p_type IS NULL OR type = p_type)
       AND is_read = false;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- 2. 删除已读消息（按类型，p_type 传 NULL 则全部）
CREATE OR REPLACE FUNCTION public.delete_read_notifications(
    p_user_id uuid,
    p_type    text DEFAULT NULL::text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_count integer;
BEGIN
    DELETE FROM public.notifications
     WHERE user_id = p_user_id
       AND (p_type IS NULL OR type = p_type)
       AND is_read = true;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_all_notifications_read(uuid, text) TO anon;
GRANT EXECUTE ON FUNCTION public.delete_read_notifications(uuid, text) TO anon;
