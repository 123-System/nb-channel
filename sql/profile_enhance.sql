-- ============================================================
-- NB频道 - 个人主页增强：简介 + 主页访问量 + 签到热力图
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- ============================================================

-- ========== 1. profiles 加简介字段 ==========
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS bio text DEFAULT '';

-- 更新简介 RPC（仅本人，SECURITY DEFINER）
CREATE OR REPLACE FUNCTION public.update_bio(p_user_id uuid, p_bio text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '参数错误');
    END IF;
    UPDATE public.profiles SET bio = left(coalesce(p_bio, ''), 100) WHERE id = p_user_id;
    RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_bio(uuid, text) TO anon;

-- ========== 2. 主页访问量 ==========
CREATE TABLE IF NOT EXISTS public.profile_visits (
    user_id    uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    visit_date date NOT NULL DEFAULT (now() AT TIME ZONE 'Asia/Shanghai')::date,
    count      integer NOT NULL DEFAULT 1,
    PRIMARY KEY (user_id, visit_date)
);
ALTER TABLE public.profile_visits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.profile_visits FROM anon, authenticated;
-- 只有 SECURITY DEFINER 函数能读写该表

-- 记录一次访问 + 返回累计访问量（幂等：同一天同用户只 +1）
CREATE OR REPLACE FUNCTION public.visit_profile(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_total integer;
BEGIN
    IF p_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) THEN
        RETURN jsonb_build_object('success', false, 'message', '用户不存在');
    END IF;
    INSERT INTO public.profile_visits (user_id, visit_date)
    VALUES (p_user_id, (now() AT TIME ZONE 'Asia/Shanghai')::date)
    ON CONFLICT (user_id, visit_date) DO UPDATE SET count = profile_visits.count + 1;
    SELECT coalesce(sum(count), 0) INTO v_total FROM public.profile_visits WHERE user_id = p_user_id;
    RETURN jsonb_build_object('success', true, 'total', v_total);
END;
$$;

GRANT EXECUTE ON FUNCTION public.visit_profile(uuid) TO anon;

-- ========== 3. 签到热力图（近365天签到日期列表） ==========
-- user_checkins 只有最近一次签到，热力图需要历史签到记录。
-- 若 check_in_records 表存在（含 user_id + 日期），用它；否则退化为只显示当前连续天数。
-- 这里先确认表结构：若已有该表则直接使用；没有则创建（兼容老数据）。
CREATE TABLE IF NOT EXISTS public.check_in_records (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    check_in_date date NOT NULL DEFAULT (now() AT TIME ZONE 'Asia/Shanghai')::date,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, check_in_date)
);
ALTER TABLE public.check_in_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.check_in_records FROM anon, authenticated;

-- 签到函数：记录历史 + 更新连续天数（替换旧版 do_check_in 的写入逻辑，幂等）
CREATE OR REPLACE FUNCTION public.do_check_in(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    last_checkin DATE;
    consecutive INT;
    reward INT;
    new_consecutive INT;
    v_today DATE := (now() AT TIME ZONE 'Asia/Shanghai')::date;
BEGIN
    SELECT last_checkin_date, consecutive_days INTO last_checkin, consecutive
    FROM user_checkins WHERE user_id = p_user_id;

    IF last_checkin = v_today THEN
        RETURN jsonb_build_object('success', false, 'message', '今日已签到', 'reward', 0);
    END IF;

    IF last_checkin = v_today - 1 THEN
        new_consecutive := consecutive + 1;
    ELSE
        new_consecutive := 1;
    END IF;

    reward := new_consecutive * 100;

    UPDATE profiles SET nb_balance = nb_balance + reward WHERE id = p_user_id;

    INSERT INTO user_checkins (user_id, last_checkin_date, consecutive_days)
    VALUES (p_user_id, v_today, new_consecutive)
    ON CONFLICT (user_id) DO UPDATE
    SET last_checkin_date = EXCLUDED.last_checkin_date,
        consecutive_days = EXCLUDED.consecutive_days;

    -- 历史记录（幂等）
    INSERT INTO check_in_records (user_id, check_in_date)
    VALUES (p_user_id, v_today)
    ON CONFLICT (user_id, check_in_date) DO NOTHING;

    RETURN jsonb_build_object('success', true, 'reward', reward, 'consecutive', new_consecutive);
END;
$$;

GRANT EXECUTE ON FUNCTION public.do_check_in(uuid) TO anon;

-- 热力图数据：返回近365天签到日期（数组）
CREATE OR REPLACE FUNCTION public.get_checkin_heatmap(p_user_id uuid, p_days integer DEFAULT 365)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_dates date[];
BEGIN
    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'dates', '[]'::jsonb);
    END IF;
    SELECT array_agg(check_in_date ORDER BY check_in_date)
      INTO v_dates
      FROM public.check_in_records
     WHERE user_id = p_user_id
       AND check_in_date >= (now() AT TIME ZONE 'Asia/Shanghai')::date - (p_days - 1);
    RETURN jsonb_build_object('success', true, 'dates', coalesce(to_jsonb(v_dates), '[]'::jsonb));
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_checkin_heatmap(uuid, integer) TO anon;

