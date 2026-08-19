-- ============================================================
-- NB频道 - 删除含科普特字母的仿冒账号（自动识别，含全部关联数据）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 背景："小NⲂ"这类账号用科普特字母（U+2C80-U+2CFF）冒充 B。
-- 本脚本自动找出所有用户名含科普特字母的账号并整体删除；
-- 正常账号（如 NB公司）不含科普特字母，不受影响。
-- ============================================================

DO $$
DECLARE
    v_ids uuid[];
    v_company_ids bigint[];
    v_count integer;
BEGIN
    -- 自动识别：用户名含科普特字母（U+2C80-U+2CFF）的账号
    SELECT array_agg(id) INTO v_ids
      FROM public.profiles
     WHERE username ~ ('[' || chr(11392) || '-' || chr(11519) || ']');

    IF v_ids IS NULL THEN
        RAISE NOTICE '未找到含科普特字母的账号';
        RETURN;
    END IF;

    v_count := array_length(v_ids, 1);

    -- 收集这些用户拥有的公司
    SELECT array_agg(id) INTO v_company_ids
    FROM public.user_companies WHERE user_id = ANY(v_ids);

    -- 1. 支持记录
    DELETE FROM public.support_logs
     WHERE supporter_id = ANY(v_ids) OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));
    -- 2. 自动支持规则
    DELETE FROM public.support_rules
     WHERE user_id = ANY(v_ids) OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));
    -- 3. 持仓
    DELETE FROM public.holdings
     WHERE user_id = ANY(v_ids) OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));
    -- 4. 交易记录
    DELETE FROM public.transactions
     WHERE user_id = ANY(v_ids) OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));
    -- 5. 日K线
    DELETE FROM public.stock_daily_kline
     WHERE company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));
    -- 6. 虚拟公司
    DELETE FROM public.user_companies WHERE user_id = ANY(v_ids);
    -- 7. 评论（先回复再本人）
    DELETE FROM public.comments
     WHERE parent_id IN (SELECT id FROM public.comments WHERE user_id = ANY(v_ids));
    DELETE FROM public.comments WHERE user_id = ANY(v_ids);
    -- 8. 点赞
    DELETE FROM public.comment_reactions WHERE user_id = ANY(v_ids);
    -- 9. 通知
    DELETE FROM public.notifications
     WHERE user_id = ANY(v_ids) OR from_user_id = ANY(v_ids);
    -- 10. 举报
    DELETE FROM public.reports WHERE reporter_user_id = ANY(v_ids);
    -- 11. 作品
    DELETE FROM public.product_purchases
     WHERE buyer_id = ANY(v_ids) OR seller_id = ANY(v_ids);
    DELETE FROM public.product_downloads WHERE user_id = ANY(v_ids);
    -- 12. 签到
    DELETE FROM public.user_checkins WHERE user_id = ANY(v_ids);
    DELETE FROM public.check_in_records WHERE user_id = ANY(v_ids);
    -- 13. 抽奖
    DELETE FROM public.lottery_records WHERE user_id = ANY(v_ids);
    -- 14. 蓝标
    DELETE FROM public.verified_users WHERE user_id = ANY(v_ids);
    -- 15. 用户本身
    DELETE FROM public.profiles WHERE id = ANY(v_ids);

    RAISE NOTICE '已删除 % 个仿冒账号及其全部关联数据', v_count;
END $$;
