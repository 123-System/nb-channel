-- ============================================================
-- NB频道 - Supabase Storage 存储（头像 + 作品文件）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 功能：
--   1) profiles 表新增 avatar_url 列（头像地址）
--   2) 创建存储桶：avatars（公开，头像）、products（私有，作品文件）
--   3) 允许 anon 上传到两个桶（自定义登录体系，anon key 即用户凭据）
-- ============================================================

-- ========== 1. profiles 表加头像列 ==========
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_url text;

-- ========== 2. 创建存储桶（幂等） ==========
INSERT INTO storage.buckets (id, name, public)
VALUES ('avatars', 'avatars', true),
       ('products', 'products', false)
ON CONFLICT (id) DO NOTHING;

-- ========== 3. 上传权限（anon 可向两个桶插入对象） ==========
DROP POLICY IF EXISTS "avatars_anon_insert" ON storage.objects;
CREATE POLICY "avatars_anon_insert" ON storage.objects
    FOR INSERT TO anon WITH CHECK (bucket_id = 'avatars');

DROP POLICY IF EXISTS "products_anon_insert" ON storage.objects;
CREATE POLICY "products_anon_insert" ON storage.objects
    FOR INSERT TO anon WITH CHECK (bucket_id = 'products');

-- ========== 4. 说明 ==========
-- avatars 桶为公开桶：头像直接通过公开 URL 访问
--   https://<项目>.supabase.co/storage/v1/object/public/avatars/<文件名>
-- products 桶为私有桶：下载走 PythonAnywhere /files/<key> 代理
-- 公开桶的公开读取不需要额外策略（public=true 即公开 URL 可读）；
-- 如需删除对象等更多权限，后续按需添加策略。
