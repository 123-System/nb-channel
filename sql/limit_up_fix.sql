-- ============================================================
-- NB频道 - 涨跌停补漏：支持/买入也要遵守 ±50% 限制
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 背景：波动引擎有涨停冻结，但 support_company / buy_stock 直接把
--       NB 打进市值，绕过涨跌停 → 出现"已涨停还在涨"（如 314%）。
-- 修复：两函数增加涨停上限检查——已涨停（≥ 开盘价×1.5）直接拒绝，
--       未涨停则把金额截断到涨停价（不多收钱）。
-- 锚点：当日开盘价 = stock_daily_kline.trade_date 为北京时间日期。
-- ============================================================

-- ========== 1. support_company：支持也要受涨停限制 ==========
CREATE OR REPLACE FUNCTION public.support_company(p_user_id uuid, p_company_id bigint, p_amount integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_owner_id UUID;
    v_market_value INTEGER;
    v_fee INTEGER := 0;
    v_total_pay INTEGER;
    v_day_open NUMERIC;
    v_max_add NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '支持金额必须大于0');
    END IF;
    IF p_amount > 2000 THEN
        RETURN jsonb_build_object('success', false, 'message', '单次手动支持金额不能超过2000 NB币');
    END IF;

    -- 交易时段检查（北京时间 8:00 ~ 20:00）
    IF (now() AT TIME ZONE 'Asia/Shanghai')::time < time '08:00'
       OR (now() AT TIME ZONE 'Asia/Shanghai')::time >= time '20:00' THEN
        RETURN jsonb_build_object('success', false, 'message', '当前为休市时间（每日 8:00-20:00 交易），请开盘后再操作');
    END IF;

    SELECT user_id, market_value INTO v_owner_id, v_market_value
      FROM public.user_companies WHERE id = p_company_id;
    IF v_owner_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '虚拟公司不存在');
    END IF;

    -- 涨跌停上限：已涨停（≥ 开盘价×1.5）拒绝支持；未涨停则截断到涨停价
    SELECT open INTO v_day_open
      FROM public.stock_daily_kline
     WHERE company_id = p_company_id
       AND trade_date = (now() AT TIME ZONE 'Asia/Shanghai')::date;
    IF v_day_open IS NOT NULL THEN
        v_max_add := floor(v_day_open * 1.5) - v_market_value;
        IF v_max_add <= 0 THEN
            RETURN jsonb_build_object('success', false, 'message', '该公司已涨停（较今日开盘价 +50%），今日无法再支持');
        END IF;
        IF p_amount > v_max_add THEN
            p_amount := v_max_add;
        END IF;
    END IF;

    -- 自支持收 5% 手续费（他人支持仍免费）
    IF v_owner_id = p_user_id THEN
        v_fee := floor(p_amount * 0.05);
    END IF;
    v_total_pay := p_amount + v_fee;

    UPDATE public.profiles SET nb_balance = nb_balance - v_total_pay
     WHERE id = p_user_id AND nb_balance >= v_total_pay;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('NB币余额不足（需 %s NB币%s）', v_total_pay, CASE WHEN v_fee > 0 THEN format('，含 %s NB币手续费', v_fee) ELSE '' END));
    END IF;

    UPDATE public.user_companies
       SET market_value = market_value + p_amount
     WHERE id = p_company_id;

    INSERT INTO public.support_logs (supporter_id, company_id, amount)
    VALUES (p_user_id, p_company_id, p_amount);

    IF v_fee > 0 THEN
        RETURN jsonb_build_object('success', true, 'message',
            format('成功支持自己的公司 %s NB币（手续费 %s NB币，共支付 %s NB币）', p_amount, v_fee, v_total_pay));
    END IF;
    RETURN jsonb_build_object('success', true, 'message', format('成功支持 %s NB币', p_amount));
END;
$$;

