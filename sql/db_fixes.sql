-- ============================================================
-- NB频道 - 数据库缺陷修复（db_fixes）v2
-- 在 Supabase SQL Editor 中执行本文件
-- 修复内容：
--   1) download_product 对"已购付费作品"会重复扣款（真实修复）
--   2) 检查 notifications / product_downloads / products 的 id 是否缺自增
--      （注意：若 id 是 identity 列则自动跳过——identity 列自带自增，无需处理）
-- ============================================================

-- ========== 1. 兜底检查：id 缺自增的才补序列 ==========
-- 只有当 id 既不是 identity、又没有默认值时才会执行 ALTER，
-- 避免对 identity 列执行 SET DEFAULT 报错（42601）。
DO $$
BEGIN
    -- notifications.id
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'notifications'
          AND column_name = 'id'
          AND is_identity = 'NO' AND column_default IS NULL
    ) THEN
        RAISE NOTICE 'notifications.id 已是自增（identity 或有默认值），跳过';
    ELSE
        CREATE SEQUENCE IF NOT EXISTS notifications_id_seq;
        ALTER TABLE public.notifications ALTER COLUMN id SET DEFAULT nextval('notifications_id_seq');
        PERFORM setval('notifications_id_seq', GREATEST((SELECT COALESCE(MAX(id), 1) FROM public.notifications), 1));
        RAISE NOTICE 'notifications.id 已补自增序列';
    END IF;

    -- product_downloads.id
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'product_downloads'
          AND column_name = 'id'
          AND is_identity = 'NO' AND column_default IS NULL
    ) THEN
        RAISE NOTICE 'product_downloads.id 已是自增（identity 或有默认值），跳过';
    ELSE
        CREATE SEQUENCE IF NOT EXISTS product_downloads_id_seq;
        ALTER TABLE public.product_downloads ALTER COLUMN id SET DEFAULT nextval('product_downloads_id_seq');
        PERFORM setval('product_downloads_id_seq', GREATEST((SELECT COALESCE(MAX(id), 1) FROM public.product_downloads), 1));
        RAISE NOTICE 'product_downloads.id 已补自增序列';
    END IF;

    -- products.id
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'products'
          AND column_name = 'id'
          AND is_identity = 'NO' AND column_default IS NULL
    ) THEN
        RAISE NOTICE 'products.id 已是自增（identity 或有默认值），跳过';
    ELSE
        CREATE SEQUENCE IF NOT EXISTS products_id_seq;
        ALTER TABLE public.products ALTER COLUMN id SET DEFAULT nextval('products_id_seq');
        PERFORM setval('products_id_seq', GREATEST((SELECT COALESCE(MAX(id), 1) FROM public.products), 1));
        RAISE NOTICE 'products.id 已补自增序列';
    END IF;
END $$;

-- ========== 3. download_product 修复：已购/作者不再重复扣款 ==========
-- 原逻辑：价格>0 且非作者就扣款，不检查是否已购买 → 重复下载会重复扣费。
-- 修复：① 作者本人下载免费；② 已购买过的直接给链接；③ 免费作品正常记录下载。
CREATE OR REPLACE FUNCTION public.download_product(p_product_id bigint, p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_price INTEGER;
    v_balance INTEGER;
    v_file_url TEXT;
    v_author_id UUID;
BEGIN
    -- 1. 查询产品信息
    SELECT price, file_url, author_id INTO v_price, v_file_url, v_author_id
    FROM products WHERE id = p_product_id AND status = 'active';
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', '产品不存在或已下架');
    END IF;

    -- 2. 付费作品：作者本人免费；已购买过的直接给链接（不重复扣费）
    IF v_price > 0 AND p_user_id <> v_author_id THEN
        IF EXISTS (SELECT 1 FROM product_purchases WHERE product_id = p_product_id AND buyer_id = p_user_id) THEN
            RETURN jsonb_build_object('success', true, 'message', '已购买，直接下载', 'file_url', v_file_url);
        END IF;
        -- 检查下载者余额并扣款
        SELECT nb_balance INTO v_balance FROM profiles WHERE id = p_user_id;
        IF v_balance < v_price THEN
            RETURN jsonb_build_object('success', false, 'message', 'NB币余额不足');
        END IF;
        UPDATE profiles SET nb_balance = nb_balance - v_price WHERE id = p_user_id;
        UPDATE profiles SET nb_balance = nb_balance + v_price WHERE id = v_author_id;
    END IF;

    -- 3. 记录下载
    INSERT INTO product_downloads (product_id, user_id, paid_amount)
    VALUES (p_product_id, p_user_id, v_price);

    -- 4. 更新下载次数
    UPDATE products SET downloads = downloads + 1 WHERE id = p_product_id;

    -- 5. 返回文件 URL
    RETURN jsonb_build_object('success', true, 'file_url', v_file_url);
END;
$$;

GRANT EXECUTE ON FUNCTION public.download_product(bigint, uuid) TO anon;
