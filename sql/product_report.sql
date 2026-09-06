-- ============================================================
-- product_report.sql 作品举报支持
-- 执行:在 Supabase SQL Editor 整段运行一次。
-- 内容:1) reports 增加 product_id 列(作品举报)
--       2) 移除可能限制 target_type 的 CHECK(若有)
--       3) 后台"删除作品"管理函数(级联清理购买记录/举报)
-- ============================================================

-- 1) reports 增加作品列
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS product_id bigint;

-- 外键:删除作品时其举报随之删除
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.reports'::regclass AND conname = 'reports_product_id_fkey') THEN
        ALTER TABLE public.reports
            ADD CONSTRAINT reports_product_id_fkey
            FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_reports_product ON public.reports (product_id);

-- 2) 若存在限制 target_type 取值的 CHECK,移除(允许 'product')
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'public.reports'::regclass
          AND contype = 'c'
          AND pg_get_constraintdef(oid) ILIKE '%target_type%'
    LOOP
        EXECUTE format('ALTER TABLE public.reports DROP CONSTRAINT %I', r.conname);
    END LOOP;
END $$;

-- 3) 后台删除作品(管理端,需管理员会话)
CREATE OR REPLACE FUNCTION public.admin_delete_product(p_product_id bigint, p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_title text;
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('success', false, 'message', '登录已过期，请重新登录');
    END IF;
    SELECT title INTO v_title FROM public.products WHERE id = p_product_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', format('作品 ID %s 不存在', p_product_id));
    END IF;
    DELETE FROM public.product_purchases WHERE product_id = p_product_id;
    DELETE FROM public.reports WHERE product_id = p_product_id AND target_type = 'product';
    DELETE FROM public.products WHERE id = p_product_id;
    RETURN jsonb_build_object('success', true, 'message', format('作品「%s」(ID %s) 已删除', v_title, p_product_id));
END $$;

GRANT EXECUTE ON FUNCTION public.admin_delete_product(bigint, text) TO anon;