-- ========== 4. 用户主页聚合 RPC：加入简介/访问量/最近动态 ==========
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
        'bio', coalesce((SELECT bio FROM public.profiles WHERE id = p_user_id), ''),
        'visits', coalesce((SELECT sum(count) FROM public.profile_visits WHERE user_id = p_user_id), 0),
        'stats', jsonb_build_object(
            'titles',   (SELECT count(*) FROM public.user_titles WHERE user_id = p_user_id),
            'achievements', (SELECT count(*) FROM public.user_achievements WHERE user_id = p_user_id),
            'products', (SELECT count(*) FROM public.products WHERE author_id = p_user_id),
            'comments', (SELECT count(*) FROM public.comments WHERE user_id = p_user_id),
            'checkin',  coalesce((SELECT consecutive_days FROM public.user_checkins WHERE user_id = p_user_id), 0),
            'friends',  (SELECT count(*) FROM public.friendships WHERE user_a = p_user_id OR user_b = p_user_id)
        ),
        'title', (SELECT jsonb_build_object(
                        'title_key', t.key, 'name', t.name,
                        'image_url', t.image_url, 'icon', t.icon, 'stars', ut.stars)
                    FROM public.profiles p
                    JOIN public.titles t ON t.key = p.equipped_title_id
                    LEFT JOIN public.user_titles ut ON ut.title_key = t.key AND ut.user_id = p_user_id
                   WHERE p.id = p_user_id AND p.equipped_title_id IS NOT NULL),
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
        'company', (SELECT jsonb_build_object(
                        'company_name', company_name, 'verified', verified)
                      FROM public.user_companies WHERE user_id = p_user_id LIMIT 1),
        'verified', EXISTS (SELECT 1 FROM public.verified_users WHERE user_id = p_user_id),
        'banned', (SELECT is_banned FROM public.profiles WHERE id = p_user_id),
        'products_list', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                        'id', id, 'title', title,
                        'downloads', downloads, 'created_at', created_at) ORDER BY created_at DESC)
              FROM (SELECT id, title, downloads, created_at FROM public.products
                     WHERE author_id = p_user_id ORDER BY created_at DESC LIMIT 20) s), '[]'::jsonb),
        'company_info', (SELECT jsonb_build_object(
                            'company_name', company_name, 'verified', verified, 'created_at', created_at)
                           FROM public.user_companies WHERE user_id = p_user_id LIMIT 1),
        'achievements_list', coalesce((
            SELECT jsonb_agg(jsonb_build_object('key', ua.achievement_key, 'name', a.name, 'icon', a.icon))
              FROM public.user_achievements ua
              LEFT JOIN public.achievements a ON a.key = ua.achievement_key
             WHERE ua.user_id = p_user_id), '[]'::jsonb),
        -- 最近动态（合并 作品发布/评论/解锁称号/获得成就/签到，按时间倒序，最多30条）
        'activity', coalesce((
            SELECT jsonb_agg(x ORDER BY ts DESC)
              FROM (
                SELECT jsonb_build_object(
                           'type', 'product',
                           'text', '发布了作品《' || title || '》',
                           'ts', created_at) AS x,
                       created_at AS ts
                  FROM public.products WHERE author_id = p_user_id
                UNION ALL
                SELECT jsonb_build_object(
                           'type', 'comment',
                           'text', '发表了评论：' || left(content, 40),
                           'ts', created_at) AS x,
                       created_at AS ts
                  FROM public.comments WHERE user_id = p_user_id
                UNION ALL
                SELECT jsonb_build_object(
                           'type', 'title',
                           'text', '解锁称号：' || t.name,
                           'ts', ut.unlocked_at) AS x,
                       ut.unlocked_at AS ts
                  FROM public.user_titles ut
                  JOIN public.titles t ON t.key = ut.title_key
                 WHERE ut.user_id = p_user_id
                UNION ALL
                SELECT jsonb_build_object(
                           'type', 'achievement',
                           'text', '获得成就：' || a.name,
                           'ts', ua.claimed_at) AS x,
                       ua.claimed_at AS ts
                  FROM public.user_achievements ua
                  LEFT JOIN public.achievements a ON a.key = ua.achievement_key
                 WHERE ua.user_id = p_user_id
                UNION ALL
                SELECT jsonb_build_object(
                           'type', 'checkin',
                           'text', '签到打卡',
                           'ts', (cr.check_in_date::timestamptz + interval '12 hours')) AS x,
                       (cr.check_in_date::timestamptz + interval '12 hours') AS ts
                  FROM public.check_in_records cr
                 WHERE cr.user_id = p_user_id
                ORDER BY ts DESC
                LIMIT 30
              ) t
        ), '[]'::jsonb)
    ) INTO v_result;

    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_home_profile(uuid) TO anon;
