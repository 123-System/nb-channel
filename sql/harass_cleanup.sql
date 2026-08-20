-- ============================================================
-- NB频道 - 恶意评论清理 + 后端违禁词拦截
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 功能：
--   1) bad_words 词库表 + 触发器：评论/回复在数据库层直接拦截违禁词
--      （前端拦截可被绕过，触发器是硬防线）
--   2) 一键找出并删除含攻击内容的评论、回复及其关联数据
--   3) 删除发过攻击内容的账号（含其全部关联数据）
-- ============================================================

-- ========== 1. 后端违禁词拦截 ==========
CREATE TABLE IF NOT EXISTS public.bad_words (
    word text PRIMARY KEY
);

-- 初始词库（以后加词：INSERT INTO bad_words (word) VALUES ('新词');）
INSERT INTO public.bad_words (word) VALUES
    ('操你妈'), ('傻逼'), ('废物'), ('脑残'), ('智障'), ('nmsl'), ('吃屎'), ('大粪'),
    ('蟑螂'), ('臭水沟'), ('屁水'), ('呕吐物'), ('全家肉沫'), ('强酸'), ('甲醇'),
    ('放射性'), ('寄生虫'), ('尿液'), ('引战'), ('造谣'), ('骂给'), ('当给'),
    ('无家可归'), ('乱封号'), ('gay'), ('fuck'), ('shit'), ('bitch'),
    ('支那'), ('黑鬼'), ('白皮猪'), ('台巴子'), ('网暴'), ('喷子')
ON CONFLICT (word) DO NOTHING;

CREATE OR REPLACE FUNCTION public.check_comment_bad_words()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_word text;
BEGIN
    FOR v_word IN SELECT word FROM public.bad_words LOOP
        IF position(lower(v_word) in lower(NEW.content)) > 0 THEN
            RAISE EXCEPTION '您的评论包含违禁词，禁止发布';
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_bad_words ON public.comments;
CREATE TRIGGER trg_check_bad_words
BEFORE INSERT OR UPDATE ON public.comments
FOR EACH ROW EXECUTE FUNCTION public.check_comment_bad_words();

-- ========== 2. 先看看哪些评论命中（确认目标，只查不删） ==========
SELECT c.id, p.username, left(c.content, 40) AS 内容预览, c.created_at
FROM public.comments c
JOIN public.profiles p ON p.id = c.user_id
WHERE c.content LIKE '%蟑螂%' OR c.content LIKE '%臭水沟%' OR c.content LIKE '%吃屎%'
   OR c.content LIKE '%大粪%' OR c.content LIKE '%屁水%' OR c.content LIKE '%全家肉沫%'
   OR c.content LIKE '%引战%' OR c.content LIKE '%造谣%' OR c.content LIKE '%骂给%'
   OR c.content LIKE '%当给%' OR c.content LIKE '%乱封号%' OR c.content LIKE '%放射性%'
ORDER BY c.created_at DESC;

-- ========== 3. 删除命中评论 + 删除发帖账号（含全部关联数据） ==========
DO $$
DECLARE
    v_ids uuid[];
    v_company_ids bigint[];
    v_comment_count integer;
BEGIN
    -- 收集发过攻击内容的账号
    SELECT array_agg(DISTINCT c.user_id) INTO v_ids
    FROM public.comments c
    WHERE c.content LIKE '%蟑螂%' OR c.content LIKE '%臭水沟%' OR c.content LIKE '%吃屎%'
       OR c.content LIKE '%大粪%' OR c.content LIKE '%屁水%' OR c.content LIKE '%全家肉沫%'
       OR c.content LIKE '%引战%' OR c.content LIKE '%造谣%' OR c.content LIKE '%骂给%'
       OR c.content LIKE '%当给%' OR c.content LIKE '%乱封号%' OR c.content LIKE '%放射性%';

    IF v_ids IS NULL THEN
        RAISE NOTICE '没有找到攻击评论';
        RETURN;
    END IF;

    -- 删除这些账号的所有评论（含回复）
    DELETE FROM public.comments
     WHERE parent_id IN (SELECT id FROM public.comments WHERE user_id = ANY(v_ids));
    DELETE FROM public.comments WHERE user_id = ANY(v_ids);
    GET DIAGNOSTICS v_comment_count = ROW_COUNT;
    RAISE NOTICE '已删除评论/回复 % 条', v_comment_count;

    -- 关联数据清理
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

    -- 他们的公司（如有）一并清理
    SELECT array_agg(id) INTO v_company_ids
    FROM public.user_companies WHERE user_id = ANY(v_ids);
    IF v_company_ids IS NOT NULL THEN
        DELETE FROM public.support_logs WHERE company_id = ANY(v_company_ids);
        DELETE FROM public.support_rules WHERE company_id = ANY(v_company_ids);
        DELETE FROM public.holdings WHERE company_id = ANY(v_company_ids);
        DELETE FROM public.transactions WHERE company_id = ANY(v_company_ids);
        DELETE FROM public.stock_daily_kline WHERE company_id = ANY(v_company_ids);
        DELETE FROM public.user_companies WHERE user_id = ANY(v_ids);
    END IF;

    DELETE FROM public.profiles WHERE id = ANY(v_ids);
    RAISE NOTICE '已删除 % 个攻击账号', array_length(v_ids, 1);
END $$;
