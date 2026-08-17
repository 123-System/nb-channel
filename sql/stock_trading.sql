-- ============================================================
-- NB频道 - 虚拟股票交易系统（买入/卖出/持仓）
-- 基于你的真实函数体（2026-08-16 导出）修复并增强
-- 在 Supabase SQL Editor 中执行
-- ============================================================

-- ========== 0. 确保 holdings 表有唯一约束（buy_stock 的 ON CONFLICT 依赖它） ==========
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'holdings_user_company_unique') THEN
        ALTER TABLE public.holdings
            ADD CONSTRAINT holdings_user_company_unique UNIQUE (user_id, company_id);
    END IF;
END $$;

-- ========== 1. buy_stock 增强版 ==========
-- 原函数缺陷修复：
--   ① 禁止买入自己的公司（堵住"自买→市值暴涨→破产套现"刷币漏洞）
--   ② 校验股数 > 0 与单次上限
--   ③ 校验总持仓不超过总股本（total_shares）
--   ④ 余额用原子扣款（防并发超扣）
CREATE OR REPLACE FUNCTION public.buy_stock(p_user_id uuid, p_company_id bigint, p_shares integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_price_per_share INTEGER;
    v_total_cost INTEGER;
    v_total_pay INTEGER;
    v_fee INTEGER;
    v_company_name TEXT;
    v_owner_id UUID;
    v_total_shares INTEGER;
    v_held_shares INTEGER;
BEGIN
    IF p_shares IS NULL OR p_shares <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '股数必须大于0');
    END IF;
    IF p_shares > 10000 THEN
        RETURN jsonb_build_object('success', false, 'message', '单次买入不能超过10000股');
    END IF;

    SELECT market_value / circulating_shares, company_name, user_id, total_shares
      INTO v_price_per_share, v_company_name, v_owner_id, v_total_shares
      FROM public.user_companies
     WHERE id = p_company_id;
    IF v_price_per_share IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '公司不存在');
    END IF;

    -- 禁止买入自己的公司
    IF v_owner_id = p_user_id THEN
        RETURN jsonb_build_object('success', false, 'message', '不能买入自己公司的股票');
    END IF;

    -- 总持仓不超过总股本
    SELECT COALESCE(SUM(shares), 0) INTO v_held_shares
      FROM public.holdings WHERE company_id = p_company_id;
    IF v_held_shares + p_shares > v_total_shares THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('该股票剩余可买 %s 股', v_total_shares - v_held_shares));
    END IF;

    v_total_cost := v_price_per_share * p_shares;
    -- 手续费：交易额的 5%（向下取整）
    v_fee := floor(v_total_cost * 0.05);
    v_total_pay := v_total_cost + v_fee;

    -- 原子扣款（含手续费，余额不足则不动）
    UPDATE public.profiles SET nb_balance = nb_balance - v_total_pay
     WHERE id = p_user_id AND nb_balance >= v_total_pay;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('NB币余额不足（需 %s NB币，含 %s NB币手续费）', v_total_pay, v_fee));
    END IF;

    -- 资金注入公司（市值只增加交易额，手续费不进入市值）
    UPDATE public.user_companies
       SET market_value = market_value + v_total_cost
     WHERE id = p_company_id;

    -- 持仓更新
    INSERT INTO public.holdings (user_id, company_id, shares, average_price)
    VALUES (p_user_id, p_company_id, p_shares, v_price_per_share)
    ON CONFLICT (user_id, company_id) DO UPDATE SET
        shares = holdings.shares + p_shares,
        average_price = ((holdings.average_price * holdings.shares) + (v_price_per_share * p_shares)) / (holdings.shares + p_shares),
        updated_at = now();

    -- 交易记录（fee 记录手续费）
    INSERT INTO public.transactions (user_id, company_id, type, shares, price, total_amount, fee)
    VALUES (p_user_id, p_company_id, 'buy', p_shares, v_price_per_share, v_total_cost, v_fee);

    RETURN jsonb_build_object(
        'success', true,
        'message', format('成功买入 %s 股「%s」，单价 %s NB币，交易额 %s NB币，手续费 %s NB币，共支付 %s NB币',
                          p_shares, v_company_name, v_price_per_share, v_total_cost, v_fee, v_total_pay),
        'price', v_price_per_share
    );
END;
$$;

