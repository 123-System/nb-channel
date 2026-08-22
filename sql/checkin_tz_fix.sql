-- ============================================================
-- NB频道 - 签到时区修复（凌晨无法签到）
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 原因：do_check_in / get_checkin_status 用 CURRENT_DATE（数据库 UTC），
--       北京时间凌晨 0:00-8:00 时 UTC 仍是前一天 → 签到判断错乱。
-- 修复：改用 (now() AT TIME ZONE 'Asia/Shanghai')::date（北京时间日期）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.do_check_in(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    last_checkin DATE;
    consecutive INT;
    reward INT;
    new_consecutive INT;
    v_today DATE := (now() AT TIME ZONE 'Asia/Shanghai')::date;   -- 北京时间日期
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
    
    RETURN jsonb_build_object('success', true, 'reward', reward, 'consecutive', new_consecutive);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_checkin_status(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    last_checkin DATE;
    consecutive INT;
    can_checkin BOOLEAN;
    next_bonus INT;
    v_today DATE := (now() AT TIME ZONE 'Asia/Shanghai')::date;   -- 北京时间日期
BEGIN
    SELECT last_checkin_date, consecutive_days INTO last_checkin, consecutive
    FROM user_checkins WHERE user_id = p_user_id;
    
    -- 从未签到
    IF last_checkin IS NULL THEN
        can_checkin := true;
        next_bonus := 100;
        RETURN jsonb_build_object('can_checkin', can_checkin, 'next_bonus', next_bonus);
    END IF;
    
    -- 今天是否已签到
    IF last_checkin = v_today THEN
        can_checkin := false;
        next_bonus := (consecutive + 1) * 100;
        RETURN jsonb_build_object('can_checkin', can_checkin, 'next_bonus', next_bonus);
    END IF;
    
    -- 今天未签到，可以签到
    can_checkin := true;
    IF last_checkin = v_today - 1 THEN
        next_bonus := (consecutive + 1) * 100;
    ELSE
        next_bonus := 100;
    END IF;
    
    RETURN jsonb_build_object('can_checkin', can_checkin, 'next_bonus', next_bonus);
END;
$function$;

-- 权限（保持 anon 可调用）
GRANT EXECUTE ON FUNCTION public.do_check_in(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_checkin_status(uuid) TO anon;
