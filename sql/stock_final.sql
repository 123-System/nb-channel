-- ============================================================
-- NB频道 - 虚拟股票【最终统一版】★ 只跑这个文件即可 ★
-- 包含：金额制买卖 + 禁止自买 + 自支持(5%手续费) + 破产 + 持仓 + RLS
-- 会先删除所有旧版本函数（股数制/旧返回类型），幂等可重复执行
-- ============================================================

-- ========== 0. 清理旧版本函数（避免重载/类型冲突） ==========
DROP FUNCTION IF EXISTS public.buy_stock(uuid, bigint, integer);       -- 旧股数制
DROP FUNCTION IF EXISTS public.sell_stock(uuid, bigint, integer);      -- 旧股数制
DROP FUNCTION IF EXISTS public.get_my_holdings(uuid);                  -- 旧返回类型

-- ========== 1. holdings 表唯一约束（buy 的 ON CONFLICT 依赖） ==========
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'holdings_user_company_unique') THEN
        ALTER TABLE public.holdings
            ADD CONSTRAINT holdings_user_company_unique UNIQUE (user_id, company_id);
    END IF;
END $$;

-- ========== 2. holdings 列类型（份额/净值允许小数） ==========
ALTER TABLE public.holdings ALTER COLUMN shares TYPE numeric(18,4);
ALTER TABLE public.holdings ALTER COLUMN average_price TYPE numeric(18,4);

-- ========== 3. buy_stock：金额制买入（禁止买自己公司） ==========
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

-- ========== 4. sell_stock：金额制卖出（超出持仓自动按上限成交） ==========
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

-- ========== 5. get_my_holdings：持仓查询 ==========
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

-- ========== 6. support_company：支持（允许自支持，自支持 5% 手续费） ==========
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

-- ========== 7. bankrupt_company：破产 ==========
CREATE OR REPLACE FUNCTION public.bankrupt_company(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company_id BIGINT;
    v_company_name TEXT;
    v_market_value INTEGER;
    v_reward INTEGER := 0;
BEGIN
    SELECT id, company_name, market_value
      INTO v_company_id, v_company_name, v_market_value
      FROM public.user_companies WHERE user_id = p_user_id;
    IF v_company_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '您还没有虚拟公司');
    END IF;

    IF v_market_value > 20000 THEN
        v_reward := v_market_value - 20000;
    END IF;

    DELETE FROM public.holdings WHERE company_id = v_company_id;
    DELETE FROM public.user_companies WHERE id = v_company_id;
    DELETE FROM public.verified_users WHERE user_id = p_user_id;
    DELETE FROM public.support_rules WHERE company_id = v_company_id;
    -- 注意：不要删除 stock_history_full！
    -- 每条快照包含所有公司，按公司名删除 = 删光整张K线历史表（历史bug，已修复）

    IF v_reward > 0 THEN
        UPDATE public.profiles SET nb_balance = nb_balance + v_reward WHERE id = p_user_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_reward > 0
                        THEN format('破产成功，获得 %s NB币（市值-20000）', v_reward)
                        ELSE '破产成功，市值未超过20000，无奖励' END,
        'reward', v_reward
    );
END;
$$;

-- ========== 8. 权限 ==========
GRANT EXECUTE ON FUNCTION public.buy_stock(uuid, bigint, numeric) TO anon;
GRANT EXECUTE ON FUNCTION public.sell_stock(uuid, bigint, numeric) TO anon;
GRANT EXECUTE ON FUNCTION public.get_my_holdings(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.support_company(uuid, bigint, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.bankrupt_company(uuid) TO anon;

-- ========== 9. RLS 收紧 ==========
ALTER TABLE public.holdings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS holdings_read_all ON public.holdings;
DROP POLICY IF EXISTS holdings_write_all ON public.holdings;
REVOKE ALL ON public.holdings FROM anon;

REVOKE INSERT, UPDATE, DELETE ON public.user_companies FROM anon;
REVOKE UPDATE (is_banned, banned_reason, warning_count) ON public.profiles FROM anon, authenticated;
REVOKE DELETE ON public.comments FROM anon;
REVOKE DELETE ON public.reports FROM anon;
REVOKE INSERT, DELETE ON public.verified_users FROM anon;

-- ========== 完成：以后只需执行本文件 ==========
