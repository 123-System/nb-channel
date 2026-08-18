-- ============================================================
-- NB频道 - 抽奖记录查询 + 公告后台管理
-- 在 Supabase SQL Editor 中执行本文件（需要先执行过 lottery.sql 和 admin_security.sql）
-- 功能：
--   1) get_my_lottery_records：查询"我的抽奖记录"（绕过 anon 对 lottery_records 的封锁）
--   2) admin_update_announcement：管理员更新/清除公告（admin_config 表，key=announcement）
-- ============================================================

-- ========== 1. 我的抽奖记录 ==========
-- 说明：lottery_records 已对 anon 关闭直接访问（REVOKE ALL），
--       所以用 SECURITY DEFINER 函数按 user_id 查询，只返回自己的记录。
CREATE OR REPLACE FUNCTION public.get_my_lottery_records(p_user_id uuid)
RETURNS TABLE (id bigint, result text, amount integer, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT r.id, r.result, r.amount, r.created_at
      FROM public.lottery_records r
     WHERE r.user_id = p_user_id
     ORDER BY r.created_at DESC, r.id DESC;
END;
$$;

-- ========== 2. 管理员：更新/清除公告 ==========
-- p_text 为空字符串时清除公告（删除该行）
CREATE OR REPLACE FUNCTION public.admin_update_announcement(p_token text, p_text text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('success', false, 'message', '登录已过期，请重新登录');
    END IF;

    IF p_text IS NULL OR btrim(p_text) = '' THEN
        DELETE FROM public.admin_config WHERE key = 'announcement';
        RETURN jsonb_build_object('success', true, 'message', '公告已清除');
    END IF;

    -- 先更新，不存在再插入（避免依赖 admin_config 上是否有唯一约束）
    UPDATE public.admin_config SET value = p_text WHERE key = 'announcement';
    IF NOT FOUND THEN
        INSERT INTO public.admin_config (key, value) VALUES ('announcement', p_text);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', '公告已更新');
END;
$$;

-- ========== 3. 权限 ==========
GRANT EXECUTE ON FUNCTION public.get_my_lottery_records(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_update_announcement(text, text) TO anon;
