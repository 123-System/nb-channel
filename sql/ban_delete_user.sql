-- ============================================================
-- NB频道 - 封禁 + 删除用户（按用户名）
-- 在 Supabase SQL Editor 中执行
-- 目标用户：我的世界浩宸
-- 效果：1) 账号封禁（无法登录/发言） 2) 删除该用户全部内容
--       （评论/公司/聊天/银行/称号/抽奖/转账等），profiles 保留以便封禁生效
-- ============================================================

DO $$
DECLARE
    v_ids uuid[];          -- 匹配到的用户ID（支持同名多个）
    v_company_ids bigint[];-- 这些用户拥有的公司
BEGIN
    -- 0. 按用户名查找
    SELECT array_agg(id) INTO v_ids
      FROM public.profiles
     WHERE username = '我的世界浩宸';

    IF v_ids IS NULL OR array_length(v_ids, 1) = 0 THEN
        RAISE EXCEPTION '未找到用户：我的世界浩宸';
    END IF;
    RAISE NOTICE '匹配到 % 个用户', array_length(v_ids, 1);

    -- 收集这些用户拥有的所有公司
    SELECT array_agg(id) INTO v_company_ids
      FROM public.user_companies
     WHERE user_id = ANY(v_ids);

    -- ===== 1. 封禁账号（先封禁，防止删数据期间继续操作） =====
    UPDATE public.profiles
       SET is_banned = true,
           banned_reason = '违规封禁删除'
     WHERE id = ANY(v_ids);

    -- ===== 2. 删除虚拟公司相关数据 =====
    -- 支持记录（他支持的 + 他公司被支持的）
    DELETE FROM public.support_logs
     WHERE supporter_id = ANY(v_ids)
        OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));
    -- 自动支持规则
    DELETE FROM public.support_rules
     WHERE user_id = ANY(v_ids)
        OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));
    -- 持仓（他的 + 他公司所有股东的）
    DELETE FROM public.holdings
     WHERE user_id = ANY(v_ids)
        OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));
    -- 交易记录
    DELETE FROM public.transactions
     WHERE user_id = ANY(v_ids)
        OR company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));
    -- 日K线
    DELETE FROM public.stock_daily_kline
     WHERE company_id = ANY(COALESCE(v_company_ids, ARRAY[]::bigint[]));
    -- 虚拟公司本身
    DELETE FROM public.user_companies WHERE user_id = ANY(v_ids);

    -- ===== 3. 删除评论（先删对他的评论的举报/点赞，再删回复，最后删评论） =====
    DELETE FROM public.reports
     WHERE comment_id IN (SELECT id FROM public.comments WHERE user_id = ANY(v_ids));
    DELETE FROM public.comments
     WHERE parent_id IN (SELECT id FROM public.comments WHERE user_id = ANY(v_ids));
    DELETE FROM public.comments WHERE user_id = ANY(v_ids);
    -- 评论点赞
    DELETE FROM public.comment_reactions WHERE user_id = ANY(v_ids);

    -- ===== 4. 通知 / 举报 =====
    DELETE FROM public.notifications
     WHERE user_id = ANY(v_ids) OR from_user_id = ANY(v_ids);
    DELETE FROM public.reports WHERE reporter_user_id = ANY(v_ids);

    -- ===== 5. 作品（他上传的 + 购买/下载记录） =====
    DELETE FROM public.product_purchases
     WHERE buyer_id = ANY(v_ids) OR seller_id = ANY(v_ids);
    DELETE FROM public.product_downloads WHERE user_id = ANY(v_ids);
    DELETE FROM public.products WHERE author_id = ANY(v_ids);

    -- ===== 6. 成就 =====
    DELETE FROM public.user_achievements WHERE user_id = ANY(v_ids);

    -- ===== 7. 签到 =====
    DELETE FROM public.user_checkins WHERE user_id = ANY(v_ids);
    DELETE FROM public.check_in_records WHERE user_id = ANY(v_ids);

    -- ===== 8. 蓝标 =====
    DELETE FROM public.verified_users WHERE user_id = ANY(v_ids);

    -- ===== 9. 银行（账户+流水） =====
    DELETE FROM public.bank_logs WHERE user_id = ANY(v_ids);
    DELETE FROM public.bank_accounts WHERE user_id = ANY(v_ids);

    -- ===== 10. 称号 =====
    DELETE FROM public.user_titles WHERE user_id = ANY(v_ids);
    DELETE FROM public.user_balance_counts WHERE user_id = ANY(v_ids);

    -- ===== 11. 抽奖 / 转账（含红包）/ 金币 =====
    DELETE FROM public.lottery_records WHERE user_id = ANY(v_ids);
    DELETE FROM public.transfers WHERE from_user = ANY(v_ids) OR to_user = ANY(v_ids);
    DELETE FROM public.coin_claims WHERE user_id = ANY(v_ids);

    -- ===== 12. 好友/私信（级联外键兜底） =====
    DELETE FROM public.messages WHERE sender_id = ANY(v_ids);
    DELETE FROM public.conversations
     WHERE user_low = ANY(v_ids) OR user_high = ANY(v_ids);
    DELETE FROM public.blocked_users
     WHERE user_id = ANY(v_ids) OR blocked_id = ANY(v_ids);
    DELETE FROM public.friend_requests
     WHERE from_user_id = ANY(v_ids) OR to_user_id = ANY(v_ids);
    DELETE FROM public.friendships
     WHERE user_a = ANY(v_ids) OR user_b = ANY(v_ids);

    -- ===== 13. Storage 文件（他上传的作品/头像，owner 即上传者） =====
    DELETE FROM storage.objects WHERE owner = ANY(v_ids);

    RAISE NOTICE '封禁并删除完成（profiles 保留封禁标记）';
END $$;

-- ============================================================
-- 查看结果（确认）
-- ============================================================
SELECT id, username, is_banned, banned_reason, created_at
  FROM public.profiles
 WHERE username = '我的世界浩宸';
