-- ============================================================
-- NB频道 - 彻底删除用户（含所有关联数据）
-- 在 Supabase SQL Editor 中执行
-- 用法：把 v_uid 改成要删除的用户 ID，然后运行
-- 注意：该用户的虚拟公司会被删除，其他股东持有的该公司份额一并作废
-- ============================================================

DO $$
DECLARE
    v_uid uuid := 'a800484e-640e-43c5-bc64-0fb138018e68';  -- ← 要删除的用户ID（改成你自己的）
    v_company_ids bigint[];
BEGIN
    -- 收集该用户拥有的公司
    SELECT array_agg(id) INTO v_company_ids FROM public.user_companies WHERE user_id = v_uid;

    -- 1. 支持记录（他支持的 + 他公司被支持的）
    DELETE FROM public.support_logs
     WHERE supporter_id = v_uid
        OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));

    -- 2. 自动支持规则
    DELETE FROM public.support_rules
     WHERE user_id = v_uid
        OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));

    -- 3. 持仓（他的 + 他公司所有股东的持仓）
    DELETE FROM public.holdings
     WHERE user_id = v_uid
        OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));

    -- 4. 交易记录
    DELETE FROM public.transactions
     WHERE user_id = v_uid
        OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));

    -- 5. 日K线数据
    DELETE FROM public.stock_daily_kline
     WHERE company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));

    -- 6. 他的虚拟公司
    DELETE FROM public.user_companies WHERE user_id = v_uid;

    -- 7. 评论（先删他的评论下的回复，再删他的评论）
    DELETE FROM public.comments
     WHERE parent_id IN (SELECT id FROM public.comments WHERE user_id = v_uid);
    DELETE FROM public.comments WHERE user_id = v_uid;

    -- 8. 评论点赞记录
    DELETE FROM public.comment_reactions WHERE user_id = v_uid;

    -- 9. 通知（发给他的 + 他发起的）
    DELETE FROM public.notifications WHERE user_id = v_uid OR from_user_id = v_uid;

    -- 10. 举报
    DELETE FROM public.reports WHERE reporter_user_id = v_uid;

    -- 11. 作品购买/下载记录
    DELETE FROM public.product_purchases WHERE buyer_id = v_uid OR seller_id = v_uid;
    DELETE FROM public.product_downloads WHERE user_id = v_uid;

    -- 12. 签到记录
    DELETE FROM public.user_checkins WHERE user_id = v_uid;
    DELETE FROM public.check_in_records WHERE user_id = v_uid;

    -- 13. 蓝标
    DELETE FROM public.verified_users WHERE user_id = v_uid;

    -- 14. 用户本身
    DELETE FROM public.profiles WHERE id = v_uid;

    RAISE NOTICE '用户 % 及其全部关联数据已删除', v_uid;
END $$;
