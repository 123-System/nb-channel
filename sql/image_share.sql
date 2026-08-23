-- ============================================================
-- NB频道 - 评论/私信图片上传（image_share）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 功能：
--   1) 创建公开存储桶 images（评论区/私信图片）
--   2) 允许 anon 上传/删除（PythonAnywhere 后端 + 前端直传兼容）
-- 图片在消息中以短标记 [img]key[/img] 存储，前端渲染时拼公开 URL
-- ============================================================

-- ========== 1. 创建存储桶（公开，幂等） ==========
INSERT INTO storage.buckets (id, name, public)
VALUES ('images', 'images', true)
ON CONFLICT (id) DO NOTHING;

-- ========== 2. 上传权限（anon + authenticated 都可上传） ==========
DROP POLICY IF EXISTS "images_anon_insert" ON storage.objects;
CREATE POLICY "images_anon_insert" ON storage.objects
    FOR INSERT TO anon, authenticated WITH CHECK (bucket_id = 'images');

-- ========== 3. 删除权限（清理图片时需要） ==========
DROP POLICY IF EXISTS "images_anon_delete" ON storage.objects;
CREATE POLICY "images_anon_delete" ON storage.objects
    FOR DELETE TO anon, authenticated USING (bucket_id = 'images');

-- ========== 4. 说明 ==========
-- images 桶为公开桶：图片直接通过公开 URL 访问
--   https://<项目>.supabase.co/storage/v1/object/public/images/<文件名>
-- 公开桶的公开读取不需要额外策略（public=true 即公开 URL 可读）。
