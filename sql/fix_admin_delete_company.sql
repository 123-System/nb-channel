-- ============================================================
-- fix_admin_delete_company.sql
-- 修复:后台"删除公司"提示成功但公司仍在(库内函数为旧版)。
-- 执行:在 Supabase SQL Editor 整段运行一次,会覆盖为当前正确版本
-- (删除 user_companies + 清理 support_rules/reports/verified_users/holdings)。
-- 验证:后台再删一家公司,应提示成功且列表中消失;
--       也可先执行下面 SELECT 查看库内函数源码,与我仓库 pythonanywhere 同源对比:
--       SELECT prosrc FROM pg_proc WHERE proname = 'admin_delete_company';
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_delete_company(p_company_id bigint, p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID;
    v_company_name TEXT;
BEGIN
    IF NOT public._admin_token_valid(p_token) THEN
        RETURN jsonb_build_object('success', false, 'message', '登录已过期，请重新登录');
    END IF;

    -- 查找公司
    SELECT user_id, company_name INTO v_user_id, v_company_name
    FROM public.user_companies
    WHERE id = p_company_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', format('公司 ID %s 不存在', p_company_id));
    END IF;

    -- 删除公司
    DELETE FROM public.user_companies WHERE id = p_company_id;
    -- 删除自动支持规则
    DELETE FROM public.support_rules WHERE company_id = p_company_id;
    -- 删除该公司的所有举报（target_type = 'company'）
    DELETE FROM public.reports WHERE company_id = p_company_id AND target_type = 'company';
    -- 删除蓝标
    DELETE FROM public.verified_users WHERE user_id = v_user_id;
    -- 清空该公司的股东持仓（股票作废）
    DELETE FROM public.holdings WHERE company_id = p_company_id;

    RETURN jsonb_build_object('success', true, 'message', format('公司「%s」已删除', v_company_name));
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_delete_company(bigint, text) TO anon;
