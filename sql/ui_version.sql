-- ============================================================
-- NB频道 - 界面版本偏好（后端存储，新版/旧版页面分离 + 自动跳转）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 机制：
--   profiles.ui_version = 'new' | 'old'（默认 'new'）
--   前端加载时查此值，按偏好自动跳转到 xxx.html / xxx-new.html
-- ============================================================

-- 1. profiles 加界面版本列（幂等，老用户默认新版）
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS ui_version text NOT NULL DEFAULT 'new';

-- 2. 设置界面版本（仅允许 new / old）
CREATE OR REPLACE FUNCTION public.set_ui_version(p_user_id uuid, p_version text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_version NOT IN ('new', 'old') THEN
        RETURN jsonb_build_object('success', false, 'message', '版本参数只能是 new 或 old');
    END IF;
    UPDATE public.profiles SET ui_version = p_version WHERE id = p_user_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', '用户不存在');
    END IF;
    RETURN jsonb_build_object('success', true, 'ui_version', p_version);
END;
$$;

-- 3. 权限（读取走 anon SELECT profiles，无需 RPC）
GRANT EXECUTE ON FUNCTION public.set_ui_version(uuid, text) TO anon;
