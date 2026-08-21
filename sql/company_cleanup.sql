-- ============================================================
-- NB频道 - 清理攻击性公司 + 仿冒账号 + 公司名防线
-- 在 Supabase SQL Editor 中执行本文件
-- 背景：有人在股票市场注册了大量辱骂/攻击公司
--       （如"NB频道只会瞎78封号""NB频道吃屎去吧""切掉nb频道的睾丸"），
--       甚至注册了坐标公司（30.2943, 120.1663，涉嫌泄露位置信息）。
-- 本脚本：
--   1) 列出所有攻击性公司（先确认）
--   2) 删除攻击公司 + 其主人账号（含全部关联数据）
--   3) 公司名防线：注册公司时校验 白名单(中文/字母/数字) + 违禁词
-- ============================================================

-- ========== 1. 先列出攻击性公司（确认目标，只查不删） ==========
SELECT c.id, c.company_name, p.username AS owner_name, c.created_at
FROM public.user_companies c
JOIN public.profiles p ON p.id = c.user_id
WHERE c.company_name LIKE '%吃屎%' OR c.company_name LIKE '%粪%'
   OR c.company_name LIKE '%睾丸%' OR c.company_name LIKE '%鸡巴%'
   OR c.company_name LIKE '%瞎78%' OR c.company_name LIKE '%瞎几把%'
   OR c.company_name LIKE '%瞎鸡巴%' OR c.company_name LIKE '%封号%'
   OR c.company_name LIKE '%切掉%' OR c.company_name LIKE '%坐标%'
   OR c.company_name LIKE '%傻福%'
ORDER BY c.created_at DESC;

-- ========== 2. 删除攻击公司 + 攻击账号（含全部关联数据） ==========
DO $$
DECLARE
    v_ids uuid[];
    v_company_ids bigint[];
    v_count integer;
BEGIN
    -- 攻击账号 = 公司名含攻击词的主人 + 用户名含攻击词的账号
    -- （注意：小NB（NB公司）、小Na（Na公司）为正常用户，不在此列）
    SELECT array_agg(DISTINCT uid) INTO v_ids FROM (
        SELECT c.user_id AS uid
          FROM public.user_companies c
         WHERE c.company_name LIKE '%吃屎%' OR c.company_name LIKE '%粪%'
            OR c.company_name LIKE '%睾丸%' OR c.company_name LIKE '%鸡巴%'
            OR c.company_name LIKE '%瞎78%' OR c.company_name LIKE '%瞎几把%'
            OR c.company_name LIKE '%瞎鸡巴%' OR c.company_name LIKE '%封号%'
            OR c.company_name LIKE '%切掉%' OR c.company_name LIKE '%坐标%'
            OR c.company_name LIKE '%傻福%'
        UNION
        SELECT id FROM public.profiles
         WHERE username LIKE '%吃屎%' OR username LIKE '%睾丸%'
            OR username LIKE '%瞎78%' OR username LIKE '%瞎几把%'
            OR username LIKE '%瞎鸡巴%' OR username LIKE '%封号%'
            OR username LIKE '%傻福%'
    ) t;

    IF v_ids IS NULL THEN
        RAISE NOTICE '没有找到攻击账号';
        RETURN;
    END IF;
    v_count := array_length(v_ids, 1);
    RAISE NOTICE '将处理 % 个攻击账号', v_count;

    -- 收集这些账号拥有的公司
    SELECT array_agg(id) INTO v_company_ids
    FROM public.user_companies WHERE user_id = ANY(v_ids);

    -- 公司关联数据
    IF v_company_ids IS NOT NULL THEN
        DELETE FROM public.support_logs WHERE company_id = ANY(v_company_ids);
        DELETE FROM public.support_rules WHERE company_id = ANY(v_company_ids);
        DELETE FROM public.holdings WHERE company_id = ANY(v_company_ids);
        DELETE FROM public.transactions WHERE company_id = ANY(v_company_ids);
        DELETE FROM public.stock_daily_kline WHERE company_id = ANY(v_company_ids);
        DELETE FROM public.reports WHERE company_id = ANY(v_company_ids) AND target_type = 'company';
        DELETE FROM public.user_companies WHERE user_id = ANY(v_ids);
    END IF;

    -- 账号关联数据
    DELETE FROM public.comments
     WHERE parent_id IN (SELECT id FROM public.comments WHERE user_id = ANY(v_ids));
    DELETE FROM public.comments WHERE user_id = ANY(v_ids);
    DELETE FROM public.comment_reactions WHERE user_id = ANY(v_ids);
    DELETE FROM public.notifications
     WHERE user_id = ANY(v_ids) OR from_user_id = ANY(v_ids);
    DELETE FROM public.reports WHERE reporter_user_id = ANY(v_ids);
    DELETE FROM public.support_logs WHERE supporter_id = ANY(v_ids);
    DELETE FROM public.support_rules WHERE user_id = ANY(v_ids);
    DELETE FROM public.holdings WHERE user_id = ANY(v_ids);
    DELETE FROM public.transactions WHERE user_id = ANY(v_ids);
    DELETE FROM public.lottery_records WHERE user_id = ANY(v_ids);
    DELETE FROM public.user_checkins WHERE user_id = ANY(v_ids);
    DELETE FROM public.check_in_records WHERE user_id = ANY(v_ids);
    DELETE FROM public.product_purchases WHERE buyer_id = ANY(v_ids);
    DELETE FROM public.product_downloads WHERE user_id = ANY(v_ids);
    DELETE FROM public.verified_users WHERE user_id = ANY(v_ids);

    DELETE FROM public.profiles WHERE id = ANY(v_ids);
    RAISE NOTICE '已删除 % 个攻击账号及其全部数据', v_count;
