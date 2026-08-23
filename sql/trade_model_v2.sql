-- ============================================================
-- NB频道 - 交易模型 v2（买卖不改变市值，盈亏随市值浮动）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 新规则：
--   买入：扣（本金+5%手续费，手续费销毁），市值不变；
--         持仓记录 = 累计本金 + 基准市值（多次买入累加本金，基准按本金加权平均）
--   卖出：按当前仓位价值卖出指定金额（超出自动按上限成交）；
--         当前市值 > 基准市值 → 赚；< → 亏（手续费 5% 销毁）；
--         剩余本金按卖出比例缩减，市值仍不变
--   持仓价值 = 本金 × (当前市值 / 基准市值)
-- 注意：规则变更，原有持仓与交易记录将全部清空！
-- ============================================================

-- ========== 0. 清空旧数据（新规则开始） ==========
DELETE FROM public.transactions;
DELETE FROM public.holdings;

-- ========== 0.5 持仓表增加新字段（幂等） ==========
ALTER TABLE public.holdings ADD COLUMN IF NOT EXISTS principal numeric(18,4) NOT NULL DEFAULT 0;
ALTER TABLE public.holdings ADD COLUMN IF NOT EXISTS base_market_value numeric(18,4) NOT NULL DEFAULT 0;

-- 旧字段降级：shares / average_price 在新模型中不再使用，
-- 去掉 NOT NULL，避免新版 buy_stock 插入（不写这些列）时违反约束
ALTER TABLE public.holdings ALTER COLUMN shares DROP NOT NULL;
ALTER TABLE public.holdings ALTER COLUMN average_price DROP NOT NULL;

-- ========== 1. 买入（钱不进市值，只记录本金与基准市值） ==========
CREATE OR REPLACE FUNCTION public.buy_stock(p_user_id uuid, p_company_id bigint, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_market_value BIGINT;
    v_company_name TEXT;
    v_owner_id UUID;
    v_fee INTEGER;
    v_total_pay NUMERIC(18,4);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '投入金额必须大于0');
    END IF;
    IF p_amount > 500000 THEN
        RETURN jsonb_build_object('success', false, 'message', '单次买入不能超过500000 NB币');
    END IF;

    -- 交易时段检查（北京时间 8:00 ~ 20:00）
    IF (now() AT TIME ZONE 'Asia/Shanghai')::time < time '08:00'
       OR (now() AT TIME ZONE 'Asia/Shanghai')::time >= time '20:00' THEN
        RETURN jsonb_build_object('success', false, 'message', '当前为休市时间（每日 8:00-20:00 交易），请开盘后再操作');
    END IF;

    SELECT market_value, company_name, user_id
      INTO v_market_value, v_company_name, v_owner_id
      FROM public.user_companies WHERE id = p_company_id;
    IF v_market_value IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '公司不存在');
    END IF;

    -- 禁止买入自己的公司（想托底请用"支持"）
    IF v_owner_id = p_user_id THEN
        RETURN jsonb_build_object('success', false, 'message', '不能买入自己公司的股份（可以用"支持"为自己的公司托底）');
    END IF;

    -- 手续费 5%（销毁），本金记录为持仓
    v_fee := floor(p_amount * 0.05);
    v_total_pay := p_amount + v_fee;

    UPDATE public.profiles SET nb_balance = nb_balance - v_total_pay
     WHERE id = p_user_id AND nb_balance >= v_total_pay;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('NB币余额不足（需 %s NB币，含 %s NB币手续费）', v_total_pay, v_fee));
    END IF;

    -- 持仓：本金累加，基准市值按本金加权平均（市值本身不变）
    INSERT INTO public.holdings (user_id, company_id, principal, base_market_value, updated_at)
    VALUES (p_user_id, p_company_id, p_amount, v_market_value, now())
    ON CONFLICT (user_id, company_id) DO UPDATE SET
        principal = holdings.principal + EXCLUDED.principal,
        base_market_value = CASE
            WHEN holdings.principal + EXCLUDED.principal > 0
            THEN round((holdings.base_market_value * holdings.principal
                      + EXCLUDED.base_market_value * EXCLUDED.principal)
                     / (holdings.principal + EXCLUDED.principal))
            ELSE EXCLUDED.base_market_value END,
        updated_at = now();

    INSERT INTO public.transactions (user_id, company_id, type, shares, price, total_amount, fee)
    VALUES (p_user_id, p_company_id, 'buy', 0, v_market_value, p_amount, v_fee);

    RETURN jsonb_build_object(
        'success', true,
        'message', format('成功入股「%s」！投入 %s NB币，手续费 %s NB币，共支付 %s NB币（买入不改变市值，盈亏随市值变动）',
                          v_company_name, p_amount, v_fee, v_total_pay),
        'principal', p_amount
    );
END;
$$;

