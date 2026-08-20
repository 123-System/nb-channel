-- ============================================================
-- NB频道 - 移除涨跌停机制（波动/买卖/支持不再有 ±50% 限制）
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 改动：
--   1) random_fluctuate_market_values v8：删掉涨停/跌停冻结与边界钳制，
--      只保留 交易时段 + 8秒节流 + ±2% 随机游走 + 10000 保底
--   2) support_company：还原为无涨跌停检查（自支持 5% 手续费保留）
--   3) buy_stock：还原为无涨跌停检查（禁买自己公司、5% 手续费保留）
--   4) sell_stock：还原为无跌停检查（保底 10000、5% 手续费保留）
-- 注意：K线图的"开盘价"记录（record_daily_kline）保留，不影响。
-- ============================================================

-- ========== 1. 波动函数 v8（无涨跌停） ==========
CREATE OR REPLACE FUNCTION public.random_fluctuate_market_values()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    company RECORD;
    change_percent FLOAT;
    new_value BIGINT;
    v_last timestamptz;
BEGIN
    -- 交易时段判断（北京时间）：8:00 开盘 ~ 20:00 收盘
    IF (now() AT TIME ZONE 'Asia/Shanghai')::time < time '08:00'
       OR (now() AT TIME ZONE 'Asia/Shanghai')::time >= time '20:00' THEN
        RETURN;
    END IF;

    -- 全局节流：8 秒内已波动过则跳过
    SELECT value::timestamptz INTO v_last FROM public.market_meta WHERE key = 'last_fluctuate';
    IF v_last IS NOT NULL AND v_last > now() - interval '8 seconds' THEN
        RETURN;
    END IF;

    FOR company IN SELECT id, market_value FROM user_companies LOOP
        -- 随机波动：-2% ~ +2%（对称，纯随机游走，无涨跌停限制）
        change_percent := (random() - 0.5) * 0.04;
        new_value := company.market_value + (company.market_value * change_percent);

        -- 最低市值保底 10000
        IF new_value < 10000 THEN new_value := 10000; END IF;

        UPDATE user_companies SET market_value = new_value WHERE id = company.id;
    END LOOP;

    -- 记录本次波动时间（节流依据）
    INSERT INTO public.market_meta (key, value) VALUES ('last_fluctuate', now()::text)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$;

-- ========== 2. support_company（无涨跌停，自支持 5% 手续费保留） ==========
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

-- ========== 3. buy_stock（无涨跌停，禁买自己公司/手续费保留） ==========
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

    SELECT market_value / total_shares, company_name, user_id, total_shares
      INTO v_nav, v_company_name, v_owner_id, v_total_shares
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

-- ========== 4. sell_stock（无跌停，保底10000/手续费保留） ==========
CREATE OR REPLACE FUNCTION public.sell_stock(p_user_id uuid, p_company_id bigint, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_nav NUMERIC(18,4);
    v_shares NUMERIC(18,4);
    v_revenue NUMERIC(18,4);
    v_fee INTEGER;
    v_net NUMERIC(18,4);
    v_holding_shares NUMERIC(18,4);
    v_company_name TEXT;
    v_market_value INTEGER;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '卖出金额必须大于0');
    END IF;

    -- 交易时段检查（北京时间 8:00 ~ 20:00）
    IF (now() AT TIME ZONE 'Asia/Shanghai')::time < time '08:00'
       OR (now() AT TIME ZONE 'Asia/Shanghai')::time >= time '20:00' THEN
        RETURN jsonb_build_object('success', false, 'message', '当前为休市时间（每日 8:00-20:00 交易），请开盘后再操作');
    END IF;

    SELECT market_value / total_shares, company_name, market_value
      INTO v_nav, v_company_name, v_market_value
      FROM public.user_companies
     WHERE id = p_company_id;
    IF v_nav IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '公司不存在');
    END IF;

    SELECT shares INTO v_holding_shares
      FROM public.holdings
     WHERE user_id = p_user_id AND company_id = p_company_id;
    IF v_holding_shares IS NULL OR v_holding_shares <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '您还没有持有这家公司');
    END IF;

    -- 按金额折算份额，超出持仓自动按上限成交（不会拒绝）
    v_shares := LEAST(round(p_amount / v_nav, 4), v_holding_shares);
    IF v_shares <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '卖出金额太小');
    END IF;

    v_revenue := round(v_shares * v_nav, 2);
    v_fee := floor(v_revenue * 0.05);
    v_net := v_revenue - v_fee;

    -- 卖出后市值不得低于保底值 10000
    IF v_market_value - v_revenue < 10000 THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('卖出后公司市值将低于保底值10000，最多可卖 %s NB币', (v_market_value - 10000)));
    END IF;

    UPDATE public.profiles SET nb_balance = nb_balance + v_net WHERE id = p_user_id;

    UPDATE public.user_companies
       SET market_value = market_value - v_revenue
     WHERE id = p_company_id;

    IF v_holding_shares - v_shares <= 0.0001 THEN
        DELETE FROM public.holdings WHERE user_id = p_user_id AND company_id = p_company_id;
    ELSE
        UPDATE public.holdings
           SET shares = shares - v_shares, updated_at = now()
         WHERE user_id = p_user_id AND company_id = p_company_id;
    END IF;

    INSERT INTO public.transactions (user_id, company_id, type, shares, price, total_amount, fee)
    VALUES (p_user_id, p_company_id, 'sell', v_shares, v_nav, v_revenue, v_fee);

    RETURN jsonb_build_object(
        'success', true,
        'message', format('成功退出「%s」！交易额 %s NB币，手续费 %s NB币，实际到账 %s NB币',
                          v_company_name, v_revenue, v_fee, v_net),
        'revenue', v_revenue
    );
END;
$$;

-- ========== 5. 权限 ==========
GRANT EXECUTE ON FUNCTION public.random_fluctuate_market_values() TO anon;
GRANT EXECUTE ON FUNCTION public.support_company(uuid, bigint, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.buy_stock(uuid, bigint, numeric) TO anon;
GRANT EXECUTE ON FUNCTION public.sell_stock(uuid, bigint, numeric) TO anon;