-- ========== 2. sell_stock 增强版 ==========
-- 修复：① 校验股数 ② 卖出后公司市值不得低于保底值 10000
CREATE OR REPLACE FUNCTION public.sell_stock(p_user_id uuid, p_company_id bigint, p_shares integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_price_per_share INTEGER;
    v_total_revenue INTEGER;
    v_fee INTEGER;
    v_net_income INTEGER;
    v_holding_shares INTEGER;
    v_company_name TEXT;
    v_market_value INTEGER;
BEGIN
    IF p_shares IS NULL OR p_shares <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '股数必须大于0');
    END IF;

    SELECT market_value / circulating_shares, company_name, market_value
      INTO v_price_per_share, v_company_name, v_market_value
      FROM public.user_companies
     WHERE id = p_company_id;
    IF v_price_per_share IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '公司不存在');
    END IF;

    SELECT shares INTO v_holding_shares
      FROM public.holdings
     WHERE user_id = p_user_id AND company_id = p_company_id;
    IF v_holding_shares IS NULL OR v_holding_shares < p_shares THEN
        RETURN jsonb_build_object('success', false, 'message', '持仓不足');
    END IF;

    v_total_revenue := v_price_per_share * p_shares;
    -- 手续费：交易额的 5%（向下取整）
    v_fee := floor(v_total_revenue * 0.05);
    v_net_income := v_total_revenue - v_fee;

    -- 卖出后市值不得低于保底值 10000（与随机波动一致）
    IF v_market_value - v_total_revenue < 10000 THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('卖出后公司市值将低于保底值10000，最多可卖 %s 股', (v_market_value - 10000) / v_price_per_share));
    END IF;

    -- 卖出所得入账（扣除手续费）
    UPDATE public.profiles SET nb_balance = nb_balance + v_net_income WHERE id = p_user_id;

    -- 公司市值减少（撤资，按交易额计算）
    UPDATE public.user_companies
       SET market_value = market_value - v_total_revenue
     WHERE id = p_company_id;

    -- 持仓更新
    IF v_holding_shares = p_shares THEN
        DELETE FROM public.holdings WHERE user_id = p_user_id AND company_id = p_company_id;
    ELSE
        UPDATE public.holdings
           SET shares = shares - p_shares, updated_at = now()
         WHERE user_id = p_user_id AND company_id = p_company_id;
    END IF;

    -- 交易记录（fee 记录手续费）
    INSERT INTO public.transactions (user_id, company_id, type, shares, price, total_amount, fee)
    VALUES (p_user_id, p_company_id, 'sell', p_shares, v_price_per_share, v_total_revenue, v_fee);

    RETURN jsonb_build_object(
        'success', true,
        'message', format('成功卖出 %s 股「%s」，单价 %s NB币，交易额 %s NB币，手续费 %s NB币，实际到账 %s NB币',
                          p_shares, v_company_name, v_price_per_share, v_total_revenue, v_fee, v_net_income),
        'price', v_price_per_share
    );
END;
$$;

-- ========== 3. 我的持仓查询 ==========
CREATE OR REPLACE FUNCTION public.get_my_holdings(p_user_id uuid)
RETURNS TABLE(
    company_id bigint,
    company_name text,
    shares integer,
    average_price integer,
    current_price integer,
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
           c.market_value / c.circulating_shares AS current_price,
           c.market_value
    FROM public.holdings h
    JOIN public.user_companies c ON c.id = h.company_id
    WHERE h.user_id = p_user_id
    ORDER BY c.market_value DESC;
END;
$$;

-- ========== 4. support_company（支持公司，RPC 化） ==========
-- 允许支持自己的公司，但自支持收取 5% 手续费（防"自支持→破产套现"无限刷币）
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

    -- 原子扣款（含手续费）
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

-- ========== 5. bankrupt_company（破产，RPC 化） ==========
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

    -- 1. 清理所有股东持仓（公司倒闭，股票作废）
    DELETE FROM public.holdings WHERE company_id = v_company_id;

    -- 2. 删除公司
    DELETE FROM public.user_companies WHERE id = v_company_id;

    -- 3. 删除蓝标
    DELETE FROM public.verified_users WHERE user_id = p_user_id;

    -- 4. 删除自动支持规则
    DELETE FROM public.support_rules WHERE company_id = v_company_id;

    -- 5. 从历史快照中移除该公司数据
    DELETE FROM public.stock_history_full
     WHERE snapshot->'names' ? v_company_name;

    -- 6. 发放奖励
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

-- ========== 6. 权限 ==========
GRANT EXECUTE ON FUNCTION public.buy_stock(uuid, bigint, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.sell_stock(uuid, bigint, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.get_my_holdings(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.support_company(uuid, bigint, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.bankrupt_company(uuid) TO anon;

-- ========== 7. 收紧权限：holdings / user_companies 禁止 anon 直接写 ==========
-- holdings：读写都走 RPC（buy/sell/get_my_holdings）
ALTER TABLE public.holdings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS holdings_read_all ON public.holdings;
DROP POLICY IF EXISTS holdings_write_all ON public.holdings;
REVOKE ALL ON public.holdings FROM anon;

-- user_companies：注册走 register_company、支持走 support_company、破产走 bankrupt_company、认证走 admin RPC
REVOKE INSERT, UPDATE, DELETE ON public.user_companies FROM anon;

-- ========== 8. 其他 RLS 漏洞收紧 ==========
-- profiles：禁止 anon 修改封禁状态/警告次数（列级权限，PG15+），余额/用户名仍可改
REVOKE UPDATE (is_banned, banned_reason, warning_count) ON public.profiles FROM anon, authenticated;

-- comments：删除必须走 RPC（delete_comment_cascade）
REVOKE DELETE ON public.comments FROM anon;

-- reports：删除必须走 RPC（admin_*）
REVOKE DELETE ON public.reports FROM anon;

-- verified_users：蓝标只能由 RPC 管理（admin_verify_company / bankrupt_company / register_company）
REVOKE INSERT, DELETE ON public.verified_users FROM anon;
