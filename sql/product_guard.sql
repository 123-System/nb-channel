-- ============================================================
-- NB频道 - 作品保护（product_guard）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 功能：
--   1) 查出标题/简介含违禁词的作品（先看再删）
--   2) 删除违规作品（只删作品及其购买/下载记录，不动用户）
--   3) 标题/简介字数限制 + 违禁词检测（数据库层硬防线）
-- ============================================================

-- ========== 1. 违禁词检测辅助函数 ==========
CREATE OR REPLACE FUNCTION public.has_bad_words(p_text text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
    v_word text;
BEGIN
    IF p_text IS NULL OR btrim(p_text) = '' THEN
        RETURN false;
    END IF;
    FOR v_word IN SELECT word FROM public.bad_words LOOP
        IF position(lower(v_word) in lower(p_text)) > 0 THEN
            RETURN true;
        END IF;
    END LOOP;
    RETURN false;
END;
$$;

-- ========== 2. 【先查】标题/简介含违禁词的作品 ==========
-- SELECT id, title, author_id, created_at
--   FROM public.products
--  WHERE status = 'active'
--    AND (has_bad_words(title) OR has_bad_words(description));

-- ========== 3. 【删除】只删违规作品（含购买/下载记录，不动用户） ==========
-- 确认清单后执行：
-- DELETE FROM public.product_purchases
--  WHERE product_id IN (SELECT id FROM public.products
--                        WHERE has_bad_words(title) OR has_bad_words(description));
-- DELETE FROM public.product_downloads
--  WHERE product_id IN (SELECT id FROM public.products
--                        WHERE has_bad_words(title) OR has_bad_words(description));
-- DELETE FROM public.products
--  WHERE has_bad_words(title) OR has_bad_words(description);

-- ========== 4. 重建 create_product：标题≤20字/2行，简介≤100字/10行，禁违禁词 ==========
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
    IF length(trim(p_title)) > 20 THEN
        RETURN jsonb_build_object('success', false, 'message', '标题不能超过20字');
    END IF;
    IF array_length(string_to_array(p_title, E'\n'), 1) > 2 THEN
        RETURN jsonb_build_object('success', false, 'message', '标题最多2行');
    END IF;
    IF public.has_bad_words(p_title) OR public.has_bad_words(p_description) THEN
        RETURN jsonb_build_object('success', false, 'message', '标题或简介包含违禁词，禁止发布');
    END IF;
    IF p_description IS NOT NULL AND length(trim(p_description)) > 100 THEN
        RETURN jsonb_build_object('success', false, 'message', '简介不能超过100字');
    END IF;
    IF p_description IS NOT NULL AND array_length(string_to_array(p_description, E'\n'), 1) > 10 THEN
        RETURN jsonb_build_object('success', false, 'message', '简介最多10行');
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

-- ========== 5. 重建 edit_product：同样的字数/行数/违禁词限制 ==========
CREATE OR REPLACE FUNCTION public.edit_product(
    p_product_id   bigint,
    p_user_id      uuid,
    p_title        text,
    p_description  text,
    p_price        integer,
    p_file_url     text,
    p_file_name    text,
    p_file_size    integer,
    p_mime_type    text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_owner uuid;
BEGIN
    SELECT author_id INTO v_owner FROM public.products WHERE id = p_product_id;
    IF v_owner IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '作品不存在');
    END IF;
    IF v_owner <> p_user_id THEN
        RETURN jsonb_build_object('success', false, 'message', '只能编辑自己的作品');
    END IF;
    IF p_title IS NULL OR length(trim(p_title)) = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '请输入作品标题');
    END IF;
    IF length(trim(p_title)) > 20 THEN
        RETURN jsonb_build_object('success', false, 'message', '标题不能超过20字');
    END IF;
    IF array_length(string_to_array(p_title, E'\n'), 1) > 2 THEN
        RETURN jsonb_build_object('success', false, 'message', '标题最多2行');
    END IF;
    IF public.has_bad_words(p_title) OR public.has_bad_words(p_description) THEN
        RETURN jsonb_build_object('success', false, 'message', '标题或简介包含违禁词，禁止发布');
    END IF;
    IF p_description IS NOT NULL AND length(trim(p_description)) > 100 THEN
        RETURN jsonb_build_object('success', false, 'message', '简介不能超过100字');
    END IF;
    IF p_description IS NOT NULL AND array_length(string_to_array(p_description, E'\n'), 1) > 10 THEN
        RETURN jsonb_build_object('success', false, 'message', '简介最多10行');
    END IF;
    IF p_price IS NULL OR p_price < 0 OR p_price > 999999999 THEN
        RETURN jsonb_build_object('success', false, 'message', '价格需在 0~999999999 之间');
    END IF;

    UPDATE public.products SET
        title = trim(p_title),
        description = coalesce(p_description, ''),
        price = p_price,
        file_url = coalesce(p_file_url, file_url),
        file_name = coalesce(p_file_name, file_name),
        file_size = coalesce(p_file_size, file_size),
        mime_type = coalesce(p_mime_type, mime_type)
     WHERE id = p_product_id;
    RETURN jsonb_build_object('success', true, 'message', '修改已保存');