END $$;

-- ========== 3. 公司名防线：注册公司时校验白名单 + 违禁词 ==========
-- 违禁词表（若之前未建过则创建，幂等）
CREATE TABLE IF NOT EXISTS public.bad_words (
    word text PRIMARY KEY
);

-- 补充违禁词（只用于公司名检查，不影响评论区词库）
INSERT INTO public.bad_words (word) VALUES
    ('吃屎'), ('粪'), ('睾丸'), ('鸡巴'), ('瞎78'), ('瞎几把'),
    ('瞎鸡巴'), ('切掉'), ('去死'), ('傻福')
ON CONFLICT (word) DO NOTHING;

-- 改造 register_company：白名单（中文/字母/数字）+ 违禁词检查
CREATE OR REPLACE FUNCTION public.register_company(p_user_id uuid, p_company_name text, p_need_verify boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_is_verified_user BOOLEAN;
    v_clean_name TEXT;
    v_word TEXT;
BEGIN
    -- 清洗零宽/不可见字符
    v_clean_name := regexp_replace(
        coalesce(p_company_name, ''),
        '[' || chr(8203) || chr(8204) || chr(8205) || chr(8206) || chr(8207)
             || chr(65279) || chr(173) || chr(8288) || chr(12288) || chr(9)
             || chr(10) || chr(13) || chr(32) || ']',
        '', 'g'
    );
    v_clean_name := btrim(v_clean_name);

    -- 白名单：公司名只允许中文、字母、数字（挡掉坐标、特殊符号等怪名）
    IF v_clean_name !~ ('^[' || chr(19968) || '-' || chr(40869) || 'a-zA-Z0-9]+$') THEN
        RETURN jsonb_build_object('success', false, 'message', '公司名称只能包含中文、字母和数字');
    END IF;

    -- 违禁词检查（bad_words 表，可随时加词）
    FOR v_word IN SELECT word FROM public.bad_words LOOP
        IF position(lower(v_word) in lower(v_clean_name)) > 0 THEN
            RETURN jsonb_build_object('success', false, 'message', '公司名称包含违禁词，请更换名称');
        END IF;
    END LOOP;

    -- 公司名称长度限制（1~20字）
    IF length(v_clean_name) < 1 OR length(v_clean_name) > 20 THEN
        RETURN jsonb_build_object('success', false, 'message', '公司名称需在 1~20 字之间');
    END IF;
    IF EXISTS (SELECT 1 FROM user_companies WHERE user_id = p_user_id) THEN
        RETURN jsonb_build_object('success', false, 'message', '您已经注册过公司');
    END IF;

    -- 检查用户是否是蓝标用户
    SELECT EXISTS (
        SELECT 1 FROM verified_users WHERE user_id = p_user_id
    ) INTO v_is_verified_user;

    IF v_is_verified_user THEN
        INSERT INTO user_companies (user_id, company_name, market_value, verified, verification_status)
        VALUES (p_user_id, v_clean_name, 20000, true, 'approved');
        RETURN jsonb_build_object('success', true, 'message', '公司注册成功（已自动认证）', 'need_verify', false);
    END IF;

    IF p_need_verify THEN
        INSERT INTO user_companies (user_id, company_name, market_value, verified, verification_status)
        VALUES (p_user_id, v_clean_name, 20000, false, 'pending');
        RETURN jsonb_build_object('success', true, 'message', '公司注册申请已提交，等待管理员审核', 'need_verify', true);
    ELSE
        INSERT INTO user_companies (user_id, company_name, market_value, verified, verification_status)
        VALUES (p_user_id, v_clean_name, 20000, false, 'none');
        RETURN jsonb_build_object('success', true, 'message', '公司注册成功', 'need_verify', false);
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_company(uuid, text, boolean) TO anon;
