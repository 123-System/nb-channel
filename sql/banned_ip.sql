-- ============================================================
-- NB频道 - IP 封禁黑名单
-- 在 Supabase SQL Editor 中执行
-- ============================================================

-- 1. 黑名单表
CREATE TABLE IF NOT EXISTS public.banned_ips (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ip         text NOT NULL UNIQUE,
    reason     text DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.banned_ips ENABLE ROW LEVEL SECURITY;
-- 匿名可读（前端检查用），写入只允许通过管理操作
DROP POLICY IF EXISTS banned_ips_read ON public.banned_ips;
CREATE POLICY banned_ips_read ON public.banned_ips
    FOR SELECT TO anon USING (true);
REVOKE INSERT, UPDATE, DELETE ON public.banned_ips FROM anon;

-- ============================================================
-- 查询刷屏用户信息（把用户名换成实际的）
SELECT id, username, created_at, is_banned
FROM public.profiles
WHERE username = 'NB科技小琪公共号';

-- 注册时间前后10分钟内的注册尝试记录（IP）
-- （registration_attempts 只记 IP 和时间，按时间近似匹配他的注册 IP）
SELECT ip_address, created_at
FROM public.registration_attempts
ORDER BY created_at DESC
LIMIT 20;

-- 找到他的 IP 后，加入黑名单（把 1.2.3.4 换成他的 IP）：
-- INSERT INTO public.banned_ips (ip, reason) VALUES ('1.2.3.4', '评论区刷屏封禁');
-- 查看黑名单：
-- SELECT * FROM public.banned_ips;
-- 解除封禁：
-- DELETE FROM public.banned_ips WHERE ip = '1.2.3.4';
