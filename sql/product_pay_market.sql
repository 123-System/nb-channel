-- ============================================================
-- NB频道 - 作品购买支持两种支付方式（product_pay_market）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 新能力：
--   ① 支付方式可选：
--      - 'nb'     ：扣买家 NB币 → 给作者 NB币余额（原逻辑）
--      - 'market' ：扣买家 NB币 → 加到作者指定公司的市值（支持作者冲榜）
--   ② get_author_companies：前端购买时查询作者公司列表（判断能否加市值）
-- ============================================================

-- 0. 建议先确认 product_purchases 列结构（正常应包含 product_id/buyer_id/seller_id）：
--    SELECT column_name FROM information_schema.columns
--    WHERE table_name = 'product_purchases' ORDER BY ordinal_position;

-- 1. 购买记录加支付方式列（幂等，老记录默认 nb）
ALTER TABLE public.product_purchases ADD COLUMN IF NOT EXISTS pay_type text NOT NULL DEFAULT 'nb';

-- ========== 2. 作者公司列表（前端购买弹窗用） ==========
CREATE OR REPLACE FUNCTION public.get_author_companies(p_author_id uuid)
RETURNS TABLE (id bigint, company_name text, market_value bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT id, company_name, market_value
      FROM public.user_companies
     WHERE user_id = p_author_id
     ORDER BY market_value DESC, id;
$$;

-- ========== 3. 购买（支持 pay_type: nb / market） ==========
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
BEGIN
    -- 1. 产品信息
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
    -- 2. 已购买：直接给链接，不重复扣费
    IF EXISTS (SELECT 1 FROM public.product_purchases
                WHERE product_id = p_product_id AND buyer_id = p_buyer_id) THEN
        RETURN jsonb_build_object('success', true, 'message', '已购买，直接下载', 'file_url', v_file_url);
    END IF;
    -- 3. 余额校验
    SELECT nb_balance INTO v_balance FROM public.profiles WHERE id = p_buyer_id;
    IF v_balance < v_price THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('NB币余额不足（需 %s NB币）', v_price));
    END IF;
    -- 4. 支付
    IF v_pay_type = 'market' THEN
        -- 加市值：目标公司必须属于作者
        SELECT company_name, market_value INTO v_company_name, v_company_mv
          FROM public.user_companies WHERE id = p_company_id AND user_id = v_author_id;
        IF v_company_name IS NULL THEN
            RETURN jsonb_build_object('success', false, 'message', '选择的公司不存在或不是该作者的公司');
        END IF;
        -- 防刷：单次加市值不能超过公司当前市值（防止小市值公司被瞬间翻倍）
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
    -- 5. 记录购买/下载
    INSERT INTO public.product_purchases (product_id, buyer_id, seller_id, pay_type)
    VALUES (p_product_id, p_buyer_id, v_author_id, v_pay_type);
    INSERT INTO public.product_downloads (product_id, user_id, paid_amount)
    VALUES (p_product_id, p_buyer_id, v_price);
    UPDATE public.products SET downloads = downloads + 1 WHERE id = p_product_id;
    -- 6. 返回
    IF v_pay_type = 'market' THEN
        RETURN jsonb_build_object('success', true, 'file_url', v_file_url,
            'message', format('购买成功！已为「%s」加市值 %s NB币（作者余额不变）', v_company_name, v_price));
    END IF;
    RETURN jsonb_build_object('success', true, 'file_url', v_file_url,
        'message', format('购买成功！已向作者支付 %s NB币', v_price));
END;
$$;

-- ========== 4. 权限 ==========
GRANT EXECUTE ON FUNCTION public.get_author_companies(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.purchase_product(bigint, uuid, text, bigint) TO anon;
GRANT EXECUTE ON FUNCTION public.purchase_product(bigint, uuid) TO anon;
