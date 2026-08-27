-- ============================================================
-- NB频道 - 清理旧 UI 后端残留（纯新 UI 重构后）
-- 在 Supabase SQL Editor 中执行（幂等）
-- ============================================================

-- 1. 删除 set_ui_version RPC（前端已不再调用）
DROP FUNCTION IF EXISTS public.set_ui_version(uuid, text);

-- 2. profiles.ui_version 列：保留（历史数据无害），但不再被读写
--    如需彻底删除（不推荐，可能影响其他引用），取消下面注释：
-- ALTER TABLE public.profiles DROP COLUMN IF EXISTS ui_version;

-- 3. 验证：应返回 0 行
SELECT proname FROM pg_proc
 WHERE proname = 'set_ui_version' AND pronamespace = 'public'::regnamespace;
