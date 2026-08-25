-- ============================================================
-- 用户主页数据聚合（SECURITY DEFINER，anon 可调用，一次返回全部）
-- 幂等，可重复执行
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_user_home_profile(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result jsonb;
BEGIN
    IF p_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) THEN
        RETURN jsonb_build_object('success', false, 'message', '用户不存在');
    END IF;

    SELECT jsonb_build_object(
        'success', true,
        -- 统计条（不显示金额）
        'stats', jsonb_build_object(
            'titles',   (SELECT count(*) FROM public.user_titles WHERE user_id = p_user_id),
            'achievements', (SELECT count(*) FROM public.user_achievements WHERE user_id = p_user_id),
            'products', (SELECT count(*) FROM public.products WHERE author_id = p_user_id),
            'comments', (SELECT count(*) FROM public.comments WHERE user_id = p_user_id),
            'checkin',  coalesce((SELECT consecutive_days FROM public.user_checkins WHERE user_id = p_user_id), 0),
            'friends',  (SELECT count(*) FROM public.friendships WHERE user_a = p_user_id OR user_b = p_user_id)
        ),
        -- 佩戴称号横幅
        'title', (SELECT jsonb_build_object(
                        'title_key', t.key, 'name', t.name,
                        'image_url', t.image_url, 'icon', t.icon, 'stars', ut.stars)
                    FROM public.profiles p
                    JOIN public.titles t ON t.key = p.equipped_title_id
                    LEFT JOIN public.user_titles ut ON ut.title_key = t.key AND ut.user_id = p_user_id
                   WHERE p.id = p_user_id AND p.equipped_title_id IS NOT NULL),
        -- 全部称号列表（含佩戴标记；每个称号只取最高星级一条，避免历史重复数据）
        'titles_list', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                        'title_key', t.key, 'name', t.name, 'icon', t.icon,
                        'image_url', t.image_url, 'stars', ut.stars,
                        'equipped', (p.equipped_title_id = t.key))
                    ORDER BY ut.stars DESC, t.key)
              FROM (
                  SELECT DISTINCT ON (title_key) title_key, stars
                    FROM public.user_titles
                   WHERE user_id = p_user_id
                   ORDER BY title_key, stars DESC
              ) ut
              JOIN public.titles t ON t.key = ut.title_key
              LEFT JOIN public.profiles p ON p.id = p_user_id), '[]'::jsonb),
        -- 公司徽章
        'company', (SELECT jsonb_build_object(
                        'company_name', company_name, 'verified', verified)
                      FROM public.user_companies WHERE user_id = p_user_id LIMIT 1),
        -- 认证UP主
        'verified', EXISTS (SELECT 1 FROM public.verified_users WHERE user_id = p_user_id),
        -- 封禁
        'banned', (SELECT is_banned FROM public.profiles WHERE id = p_user_id),
        -- 作品列表（最新20个，不含价格）
        'products_list', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                        'id', id, 'title', title,
                        'downloads', downloads, 'created_at', created_at) ORDER BY created_at DESC)
              FROM (SELECT id, title, downloads, created_at FROM public.products
                     WHERE author_id = p_user_id ORDER BY created_at DESC LIMIT 20) s), '[]'::jsonb),
        -- 公司详情
        'company_info', (SELECT jsonb_build_object(
                            'company_name', company_name, 'verified', verified, 'created_at', created_at)
                           FROM public.user_companies WHERE user_id = p_user_id LIMIT 1),
        -- 成就列表
        'achievements_list', coalesce((
            SELECT jsonb_agg(jsonb_build_object('key', ua.achievement_key, 'name', a.name, 'icon', a.icon))
              FROM public.user_achievements ua
              LEFT JOIN public.achievements a ON a.key = ua.achievement_key
             WHERE ua.user_id = p_user_id), '[]'::jsonb)
    ) INTO v_result;

    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_home_profile(uuid) TO anon;
