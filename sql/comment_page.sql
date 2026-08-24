-- ============================================================
-- NB频道 - 评论区终极优化：单 RPC 返回整页数据
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 把评论区的多次前端查询合并为 1 次数据库调用：
-- 分页主评论 + 回复 + 作者资料 + 点赞数 + 佩戴称号 + 公司徽章
-- ============================================================

-- 配套索引（幂等）
CREATE INDEX IF NOT EXISTS idx_comments_page_lookup
    ON public.comments (page_path, parent_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_comment_reactions_comment
    ON public.comment_reactions (comment_id);

-- 单页评论聚合查询
-- 返回：{ success, total, comments: [...] }
-- comments 顺序：主评论在前（最新优先），随后是各主评论的回复（按时间倒序）
CREATE OR REPLACE FUNCTION public.get_comment_page(
    p_page_path text,
    p_page integer DEFAULT 1,
    p_page_size integer DEFAULT 15,
    p_viewer_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_total integer;
    v_result jsonb;
BEGIN
    -- 主评论总数
    SELECT count(*) INTO v_total
      FROM public.comments
     WHERE page_path = p_page_path AND parent_id IS NULL;

    -- 本页主评论（最新优先）
    WITH page_mains AS (
        SELECT id
          FROM public.comments
         WHERE page_path = p_page_path AND parent_id IS NULL
         ORDER BY created_at DESC, id DESC
         LIMIT p_page_size OFFSET (p_page - 1) * p_page_size
    ),
    -- 本页主评论 + 其全部回复（回复不做分页，全部随主评论返回）
    all_rows AS (
        SELECT c.*, pr.username AS author_name, pr.avatar_url AS author_avatar
          FROM public.comments c
          JOIN public.profiles pr ON pr.id = c.user_id
         WHERE c.page_path = p_page_path
           AND (c.parent_id IS NULL AND c.id IN (SELECT id FROM page_mains)
             OR c.parent_id IN (SELECT id FROM page_mains))
    ),
    -- 点赞聚合（只算本页涉及的评论）
    reacts AS (
        SELECT cr.comment_id,
               count(*) FILTER (WHERE cr.reaction = 1) AS likes,
               count(*) FILTER (WHERE cr.reaction = -1) AS dislikes,
               bool_or(cr.user_id = p_viewer_id AND cr.reaction = 1) AS my_like,
               bool_or(cr.user_id = p_viewer_id AND cr.reaction = -1) AS my_dislike
          FROM public.comment_reactions cr
         WHERE cr.comment_id IN (SELECT id FROM all_rows)
         GROUP BY cr.comment_id
    ),
    -- 作者公司徽章（每个用户最多取一条，避免 LEFT JOIN 重复行）
    companies AS (
        SELECT DISTINCT ON (uc.user_id) uc.user_id, uc.company_name, uc.verified
          FROM public.user_companies uc
         WHERE uc.user_id IN (SELECT DISTINCT user_id FROM all_rows)
         ORDER BY uc.user_id
    ),
    -- 作者佩戴称号
    titles AS (
        SELECT p.id AS user_id, t.key AS title_key, t.name AS title_name,
               t.image_url AS title_image, t.icon AS title_icon, ut.stars AS title_stars
          FROM public.profiles p
          JOIN public.titles t ON t.key = p.equipped_title_id
          LEFT JOIN public.user_titles ut ON ut.title_key = t.key AND ut.user_id = p.id
         WHERE p.id IN (SELECT DISTINCT user_id FROM all_rows)
           AND p.equipped_title_id IS NOT NULL
    )
    SELECT jsonb_build_object(
        'success', true,
        'total', v_total,
        'comments', coalesce((
            SELECT jsonb_agg(j ORDER BY grp, grp_key, created_at DESC, id DESC)
            FROM (
                SELECT
                    jsonb_build_object(
                        'id', m.id,
                        'content', m.content,
                        'user_id', m.user_id,
                        'parent_id', m.parent_id,
                        'created_at', m.created_at,
                        'author_name', m.author_name,
                        'author_avatar', m.author_avatar,
                        'likes', coalesce(r.likes, 0),
                        'dislikes', coalesce(r.dislikes, 0),
                        'my_like', coalesce(r.my_like, false),
                        'my_dislike', coalesce(r.my_dislike, false),
                        'company_name', c.company_name,
                        'company_verified', c.verified,
                        'title_key', t.title_key,
                        'title_name', t.title_name,
                        'title_image', t.title_image,
                        'title_icon', t.title_icon,
                        'title_stars', t.title_stars
                    ) AS j,
                    CASE WHEN m.parent_id IS NULL THEN 0 ELSE 1 END AS grp,
                    coalesce(m.parent_id, 0) AS grp_key,
                    m.created_at AS created_at,
                    m.id AS id
                FROM all_rows m
                LEFT JOIN reacts r ON r.comment_id = m.id
                LEFT JOIN companies c ON c.user_id = m.user_id
                LEFT JOIN titles t ON t.user_id = m.user_id
            ) s
        ), '[]'::jsonb)
    ) INTO v_result;

    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_comment_page(text, integer, integer, uuid) TO anon;

-- ============================================================
-- highlight 跳转辅助：定位目标评论所在页码（最新排序）
-- 输入：目标评论 id（若是回复，自动定位到它的父主评论）
-- 返回：{ success, page }
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_comment_page_number(
    p_page_path text,
    p_comment_id bigint,
    p_page_size integer DEFAULT 15
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_parent_id bigint;
    v_main_id   bigint;
    v_created   timestamptz;
    v_rank      integer;
    v_page      integer;
BEGIN
    -- 目标评论；若为回复，取其父主评论
    SELECT parent_id INTO v_parent_id
      FROM public.comments
     WHERE id = p_comment_id AND page_path = p_page_path;

    IF v_parent_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.comments
                        WHERE id = p_comment_id AND page_path = p_page_path) THEN
            RETURN jsonb_build_object('success', false);
        END IF;
        v_main_id := p_comment_id;
    ELSE
        v_main_id := v_parent_id;
    END IF;

    -- 主评论按 created_at DESC, id DESC 排序，统计排在该评论前面的数量
    SELECT created_at INTO v_created FROM public.comments WHERE id = v_main_id;

    SELECT count(*) INTO v_rank
      FROM public.comments
     WHERE page_path = p_page_path AND parent_id IS NULL
       AND (created_at > v_created OR (created_at = v_created AND id > v_main_id));

    v_page := floor(v_rank::numeric / p_page_size) + 1;
    RETURN jsonb_build_object('success', true, 'page', v_page);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_comment_page_number(text, bigint, integer) TO anon;