-- ========== 2. 卖出（钱从系统支付，市值不变，剩余仓位按比例缩减） ==========
CREATE OR REPLACE FUNCTION public.sell_stock(p_user_id uuid, p_company_id bigint, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_market_value BIGINT;
    v_company_name TEXT;
    v_principal NUMERIC(18,4);
    v_base_mv NUMERIC(18,4);
    v_position NUMERIC(18,4);
    v_sell NUMERIC(18,4);
    v_cost NUMERIC(18,4);
    v_fee INTEGER;
    v_net NUMERIC(18,4);
    v_profit NUMERIC(18,4);
    v_ratio NUMERIC(18,6);
    v_new_principal NUMERIC(18,4);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '卖出金额必须大于0');
    END IF;

    -- 交易时段检查（北京时间 8:00 ~ 20:00）
    IF (now() AT TIME ZONE 'Asia/Shanghai')::time < time '08:00'
       OR (now() AT TIME ZONE 'Asia/Shanghai')::time >= time '20:00' THEN
        RETURN jsonb_build_object('success', false, 'message', '当前为休市时间（每日 8:00-20:00 交易），请开盘后再操作');
    END IF;

    SELECT market_value, company_name INTO v_market_value, v_company_name
      FROM public.user_companies WHERE id = p_company_id;
    IF v_market_value IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '公司不存在');
    END IF;

    SELECT principal, base_market_value INTO v_principal, v_base_mv
      FROM public.holdings
     WHERE user_id = p_user_id AND company_id = p_company_id;
    IF v_principal IS NULL OR v_principal <= 0 OR v_base_mv IS NULL OR v_base_mv <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '您还没有持有这家公司');
    END IF;

    -- 当前仓位价值 = 本金 × (当前市值 / 基准市值)
    v_position := v_principal * (v_market_value::numeric / v_base_mv);

    -- 卖出金额超出仓位价值时，按仓位价值成交（不拒绝）
    v_sell := LEAST(p_amount, round(v_position, 2));
    IF v_sell <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '卖出金额太小');
    END IF;

    -- 卖出部分成本 = 本金 × 卖出比例；盈亏 = 卖出金额 − 成本 − 手续费
    v_ratio := v_sell / v_position;
    v_cost := round(v_principal * v_ratio, 2);
    v_fee := floor(v_sell * 0.05);
    v_net := v_sell - v_fee;
    v_profit := round(v_sell - v_cost - v_fee, 2);

    -- 剩余本金 = 本金 × (1 − 卖出比例)
    v_new_principal := round(v_principal * (1 - v_ratio), 2);

    UPDATE public.profiles SET nb_balance = nb_balance + v_net WHERE id = p_user_id;

    IF v_new_principal <= 0.01 THEN
        DELETE FROM public.holdings WHERE user_id = p_user_id AND company_id = p_company_id;
    ELSE
        UPDATE public.holdings
           SET principal = v_new_principal, updated_at = now()
         WHERE user_id = p_user_id AND company_id = p_company_id;
    END IF;

    INSERT INTO public.transactions (user_id, company_id, type, shares, price, total_amount, fee)
    VALUES (p_user_id, p_company_id, 'sell', 0, v_market_value, v_sell, v_fee);

    RETURN jsonb_build_object(
        'success', true,
        'message', format('成功退出「%s」！卖出 %s NB币，手续费 %s NB币，实际到账 %s NB币，盈亏 %s NB币',
                          v_company_name, v_sell, v_fee, v_net, v_profit),
        'revenue', v_sell,
        'profit', v_profit,
        'position_value', round(v_position, 2)
    );
END;
$$;

-- ========== 3. 我的持仓（新模型字段） ==========
DROP FUNCTION IF EXISTS public.get_my_holdings(uuid);
CREATE OR REPLACE FUNCTION public.get_my_holdings(p_user_id uuid)
RETURNS TABLE (company_id bigint, company_name text, principal numeric, base_market_value numeric,
               current_market_value numeric, position_value numeric, profit numeric, profit_pct numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT h.company_id, uc.company_name, h.principal,
           h.base_market_value, uc.market_value::numeric,
           round(h.principal * (uc.market_value::numeric / h.base_market_value), 2) AS position_value,
           round(h.principal * (uc.market_value::numeric / h.base_market_value) - h.principal, 2) AS profit,
           round((uc.market_value::numeric / h.base_market_value - 1) * 100, 2) AS profit_pct
      FROM public.holdings h
      JOIN public.user_companies uc ON uc.id = h.company_id
     WHERE h.user_id = p_user_id
     ORDER BY position_value DESC;
END;
$$;

-- ========== 4. 权限 ==========
GRANT EXECUTE ON FUNCTION public.buy_stock(uuid, bigint, numeric) TO anon;
GRANT EXECUTE ON FUNCTION public.sell_stock(uuid, bigint, numeric) TO anon;
GRANT EXECUTE ON FUNCTION public.get_my_holdings(uuid) TO anon;