END;
$$;

-- ========== 6. 权限 ==========
GRANT EXECUTE ON FUNCTION public.create_product(uuid, text, text, integer, text, text, integer, text) TO anon;
GRANT EXECUTE ON FUNCTION public.edit_product(bigint, uuid, text, text, integer, text, text, integer, text) TO anon;

-- ========== 7. 重建 purchase_product：修复"买不了付费作品" ==========
-- 原因：INSERT product_purchases 依赖 seller_id 列，若表结构不同会报错。
-- 修复：插入前动态检查列是否存在（兼容不同表结构）。
CREATE OR REPLACE FUNCTION public.purchase_product(
    p_product_id bigint,
    p_buyer_id   uuid,
    p_pay_type   text   DEFAULT 'nb',
    p_company_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_price       integer;
    v_file_url    text;
    v_author_id   uuid;
    v_balance     integer;
    v_pay_type    text := lower(coalesce(p_pay_type, 'nb'));
    v_company_name text;
    v_company_mv  bigint;
    v_has_seller  boolean;
BEGIN
    SELECT price, file_url, author_id INTO v_price, v_file_url, v_author_id
      FROM public.products WHERE id = p_product_id AND status = 'active';
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', '产品不存在或已下架');
    END IF;
    IF v_price <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '免费作品请直接下载');
    END IF;
    IF v_author_id = p_buyer_id THEN
        RETURN jsonb_build_object('success', false, 'message', '不能购买自己的作品');
    END IF;
    IF EXISTS (SELECT 1 FROM public.product_purchases
                WHERE product_id = p_product_id AND buyer_id = p_buyer_id) THEN
        RETURN jsonb_build_object('success', true, 'message', '已购买，直接下载', 'file_url', v_file_url);
    END IF;
    SELECT nb_balance INTO v_balance FROM public.profiles WHERE id = p_buyer_id;
    IF v_balance < v_price THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('NB币余额不足（需 %s NB币）', v_price));
    END IF;
    IF v_pay_type = 'market' THEN
        SELECT company_name, market_value INTO v_company_name, v_company_mv
          FROM public.user_companies WHERE id = p_company_id AND user_id = v_author_id;
        IF v_company_name IS NULL THEN
            RETURN jsonb_build_object('success', false, 'message', '选择的公司不存在或不是该作者的公司');
        END IF;
        IF v_price > v_company_mv THEN
            RETURN jsonb_build_object('success', false, 'message',
                format('加市值不能超过公司当前市值（当前 %s NB币，最多加 %s）', v_company_mv, v_company_mv));
        END IF;
        UPDATE public.profiles SET nb_balance = nb_balance - v_price WHERE id = p_buyer_id;
        UPDATE public.user_companies SET market_value = market_value + v_price WHERE id = p_company_id;
    ELSE
        UPDATE public.profiles SET nb_balance = nb_balance - v_price WHERE id = p_buyer_id;
        UPDATE public.profiles SET nb_balance = nb_balance + v_price WHERE id = v_author_id;
    END IF;
    -- 记录购买（动态兼容表结构：seller_id 列存在才写入）
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'product_purchases' AND column_name = 'seller_id'
    ) INTO v_has_seller;
    IF v_has_seller THEN
        INSERT INTO public.product_purchases (product_id, buyer_id, seller_id, pay_type)
        VALUES (p_product_id, p_buyer_id, v_author_id, v_pay_type);
    ELSE
        INSERT INTO public.product_purchases (product_id, buyer_id, pay_type)
        VALUES (p_product_id, p_buyer_id, v_pay_type);
    END IF;
    INSERT INTO public.product_downloads (product_id, user_id, paid_amount)
    VALUES (p_product_id, p_buyer_id, v_price);
    UPDATE public.products SET downloads = downloads + 1 WHERE id = p_product_id;
    IF v_pay_type = 'market' THEN
        RETURN jsonb_build_object('success', true, 'file_url', v_file_url,
            'message', format('购买成功！已为「%s」加市值 %s NB币（作者余额不变）', v_company_name, v_price));
    END IF;
    RETURN jsonb_build_object('success', true, 'file_url', v_file_url,
        'message', format('购买成功！已向作者支付 %s NB币', v_price));
END;
$$;

GRANT EXECUTE ON FUNCTION public.purchase_product(bigint, uuid, text, bigint) TO anon;
GRANT EXECUTE ON FUNCTION public.purchase_product(bigint, uuid) TO anon;
