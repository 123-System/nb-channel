-- ============================================================
-- NB频道 - 作品分享（product_share）数据库脚本 v2
-- 基于真实表结构重写（2026-08-15 导出确认）
-- 说明：products / product_purchases / product_downloads 表已存在，
--       purchase_product / download_product / get_products 函数已存在，
--       本脚本只做：修复表缺陷 + 新建缺失的 create_product + 权限收紧。
-- ============================================================

-- ========== 0. 兜底检查：products.id 缺自增才补序列 ==========
-- 若 id 是 identity 列（自带自增）则自动跳过，避免 ALTER 报错。
DO $$
BEGIN
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

-- ========== 1. 权限：anon 只能读，写入走 RPC ==========
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_downloads ENABLE ROW LEVEL SECURITY;

-- products：允许匿名读（列表/详情）
DROP POLICY IF EXISTS products_read_all ON public.products;
CREATE POLICY products_read_all ON public.products
    FOR SELECT TO anon USING (true);

-- product_purchases：允许匿名读（前端判断"我是否已购买"）
DROP POLICY IF EXISTS product_purchases_read_all ON public.product_purchases;
CREATE POLICY product_purchases_read_all ON public.product_purchases
    FOR SELECT TO anon USING (true);

-- product_downloads：前端无需读，只允许 RPC（SECURITY DEFINER）内部写入
DROP POLICY IF EXISTS product_downloads_read_all ON public.product_downloads;
CREATE POLICY product_downloads_read_all ON public.product_downloads
    FOR SELECT TO anon USING (true);

-- 禁止 anon 直接写（若有旧策略先删）
DROP POLICY IF EXISTS products_insert_anon ON public.products;
DROP POLICY IF EXISTS products_update_anon ON public.products;
DROP POLICY IF EXISTS products_delete_anon ON public.products;
DROP POLICY IF EXISTS product_purchases_insert_anon ON public.product_purchases;
DROP POLICY IF EXISTS product_purchases_delete_anon ON public.product_purchases;

REVOKE INSERT, UPDATE, DELETE ON public.products FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.product_purchases FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.product_downloads FROM anon;

-- ========== 2. RPC：create_product（上传作品，新建） ==========
-- 适配现有 products 表结构（title/description/price/file_url/file_name/file_size/mime_type/author_id/downloads/status）
CREATE OR REPLACE FUNCTION public.create_product(
    p_user_id     uuid,
    p_title       text,
    p_description text,
    p_price       integer,
    p_file_url    text,
    p_file_name   text,
    p_file_size   integer,
    p_mime_type   text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_exists boolean;
    v_product_id  bigint;
BEGIN
    IF p_title IS NULL OR length(trim(p_title)) = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '请输入作品标题');
    END IF;
    IF length(p_title) > 100 THEN
        RETURN jsonb_build_object('success', false, 'message', '标题不能超过100字');
    END IF;
    IF p_description IS NOT NULL AND length(p_description) > 1000 THEN
        RETURN jsonb_build_object('success', false, 'message', '简介不能超过1000字');
    END IF;
    IF p_price IS NULL OR p_price < 0 OR p_price > 999999999 THEN
        RETURN jsonb_build_object('success', false, 'message', '价格需在 0~999999999 之间');
    END IF;
    IF p_file_url IS NULL OR length(p_file_url) = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '文件地址缺失');
    END IF;

    SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id = p_user_id) INTO v_user_exists;
    IF NOT v_user_exists THEN
        RETURN jsonb_build_object('success', false, 'message', '用户不存在或登录已失效');
    END IF;

    INSERT INTO public.products
        (title, description, price, file_url, file_name, file_size, mime_type, author_id, downloads, status)
    VALUES
        (trim(p_title), coalesce(p_description, ''), p_price, p_file_url,
         coalesce(p_file_name, ''), coalesce(p_file_size, 0), coalesce(p_mime_type, ''),
         p_user_id, 0, 'active')
    RETURNING id INTO v_product_id;

    RETURN jsonb_build_object('success', true, 'id', v_product_id);
END;
$$;

-- ========== 3. 权限 ==========
GRANT EXECUTE ON FUNCTION public.create_product(uuid, text, text, integer, text, text, integer, text) TO anon;

-- ========== 4. 说明 ==========
-- purchase_product / download_product / get_products 已存在于你的数据库，本脚本不覆盖。
-- 若之前执行过旧版 product_share.sql 并创建了同名的 create_product/purchase_product，
-- 本脚本已用新版 create_product 覆盖；purchase_product 请用下方语句检查参数：
--   SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'purchase_product';
