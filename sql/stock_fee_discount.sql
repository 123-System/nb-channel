-- ============================================================
-- NB频道 - 交易函数升级：支持手续费减免券（p_use_discount）
-- 在 Supabase SQL Editor 中执行本文件（幂等，可重复执行）
-- 基于 trade_model_v2（金额制：买卖不改变市值，盈亏随市值浮动）
--   买入：扣（本金+手续费5%），手续费销毁，市值不变
--   卖出：按当前仓位价值卖出指定金额（超出自动按上限成交），手续费5%销毁
--   使用手续费减免券(p_use_discount=true)时手续费降为 2%，消耗一张券
-- ============================================================

-- ========== 0. 移除旧签名（避免重载混淆） ==========
DROP FUNCTION IF EXISTS public.buy_stock(uuid, bigint, integer);
DROP FUNCTION IF EXISTS public.buy_stock(uuid, bigint, numeric);
DROP FUNCTION IF EXISTS public.sell_stock(uuid, bigint, integer);
DROP FUNCTION IF EXISTS public.sell_stock(uuid, bigint, numeric);

-- ========== 0.5 手续费券消耗函数（幂等，shop.sql 第15节同款） ==========
CREATE OR REPLACE FUNCTION public.consume_fee_discount(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_id bigint;
BEGIN
    SELECT id INTO v_id FROM public.user_items
     WHERE user_id = p_user_id AND item_key = 'fee_discount'
       AND used = false AND (expires_at IS NULL OR expires_at > now())
     ORDER BY id LIMIT 1;
    IF v_id IS NULL THEN
        RETURN false;
    END IF;
    UPDATE public.user_items SET used = true, settings = jsonb_build_object('used_at', now())
     WHERE id = v_id;
    RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.consume_fee_discount(uuid) TO anon;

-- ========== 1. 买入（支持手续费券） ==========
CREATE OR REPLACE FUNCTION public.buy_stock(p_user_id uuid, p_company_id bigint, p_amount numeric, p_use_discount boolean DEFAULT false)
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
    v_existing NUMERIC(18,4) := 0;
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

    -- 累计投入上限：本金总额不能超过公司当前市值
    SELECT COALESCE(principal, 0) INTO v_existing
      FROM public.holdings WHERE user_id = p_user_id AND company_id = p_company_id;
    IF v_existing + p_amount > v_market_value THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('累计投入不能超过公司市值（已投 %s，市值 %s，最多再投 %s NB币）',
                   v_existing, v_market_value, GREATEST(v_market_value - v_existing, 0)));
    END IF;

    -- 手续费：默认 5%（销毁）；勾选券且消耗成功则 2%
    v_fee := floor(p_amount * 0.05);
    IF p_use_discount AND public.consume_fee_discount(p_user_id) THEN
        v_fee := floor(p_amount * 0.02);
    END IF;
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

-- ========== 2. 卖出（支持手续费券） ==========
CREATE OR REPLACE FUNCTION public.sell_stock(p_user_id uuid, p_company_id bigint, p_amount numeric, p_use_discount boolean DEFAULT false)
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
    IF p_use_discount AND public.consume_fee_discount(p_user_id) THEN
        v_fee := floor(v_sell * 0.02);
    END IF;
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

-- ========== 3. 权限（4参数签名） ==========
GRANT EXECUTE ON FUNCTION public.buy_stock(uuid, bigint, numeric, boolean) TO anon;
GRANT EXECUTE ON FUNCTION public.sell_stock(uuid, bigint, numeric, boolean) TO anon;
