-- ============================================================
-- NB频道 - 数据库缺陷修复（db_fixes）
-- 在 Supabase SQL Editor 中执行本文件
-- 修复内容：
--   1) notifications.id / product_downloads.id 没有自增默认值
--      （导致通知触发器插入失败、下载记录插入失败）
--   2) download_product 对"已购付费作品"会重复扣款
-- ============================================================

-- ========== 1. notifications.id 补自增序列 ==========
-- 你的 notify_reply / notify_mentions 触发器 INSERT 时不带 id，
-- 若 id 无默认值会直接报错（消息系统静默失效）。
CREATE SEQUENCE IF NOT EXISTS notifications_id_seq;
ALTER TABLE public.notifications ALTER COLUMN id SET DEFAULT nextval('notifications_id_seq');
SELECT setval('notifications_id_seq', GREATEST((SELECT COALESCE(MAX(id), 1) FROM public.notifications), 1));

-- ========== 2. product_downloads.id 补自增序列 ==========
CREATE SEQUENCE IF NOT EXISTS product_downloads_id_seq;
ALTER TABLE public.product_downloads ALTER COLUMN id SET DEFAULT nextval('product_downloads_id_seq');
SELECT setval('product_downloads_id_seq', GREATEST((SELECT COALESCE(MAX(id), 1) FROM public.product_downloads), 1));

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
