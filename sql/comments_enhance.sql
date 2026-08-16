-- ============================================================
-- NB频道 - 评论区体验增强（comments-beta.html）
-- 在 Supabase 后台 SQL Editor 中执行本文件
-- 功能：点赞/点踩、编辑评论、级联删除（评论+回复+点赞+通知）
-- ============================================================

-- ========== 1. comment_reactions 表（点赞/点踩） ==========
CREATE TABLE IF NOT EXISTS public.comment_reactions (
    user_id     uuid NOT NULL,
    comment_id  bigint NOT NULL REFERENCES public.comments(id) ON DELETE CASCADE,
    reaction    smallint NOT NULL DEFAULT 1 CHECK (reaction IN (1, -1)),  -- 1=赞 -1=踩
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, comment_id)
);

COMMENT ON TABLE public.comment_reactions IS '评论点赞/点踩';

CREATE INDEX IF NOT EXISTS idx_comment_reactions_comment
    ON public.comment_reactions (comment_id);

ALTER TABLE public.comment_reactions ENABLE ROW LEVEL SECURITY;

-- anon 可读（前端要显示计数和自己的选择）
DROP POLICY IF EXISTS comment_reactions_read_all ON public.comment_reactions;
CREATE POLICY comment_reactions_read_all ON public.comment_reactions
    FOR SELECT TO anon USING (true);

-- 禁止 anon 直接写（通过 RPC）
REVOKE INSERT, UPDATE, DELETE ON public.comment_reactions FROM anon;

-- ========== 2. RPC：toggle_comment_reaction（点赞/点踩/取消） ==========
-- p_reaction: 1=点赞 -1=点踩 0=取消
CREATE OR REPLACE FUNCTION public.toggle_comment_reaction(
    p_user_id    uuid,
    p_comment_id bigint,
    p_reaction   integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_existing integer;
    v_likes    bigint;
    v_dislikes bigint;
BEGIN
    IF p_reaction NOT IN (1, -1, 0) THEN
        RETURN jsonb_build_object('success', false, 'message', '无效的操作');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.comments WHERE id = p_comment_id) THEN
        RETURN jsonb_build_object('success', false, 'message', '评论不存在');
    END IF;

    SELECT reaction INTO v_existing FROM public.comment_reactions
     WHERE user_id = p_user_id AND comment_id = p_comment_id;

    IF p_reaction = 0 THEN
        -- 取消：删除已有反应
        DELETE FROM public.comment_reactions
         WHERE user_id = p_user_id AND comment_id = p_comment_id;
    ELSIF v_existing IS NULL THEN
        -- 新增反应
        INSERT INTO public.comment_reactions (user_id, comment_id, reaction)
        VALUES (p_user_id, p_comment_id, p_reaction);
    ELSIF v_existing = p_reaction THEN
        -- 再次点击相同按钮 = 取消
        DELETE FROM public.comment_reactions
         WHERE user_id = p_user_id AND comment_id = p_comment_id;
    ELSE
        -- 切换赞/踩
        UPDATE public.comment_reactions
           SET reaction = p_reaction
         WHERE user_id = p_user_id AND comment_id = p_comment_id;
    END IF;

    SELECT count(*) FILTER (WHERE reaction = 1),
           count(*) FILTER (WHERE reaction = -1)
      INTO v_likes, v_dislikes
      FROM public.comment_reactions
     WHERE comment_id = p_comment_id;

    RETURN jsonb_build_object(
        'success', true,
        'likes', v_likes,
        'dislikes', v_dislikes
    );
END;
$$;

-- ========== 3. RPC：update_comment（编辑自己的评论） ==========
CREATE OR REPLACE FUNCTION public.update_comment(
    p_user_id    uuid,
    p_comment_id bigint,
    p_content    text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_updated integer;
BEGIN
    IF p_content IS NULL OR length(trim(p_content)) = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '内容不能为空');
    END IF;
    IF length(p_content) > 200 THEN
        RETURN jsonb_build_object('success', false, 'message', '内容不能超过200字');
    END IF;

    UPDATE public.comments
       SET content = trim(p_content)
     WHERE id = p_comment_id AND user_id = p_user_id;
    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF v_updated = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '只能编辑自己的评论');
    END IF;
    RETURN jsonb_build_object('success', true);
END;
$$;

-- ========== 4. RPC：delete_comment_cascade（级联删除） ==========
-- 删除评论 + 其全部回复 + 相关点赞记录 + 相关通知
CREATE OR REPLACE FUNCTION public.delete_comment_cascade(
    p_user_id    uuid,
    p_comment_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_ids bigint[];
    v_updated integer;
BEGIN
    -- 校验归属：只能删自己的评论
    UPDATE public.comments SET content = content
     WHERE id = p_comment_id AND user_id = p_user_id;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '只能删除自己的评论');
    END IF;

    -- 收集要删除的评论 id（自己 + 所有子孙回复）
    WITH RECURSIVE tree AS (
        SELECT id FROM public.comments WHERE id = p_comment_id
        UNION ALL
        SELECT c.id FROM public.comments c
        JOIN tree t ON c.parent_id = t.id
    )
    SELECT array_agg(id) INTO v_ids FROM tree;

    -- 删除通知（来源评论在被删集合中）
    DELETE FROM public.notifications
     WHERE source_comment_id = ANY (v_ids);

    -- 删除点赞记录（外键级联会自动删，这里显式删一次以防外键缺失）
    DELETE FROM public.comment_reactions WHERE comment_id = ANY (v_ids);

    -- 删除评论（回复因外键级联一并删除）
    DELETE FROM public.comments WHERE id = ANY (v_ids);

    RETURN jsonb_build_object('success', true, 'deleted', array_length(v_ids, 1));
END;
$$;

-- ========== 5. 权限 ==========
GRANT EXECUTE ON FUNCTION public.toggle_comment_reaction(uuid, bigint, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.update_comment(uuid, bigint, text) TO anon;
GRANT EXECUTE ON FUNCTION public.delete_comment_cascade(uuid, bigint) TO anon;

-- ========== 6. 备注 ==========
-- comments 表需要允许"级联删除"依赖的外键关系；
-- 若 comments 表的 parent_id 没有外键约束（大概率没有），
-- 上面 DELETE FROM comments WHERE id = ANY(v_ids) 会直接删除全部被收集的 id，
-- 无需外键也能工作（因为是显式递归收集了所有子孙）。
-- 若 comments 表已有 ON DELETE CASCADE 外键，删除主评论时会自动删回复，同样没问题。