-- ========== 2. buy_stock：买入也要受涨停限制 ==========
CREATE OR REPLACE FUNCTION public.buy_stock(p_user_id uuid, p_company_id bigint, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_nav NUMERIC(18,4);
    v_shares NUMERIC(18,4);
    v_cost NUMERIC(18,4);
    v_fee INTEGER;
    v_total_pay NUMERIC(18,4);
    v_company_name TEXT;
    v_owner_id UUID;
    v_total_shares NUMERIC;
    v_market_value BIGINT;
    v_day_open NUMERIC;
    v_max_add NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '投入金额必须大于0');
    END IF;
    IF p_amount > 10000 THEN
        RETURN jsonb_build_object('success', false, 'message', '单次买入不能超过10000 NB币');
    END IF;

    -- 交易时段检查（北京时间 8:00 ~ 20:00）
    IF (now() AT TIME ZONE 'Asia/Shanghai')::time < time '08:00'
       OR (now() AT TIME ZONE 'Asia/Shanghai')::time >= time '20:00' THEN
        RETURN jsonb_build_object('success', false, 'message', '当前为休市时间（每日 8:00-20:00 交易），请开盘后再操作');
    END IF;

    SELECT market_value / total_shares, company_name, user_id, total_shares, market_value
      INTO v_nav, v_company_name, v_owner_id, v_total_shares, v_market_value
      FROM public.user_companies
     WHERE id = p_company_id;
    IF v_nav IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '公司不存在');
    END IF;

    -- 禁止买入自己的公司（想托底请用"支持"）
    IF v_owner_id = p_user_id THEN
        RETURN jsonb_build_object('success', false, 'message', '不能买入自己公司的股份（可以用"支持"为自己的公司托底）');
    END IF;

    v_shares := round(p_amount / v_nav, 4);
    IF v_shares <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '投入金额太小，至少需 ' || ceil(v_nav)::text || ' NB币');
    END IF;

    v_cost := round(v_shares * v_nav, 2);
    v_fee := floor(v_cost * 0.05);          -- 手续费 5%
    v_total_pay := v_cost + v_fee;

    -- 涨跌停上限：已涨停拒绝买入；未涨停则把投入额截断到涨停价
    SELECT open INTO v_day_open
      FROM public.stock_daily_kline
     WHERE company_id = p_company_id
       AND trade_date = (now() AT TIME ZONE 'Asia/Shanghai')::date;
    IF v_day_open IS NOT NULL THEN
        v_max_add := floor(v_day_open * 1.5) - v_market_value;
        IF v_max_add <= 0 THEN
            RETURN jsonb_build_object('success', false, 'message', '该公司已涨停（较今日开盘价 +50%），今日无法再买入');
        END IF;
        IF v_cost > v_max_add THEN
            v_cost := v_max_add;
            v_shares := round(v_cost / v_nav, 4);
            v_fee := floor(v_cost * 0.05);
            v_total_pay := v_cost + v_fee;
        END IF;
    END IF;

    UPDATE public.profiles SET nb_balance = nb_balance - v_total_pay
     WHERE id = p_user_id AND nb_balance >= v_total_pay;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('NB币余额不足（需 %s NB币，含 %s NB币手续费）', v_total_pay, v_fee));
    END IF;

    UPDATE public.user_companies
       SET market_value = market_value + v_cost
     WHERE id = p_company_id;

    INSERT INTO public.holdings (user_id, company_id, shares, average_price)
    VALUES (p_user_id, p_company_id, v_shares, v_nav)
    ON CONFLICT (user_id, company_id) DO UPDATE SET
        shares = holdings.shares + EXCLUDED.shares,
        average_price = ((holdings.average_price * holdings.shares) + (EXCLUDED.average_price * EXCLUDED.shares)) / (holdings.shares + EXCLUDED.shares),
        updated_at = now();

    INSERT INTO public.transactions (user_id, company_id, type, shares, price, total_amount, fee)
    VALUES (p_user_id, p_company_id, 'buy', v_shares, v_nav, v_cost, v_fee);

    RETURN jsonb_build_object(
        'success', true,
        'message', format('成功入股「%s」！投入 %s NB币，手续费 %s NB币，共支付 %s NB币（市值涨跌决定您的盈亏）',
                          v_company_name, v_cost, v_fee, v_total_pay),
        'shares', v_shares
    );
END;
$$;

-- ========== 3. 权限 ==========
GRANT EXECUTE ON FUNCTION public.support_company(uuid, bigint, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.buy_stock(uuid, bigint, numeric) TO anon;
