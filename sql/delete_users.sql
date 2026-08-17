-- ============================================================
-- NB频道 - 批量删除用户（含所有关联数据）
-- 在 Supabase SQL Editor 中执行
-- 用法：把 v_ids 改成要删除的用户 ID 列表
-- 注意：这些用户拥有的虚拟公司会被删除，其他股东持有的份额一并作废
-- ============================================================

DO $$
DECLARE
    v_ids uuid[] := ARRAY[
        '用户ID1',
        '用户ID2',
        '用户ID3'
    ]::uuid[];
    v_company_ids bigint[];
BEGIN
    -- 收集这些用户拥有的所有公司
    SELECT array_agg(id) INTO v_company_ids
    FROM public.user_companies
    WHERE user_id = ANY(v_ids);

    -- 1. 支持记录（他们支持的 + 他们公司被支持的）
    DELETE FROM public.support_logs
     WHERE supporter_id = ANY(v_ids)
        OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));

    -- 2. 自动支持规则
    DELETE FROM public.support_rules
     WHERE user_id = ANY(v_ids)
        OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));

    -- 3. 持仓（他们的 + 他们公司所有股东的持仓）
    DELETE FROM public.holdings
     WHERE user_id = ANY(v_ids)
        OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));

    -- 4. 交易记录
    DELETE FROM public.transactions
     WHERE user_id = ANY(v_ids)
        OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));

    -- 5. 日K线数据
    DELETE FROM public.stock_daily_kline
     WHERE company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));

    -- 6. 他们的虚拟公司
    DELETE FROM public.user_companies WHERE user_id = ANY(v_ids);

    -- 7. 评论（先删他们的评论下的回复，再删他们的评论）
    DELETE FROM public.comments
     WHERE parent_id IN (SELECT id FROM public.comments WHERE user_id = ANY(v_ids));
    DELETE FROM public.comments WHERE user_id = ANY(v_ids);

    -- 8. 评论点赞记录
    DELETE FROM public.comment_reactions WHERE user_id = ANY(v_ids);

    -- 9. 通知（发给他们的 + 他们发起的）
    DELETE FROM public.notifications
     WHERE user_id = ANY(v_ids) OR from_user_id = ANY(v_ids);

    -- 10. 举报
    DELETE FROM public.reports WHERE reporter_user_id = ANY(v_ids);

    -- 11. 作品购买/下载记录
    DELETE FROM public.product_purchases
     WHERE buyer_id = ANY(v_ids) OR seller_id = ANY(v_ids);
    DELETE FROM public.product_downloads WHERE user_id = ANY(v_ids);

    -- 12. 签到记录
    DELETE FROM public.user_checkins WHERE user_id = ANY(v_ids);
    DELETE FROM public.check_in_records WHERE user_id = ANY(v_ids);

    -- 13. 蓝标
    DELETE FROM public.verified_users WHERE user_id = ANY(v_ids);

    -- 14. 用户本身
    DELETE FROM public.profiles WHERE id = ANY(v_ids);

    RAISE NOTICE '已删除 % 个用户及其全部关联数据', array_length(v_ids, 1);
END $$;
