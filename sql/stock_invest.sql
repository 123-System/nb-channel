-- ============================================================
-- NB频道 - 金额制投资（替代股数制交易）
-- 设计：全站只有"市值"概念。买入=按当前市值比例获得份额并注入资金；
--       卖出=按当前市值比例折现。内部使用 份额净值 NAV = 市值/总份额(1000)。
-- 执行前提：已执行过 stock_trading.sql（含 holdings 唯一约束与 RLS 收紧）
-- ============================================================

-- ========== 1. holdings 列类型调整（份额/净值允许小数） ==========
ALTER TABLE public.holdings ALTER COLUMN shares TYPE numeric(18,4);
ALTER TABLE public.holdings ALTER COLUMN average_price TYPE numeric(18,4);

-- ========== 2. buy_stock 重写：金额制买入 ==========
-- 参数：p_amount 投入 NB 币金额
-- 先删除旧的"股数制"版本（参数 p_shares integer），避免重载混淆
DROP FUNCTION IF EXISTS public.buy_stock(uuid, bigint, integer);
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

    SELECT market_value / total_shares, company_name, user_id, total_shares
      INTO v_nav, v_company_name, v_owner_id, v_total_shares
      FROM public.user_companies
     WHERE id = p_company_id;
    IF v_nav IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '公司不存在');
    END IF;

    -- 禁止买入自己的公司
    IF v_owner_id = p_user_id THEN
        RETURN jsonb_build_object('success', false, 'message', '不能买入自己公司的份额');
    END IF;

    -- 按当前净值折算份额（保留4位小数）
    v_shares := round(p_amount / v_nav, 4);
    IF v_shares <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '投入金额太小，至少需 ' || ceil(v_nav)::text || ' NB币');
    END IF;

    -- 实际投入 = 份额 × 净值（取整到分）
    v_cost := round(v_shares * v_nav, 2);
    v_fee := floor(v_cost * 0.05);          -- 手续费 5%
    v_total_pay := v_cost + v_fee;

    -- 原子扣款（含手续费）
    UPDATE public.profiles SET nb_balance = nb_balance - v_total_pay
     WHERE id = p_user_id AND nb_balance >= v_total_pay;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('NB币余额不足（需 %s NB币，含 %s NB币手续费）', v_total_pay, v_fee));
    END IF;

    -- 资金注入公司（市值只增加投入额）
    UPDATE public.user_companies
       SET market_value = market_value + v_cost
     WHERE id = p_company_id;

    -- 持仓更新（加权平均成本）
    INSERT INTO public.holdings (user_id, company_id, shares, average_price)
    VALUES (p_user_id, p_company_id, v_shares, v_nav)
    ON CONFLICT (user_id, company_id) DO UPDATE SET
        shares = holdings.shares + EXCLUDED.shares,
        average_price = ((holdings.average_price * holdings.shares) + (EXCLUDED.average_price * EXCLUDED.shares)) / (holdings.shares + EXCLUDED.shares),
        updated_at = now();

    -- 交易记录
    INSERT INTO public.transactions (user_id, company_id, type, shares, price, total_amount, fee)
    VALUES (p_user_id, p_company_id, 'buy', v_shares, v_nav, v_cost, v_fee);

    RETURN jsonb_build_object(
        'success', true,
        'message', format('成功买入「%s」份额，投入 %s NB币（净值 %s），手续费 %s NB币，共支付 %s NB币',
                          v_company_name, v_cost, v_nav, v_fee, v_total_pay),
        'shares', v_shares
    );
END;
$$;

-- ========== 3. sell_stock 重写：金额制卖出 ==========
-- 参数：p_amount 想卖出的金额（按当前净值折算份额）
DROP FUNCTION IF EXISTS public.sell_stock(uuid, bigint, integer);
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

    SELECT market_value / total_shares, company_name, market_value
      INTO v_nav, v_company_name, v_market_value
      FROM public.user_companies
     WHERE id = p_company_id;
    IF v_nav IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '公司不存在');
    END IF;

    -- 折算份额并校验持仓
    v_shares := round(p_amount / v_nav, 4);
    SELECT shares INTO v_holding_shares
      FROM public.holdings
     WHERE user_id = p_user_id AND company_id = p_company_id;
    IF v_holding_shares IS NULL OR v_holding_shares + 0.0001 < v_shares THEN
        RETURN jsonb_build_object('success', false, 'message', '卖出金额超过您的持仓价值');
    END IF;

    v_revenue := round(v_shares * v_nav, 2);
    -- 手续费 5%
    v_fee := floor(v_revenue * 0.05);
    v_net := v_revenue - v_fee;

    -- 卖出后市值不得低于保底值 10000
    IF v_market_value - v_revenue < 10000 THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('卖出后公司市值将低于保底值10000，最多可卖 %s NB币', (v_market_value - 10000)));
    END IF;

    -- 到账（扣除手续费）
    UPDATE public.profiles SET nb_balance = nb_balance + v_net WHERE id = p_user_id;

    -- 公司市值减少（撤资）
    UPDATE public.user_companies
       SET market_value = market_value - v_revenue
     WHERE id = p_company_id;

    -- 持仓更新（份额归零则删除）
    IF v_holding_shares - v_shares <= 0.0001 THEN
        DELETE FROM public.holdings WHERE user_id = p_user_id AND company_id = p_company_id;
    ELSE
        UPDATE public.holdings
           SET shares = shares - v_shares, updated_at = now()
         WHERE user_id = p_user_id AND company_id = p_company_id;
    END IF;

    -- 交易记录
    INSERT INTO public.transactions (user_id, company_id, type, shares, price, total_amount, fee)
    VALUES (p_user_id, p_company_id, 'sell', v_shares, v_nav, v_revenue, v_fee);

    RETURN jsonb_build_object(
        'success', true,
        'message', format('成功卖出「%s」份额，交易额 %s NB币，手续费 %s NB币，实际到账 %s NB币',
                          v_company_name, v_revenue, v_fee, v_net),
        'revenue', v_revenue
    );
END;
$$;

-- ========== 4. get_my_holdings 更新：返回份额/净值/当前价值 ==========
-- 返回类型从 integer 改为 numeric，必须先 DROP 再 CREATE（PostgreSQL 限制）
DROP FUNCTION IF EXISTS public.get_my_holdings(uuid);
CREATE OR REPLACE FUNCTION public.get_my_holdings(p_user_id uuid)
RETURNS TABLE(
    company_id bigint,
    company_name text,
    shares numeric,
    average_price numeric,
    current_price numeric,
    market_value integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT h.company_id,
           c.company_name,
           h.shares,
           h.average_price,
           c.market_value::numeric / c.total_shares AS current_price,
           c.market_value
    FROM public.holdings h
    JOIN public.user_companies c ON c.id = h.company_id
    WHERE h.user_id = p_user_id
    ORDER BY c.market_value DESC;
END;
$$;

-- ========== 5. 权限 ==========
GRANT EXECUTE ON FUNCTION public.buy_stock(uuid, bigint, numeric) TO anon;
GRANT EXECUTE ON FUNCTION public.sell_stock(uuid, bigint, numeric) TO anon;
GRANT EXECUTE ON FUNCTION public.get_my_holdings(uuid) TO anon;

-- 说明：support_company / bankrupt_company / RLS 收紧沿用 stock_trading.sql 的版本，无需重跑。
