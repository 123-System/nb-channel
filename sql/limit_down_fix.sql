-- ============================================================
-- NB频道 - 卖出加跌停保护（与真实股市一致：跌停无法卖出）
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 背景：卖出会把市值减回去（保底10000），跌停的公司可能被卖出砸穿
--       -50% 底线。修复：已跌停（≤ 开盘价×0.5）拒绝卖出。
-- ============================================================

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
    v_day_open NUMERIC;
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

    -- 跌停保护：已跌停（≤ 开盘价×0.5）拒绝卖出
    SELECT open INTO v_day_open
      FROM public.stock_daily_kline
     WHERE company_id = p_company_id
       AND trade_date = (now() AT TIME ZONE 'Asia/Shanghai')::date;
    IF v_day_open IS NOT NULL AND v_market_value <= v_day_open * 0.5 THEN
        RETURN jsonb_build_object('success', false, 'message', '该公司已跌停（较今日开盘价 -50%），今日无法卖出，明日开盘恢复');
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

GRANT EXECUTE ON FUNCTION public.sell_stock(uuid, bigint, numeric) TO anon;
