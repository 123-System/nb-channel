-- ============================================================
-- NB频道 - NB银行（v2：存款/贷款/信誉分）
-- 在 Supabase SQL Editor 中执行本文件（幂等）
-- 功能：
--   1) 存款：活期 0.1%/天、定期7天到期2%、定期30天到期10%
--   2) 贷款：抵押贷（存款×80%，到期总利率10%）、信用贷（信誉分额度，12%，800+打9折）
--   3) 信誉分：初始100，满分1000；按时还+5、逾期-15/天、成就+3、签到+2、评论+0.5(日上限2)
--   4) 每天凌晨自动结算存款利息 + 处理到期贷款（pg_cron）
--   5) 防刷：活期每日存款上限 1000 万
-- ============================================================

-- ========== 1. 银行账户表 ==========
CREATE TABLE IF NOT EXISTS public.bank_accounts (
    user_id         uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
    deposit         bigint NOT NULL DEFAULT 0,        -- 活期存款
    fixed7          bigint NOT NULL DEFAULT 0,        -- 定期7天本金
    fixed7_until    timestamptz,                      -- 定期7天到期时间
    fixed30         bigint NOT NULL DEFAULT 0,        -- 定期30天本金
    fixed30_until   timestamptz,                      -- 定期30天到期时间
    loan_principal  bigint NOT NULL DEFAULT 0,        -- 抵押贷本金
    loan_until      timestamptz,                      -- 抵押贷到期时间
    loan_credit     bigint NOT NULL DEFAULT 0,        -- 信用贷本金
    loan_credit_until timestamptz,                    -- 信用贷到期时间
    credit_score    integer NOT NULL DEFAULT 1000,    -- 信誉分（初始满分 1000）
    frozen          boolean NOT NULL DEFAULT false,   -- 是否有抵押贷款（冻结标记）
    frozen_amount   bigint NOT NULL DEFAULT 0,        -- 冻结的活期金额（贷款时点，之后新存的可自由取）
    created_at      timestamptz NOT NULL DEFAULT now()
);
-- 幂等加列
ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS deposit bigint NOT NULL DEFAULT 0;
ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS fixed7 bigint NOT NULL DEFAULT 0;
ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS fixed7_until timestamptz;
ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS fixed30 bigint NOT NULL DEFAULT 0;
ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS fixed30_until timestamptz;
ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS loan_principal bigint NOT NULL DEFAULT 0;
ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS loan_until timestamptz;
ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS loan_credit bigint NOT NULL DEFAULT 0;
ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS loan_credit_until timestamptz;
ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS credit_score integer NOT NULL DEFAULT 1000;
ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS frozen boolean NOT NULL DEFAULT false;
ALTER TABLE public.bank_accounts ADD COLUMN IF NOT EXISTS frozen_amount bigint NOT NULL DEFAULT 0;

ALTER TABLE public.bank_accounts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.bank_accounts FROM anon;

-- 已有账户统一调整为满分 1000（含旧默认 100 或异常值）
UPDATE public.bank_accounts SET credit_score = 1000;

-- ========== 2. 交易日志表 ==========
CREATE TABLE IF NOT EXISTS public.bank_logs (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    type       text NOT NULL,        -- deposit/fixed7_deposit/fixed30_deposit/withdraw/fixed7_withdraw/fixed30_withdraw
                                     -- loan/loan_credit/repay/repay_credit/interest/penalty/credit_change
    amount     bigint NOT NULL DEFAULT 0,
    detail     text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_bank_logs_user ON public.bank_logs (user_id, id DESC);

ALTER TABLE public.bank_logs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.bank_logs FROM anon;

-- ========== 3. 工具函数 ==========

-- 获取/创建银行账户
CREATE OR REPLACE FUNCTION public.get_bank_account(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_acc record;
    v_credit_limit bigint;
    v_credit_rate numeric;
BEGIN
    SELECT * INTO v_acc FROM public.bank_accounts WHERE user_id = p_user_id;
    IF v_acc.user_id IS NULL THEN
        INSERT INTO public.bank_accounts (user_id) VALUES (p_user_id)
        RETURNING * INTO v_acc;
    END IF;

    -- 信用贷额度与利率（按信誉分）
    IF v_acc.credit_score >= 800 THEN
        v_credit_limit := v_acc.credit_score * 1500;
        v_credit_rate := 0.108;   -- 9折（总利率12%打9折）
    ELSIF v_acc.credit_score >= 600 THEN
        v_credit_limit := v_acc.credit_score * 1000;
        v_credit_rate := 0.12;
    ELSIF v_acc.credit_score >= 300 THEN
        v_credit_limit := v_acc.credit_score * 500;
        v_credit_rate := 0.12;
    ELSE
        v_credit_limit := 0;
        v_credit_rate := 0.12;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'deposit', v_acc.deposit,
        'fixed7', v_acc.fixed7,
        'fixed7_until', v_acc.fixed7_until,
        'fixed30', v_acc.fixed30,
        'fixed30_until', v_acc.fixed30_until,
        'loan_principal', v_acc.loan_principal,
        'loan_until', v_acc.loan_until,
        'loan_credit', v_acc.loan_credit,
        'loan_credit_until', v_acc.loan_credit_until,
        'credit_score', v_acc.credit_score,
        'frozen', v_acc.frozen,
        'frozen_amount', v_acc.frozen_amount,
        'free_deposit', GREATEST(v_acc.deposit - v_acc.frozen_amount, 0),
        'collateral_limit', floor((v_acc.deposit + v_acc.fixed7 + v_acc.fixed30) * 0.8),
        'credit_limit', v_credit_limit,
        'credit_rate', v_credit_rate
    );
END;
$$;

-- ========== 4. 存款 ==========

-- 活期存款（每日上限 1000 万）
CREATE OR REPLACE FUNCTION public.bank_deposit(p_user_id uuid, p_amount bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_balance bigint;
    v_today_dep bigint;
    v_acc record;
    v_today date := (now() AT TIME ZONE 'Asia/Shanghai')::date;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '金额必须大于0');
    END IF;
    SELECT nb_balance INTO v_balance FROM public.profiles WHERE id = p_user_id;
    IF v_balance < p_amount THEN
        RETURN jsonb_build_object('success', false, 'message', 'NB币余额不足');
    END IF;

    -- 今日活期存款上限 1000 万
    SELECT coalesce(sum(amount), 0) INTO v_today_dep
      FROM public.bank_logs
     WHERE user_id = p_user_id AND type = 'deposit'
       AND (created_at AT TIME ZONE 'Asia/Shanghai')::date = v_today;
    IF v_today_dep + p_amount > 10000000 THEN
        RETURN jsonb_build_object('success', false, 'message',
            '今日活期存款已达上限（1000万/天）');
    END IF;

    SELECT * INTO v_acc FROM public.bank_accounts WHERE user_id = p_user_id;
    IF v_acc.user_id IS NULL THEN
        INSERT INTO public.bank_accounts (user_id) VALUES (p_user_id);
    END IF;

    UPDATE public.profiles SET nb_balance = nb_balance - p_amount WHERE id = p_user_id;
    UPDATE public.bank_accounts SET deposit = deposit + p_amount WHERE user_id = p_user_id;
    INSERT INTO public.bank_logs (user_id, type, amount, detail)
    VALUES (p_user_id, 'deposit', p_amount, '活期存入');
    RETURN jsonb_build_object('success', true, 'message',
        format('已存入 %s NB币（活期，日利率 0.1%%）', p_amount));
END;
$$;

-- 定期存款（7天/30天）
CREATE OR REPLACE FUNCTION public.bank_fixed_deposit(p_user_id uuid, p_amount bigint, p_days integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_balance bigint;
    v_rate numeric;
    v_type text;
BEGIN
    IF p_days NOT IN (7, 30) THEN
        RETURN jsonb_build_object('success', false, 'message', '定期只有 7 天或 30 天');
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '金额必须大于0');
    END IF;
    v_rate := CASE WHEN p_days = 7 THEN 0.02 ELSE 0.10 END;   -- 到期总利率
    v_type := CASE WHEN p_days = 7 THEN 'fixed7' ELSE 'fixed30' END;

    SELECT nb_balance INTO v_balance FROM public.profiles WHERE id = p_user_id;
    IF v_balance < p_amount THEN
        RETURN jsonb_build_object('success', false, 'message', 'NB币余额不足');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.bank_accounts WHERE user_id = p_user_id) THEN
        INSERT INTO public.bank_accounts (user_id) VALUES (p_user_id);
    END IF;

    UPDATE public.profiles SET nb_balance = nb_balance - p_amount WHERE id = p_user_id;
    IF p_days = 7 THEN
        -- 首次存入才设置到期时间；已有定期则保持原到期时间（避免覆盖旧钱的时间基准）
        UPDATE public.bank_accounts
           SET fixed7 = fixed7 + p_amount,
               fixed7_until = CASE WHEN fixed7 > 0 THEN fixed7_until
                                   ELSE now() + interval '7 days' END
         WHERE user_id = p_user_id;
        INSERT INTO public.bank_logs (user_id, type, amount, detail)
        VALUES (p_user_id, 'fixed7_deposit', p_amount, '定期7天存入');
    ELSE
        UPDATE public.bank_accounts
           SET fixed30 = fixed30 + p_amount,
               fixed30_until = CASE WHEN fixed30 > 0 THEN fixed30_until
                                    ELSE now() + interval '30 days' END
         WHERE user_id = p_user_id;
        INSERT INTO public.bank_logs (user_id, type, amount, detail)
        VALUES (p_user_id, 'fixed30_deposit', p_amount, '定期30天存入');
    END IF;
    RETURN jsonb_build_object('success', true, 'message',
        format('已存入 %s NB币（定期%s天，到期总利率 %s%%）', p_amount, p_days,
               CASE WHEN p_days = 7 THEN '2' ELSE '10' END));
END;
$$;

-- ========== 5. 取款 ==========

-- 活期取款（冻结期可取出"新存入的部分"，冻结金额不能取）
CREATE OR REPLACE FUNCTION public.bank_withdraw(p_user_id uuid, p_amount bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_acc record;
    v_free bigint;
BEGIN
    SELECT * INTO v_acc FROM public.bank_accounts WHERE user_id = p_user_id;
    IF v_acc.user_id IS NULL OR p_amount IS NULL OR p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '参数错误');
    END IF;
    -- 冻结期：只能取"冻结后新存入"的部分（deposit - frozen_amount）
    v_free := GREATEST(v_acc.deposit - v_acc.frozen_amount, 0);
    IF p_amount > v_free THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('可取金额不足：冻结 %s NB币，可自由取出 %s NB币（冻结后新存入的部分可取）',
                   v_acc.frozen_amount, v_free));
    END IF;
    UPDATE public.bank_accounts SET deposit = deposit - p_amount WHERE user_id = p_user_id;
    UPDATE public.profiles SET nb_balance = nb_balance + p_amount WHERE id = p_user_id;
    INSERT INTO public.bank_logs (user_id, type, amount, detail)
    VALUES (p_user_id, 'withdraw', p_amount, '活期取出');
    RETURN jsonb_build_object('success', true, 'message', format('已取出 %s NB币', p_amount));
END;
$$;

-- 定期提前支取（利息按活期算，本金不罚；冻结期间不能取）
CREATE OR REPLACE FUNCTION public.bank_fixed_withdraw(p_user_id uuid, p_days integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_acc record;
    v_amount bigint;
    v_interest bigint;
    v_deposited_at timestamptz;   -- 存入时间（用到期时间 - 期限反推）
    v_elapsed_days integer;
BEGIN
    SELECT * INTO v_acc FROM public.bank_accounts WHERE user_id = p_user_id;
    IF v_acc.user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '没有银行账户');
    END IF;
    IF v_acc.frozen THEN
        RETURN jsonb_build_object('success', false, 'message', '存款已冻结（有抵押贷款未还清），无法取款');
    END IF;

    IF p_days = 7 THEN
        v_amount := v_acc.fixed7;
        v_deposited_at := v_acc.fixed7_until - interval '7 days';
    ELSIF p_days = 30 THEN
        v_amount := v_acc.fixed30;
        v_deposited_at := v_acc.fixed30_until - interval '30 days';
    ELSE
        RETURN jsonb_build_object('success', false, 'message', '参数错误');
    END IF;
    IF v_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '该定期没有存款');
    END IF;

    -- 已到期：按定期总利率结算；未到期提前支取：按活期 0.1%/天算已存天数
    v_elapsed_days := GREATEST(floor(extract(epoch FROM (now() - v_deposited_at)) / 86400), 0);
    IF v_elapsed_days >= p_days THEN
        -- 到期
        v_interest := floor(v_amount * CASE WHEN p_days = 7 THEN 0.02 ELSE 0.10 END);
    ELSE
        -- 提前支取：活期利率 × 已存天数
        v_interest := floor(v_amount * 0.001 * v_elapsed_days);   -- 活期 0.1%/天
    END IF;

    IF p_days = 7 THEN
        UPDATE public.bank_accounts SET fixed7 = 0, fixed7_until = NULL WHERE user_id = p_user_id;
    ELSE
        UPDATE public.bank_accounts SET fixed30 = 0, fixed30_until = NULL WHERE user_id = p_user_id;
    END IF;
    UPDATE public.profiles SET nb_balance = nb_balance + v_amount + v_interest WHERE id = p_user_id;
    INSERT INTO public.bank_logs (user_id, type, amount, detail)
    VALUES (p_user_id, CASE WHEN p_days = 7 THEN 'fixed7_withdraw' ELSE 'fixed30_withdraw' END,
            v_amount + v_interest, format('定期%s天支取（本金 %s + 利息 %s）', p_days, v_amount, v_interest));
    RETURN jsonb_build_object('success', true, 'message',
        format('已取出 %s NB币（本金 %s + 利息 %s）', v_amount + v_interest, v_amount, v_interest));
END;
$$;

-- ========== 6. 贷款 ==========

-- 抵押贷（额度 = 存款×80%）
CREATE OR REPLACE FUNCTION public.bank_loan(p_user_id uuid, p_amount bigint, p_days integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_acc record;
    v_limit bigint;
BEGIN
    IF p_days NOT IN (7, 30) THEN
        RETURN jsonb_build_object('success', false, 'message', '贷款期限只有 7 天或 30 天');
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '金额必须大于0');
    END IF;
    SELECT * INTO v_acc FROM public.bank_accounts WHERE user_id = p_user_id;
    IF v_acc.user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '请先存款后再抵押贷款');
    END IF;
    IF v_acc.loan_principal > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '已有未还清的抵押贷款');
    END IF;

    v_limit := floor((v_acc.deposit + v_acc.fixed7 + v_acc.fixed30) * 0.8);
    IF p_amount > v_limit THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('超出抵押额度（当前可贷 %s NB币）', v_limit));
    END IF;

    -- 冻结贷款时点的全部存款（活期+定期，作为抵押）；之后新存入的部分可自由取
    UPDATE public.bank_accounts
       SET loan_principal = p_amount,
           loan_until = now() + (p_days || ' days')::interval,
           frozen = true,
           frozen_amount = v_acc.deposit + v_acc.fixed7 + v_acc.fixed30
     WHERE user_id = p_user_id;
    UPDATE public.profiles SET nb_balance = nb_balance + p_amount WHERE id = p_user_id;
    INSERT INTO public.bank_logs (user_id, type, amount, detail)
    VALUES (p_user_id, 'loan', p_amount, format('抵押贷 %s 天（到期总利率 10%%）', p_days));
    RETURN jsonb_build_object('success', true, 'message',
        format('贷款 %s NB币到账（%s 天，到期总利率 10%%），存款已冻结为抵押', p_amount, p_days));
END;
$$;

-- 信用贷（按信誉分）
CREATE OR REPLACE FUNCTION public.bank_credit_loan(p_user_id uuid, p_amount bigint, p_days integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_acc record;
    v_limit bigint;
    v_rate numeric;
BEGIN
    IF p_days NOT IN (7, 30) THEN
        RETURN jsonb_build_object('success', false, 'message', '贷款期限只有 7 天或 30 天');
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '金额必须大于0');
    END IF;
    SELECT * INTO v_acc FROM public.bank_accounts WHERE user_id = p_user_id;
    IF v_acc.user_id IS NULL THEN
        INSERT INTO public.bank_accounts (user_id) VALUES (p_user_id);
        SELECT * INTO v_acc FROM public.bank_accounts WHERE user_id = p_user_id;
    END IF;
    IF v_acc.credit_score < 300 THEN
        RETURN jsonb_build_object('success', false, 'message', '信誉分不足 300，无法信用贷款');
    END IF;
    IF v_acc.loan_credit > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '已有未还清的信用贷款');
    END IF;

    IF v_acc.credit_score >= 800 THEN
        v_limit := v_acc.credit_score * 1500;
        v_rate := 0.108;
    ELSIF v_acc.credit_score >= 600 THEN
        v_limit := v_acc.credit_score * 1000;
        v_rate := 0.12;
    ELSE
        v_limit := v_acc.credit_score * 500;
        v_rate := 0.12;
    END IF;
    IF p_amount > v_limit THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('超出信用额度（当前可贷 %s NB币）', v_limit));
    END IF;

    UPDATE public.bank_accounts
       SET loan_credit = p_amount,
           loan_credit_until = now() + (p_days || ' days')::interval
     WHERE user_id = p_user_id;
    UPDATE public.profiles SET nb_balance = nb_balance + p_amount WHERE id = p_user_id;
    INSERT INTO public.bank_logs (user_id, type, amount, detail)
    VALUES (p_user_id, 'loan_credit', p_amount,
        format('信用贷 %s 天（到期总利率 %s%%）', p_days,
               CASE WHEN v_acc.credit_score >= 800 THEN '10.8' ELSE '12' END));
    RETURN jsonb_build_object('success', true, 'message',
        format('信用贷款 %s NB币到账（%s 天，到期总利率 %s%%）', p_amount, p_days,
               CASE WHEN v_acc.credit_score >= 800 THEN '10.8' ELSE '12' END));
END;
$$;

-- ========== 7. 还款（提前还/到期自动扣） ==========

-- 还抵押贷（支持提前还，利息按实际借款天数）
CREATE OR REPLACE FUNCTION public.bank_repay(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_acc record;
    v_loan_start timestamptz;   -- 贷款日（到期时间反推：假设 7 天，用 log 更准但简化按到期推算）
    v_days integer;
    v_interest bigint;
    v_total bigint;
    v_balance bigint;
BEGIN
    SELECT * INTO v_acc FROM public.bank_accounts WHERE user_id = p_user_id;
    IF v_acc.user_id IS NULL OR v_acc.loan_principal <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '没有未还清的抵押贷款');
    END IF;

    -- 从日志取贷款时间（最准确）
    SELECT created_at INTO v_loan_start
      FROM public.bank_logs
     WHERE user_id = p_user_id AND type = 'loan'
     ORDER BY id DESC LIMIT 1;
    IF v_loan_start IS NULL THEN
        v_loan_start := now() - interval '1 day';   -- 兜底
    END IF;

    v_days := GREATEST(ceil(extract(epoch FROM (now() - v_loan_start)) / 86400), 1);
    v_interest := floor(v_acc.loan_principal * 0.10 * v_days / 30);
    v_total := v_acc.loan_principal + v_interest;

    SELECT nb_balance INTO v_balance FROM public.profiles WHERE id = p_user_id;
    IF v_balance < v_total THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('余额不足（需还 %s NB币，当前余额 %s）', v_total, v_balance));
    END IF;

    UPDATE public.profiles SET nb_balance = nb_balance - v_total WHERE id = p_user_id;
    UPDATE public.bank_accounts
       SET loan_principal = 0, loan_until = NULL, frozen = false, frozen_amount = 0
     WHERE user_id = p_user_id;
    -- 信誉分 +5
    UPDATE public.bank_accounts
       SET credit_score = LEAST(credit_score + 5, 1000)
     WHERE user_id = p_user_id;
    INSERT INTO public.bank_logs (user_id, type, amount, detail)
    VALUES (p_user_id, 'repay', v_total, format('偿还抵押贷（本金 %s + 利息 %s，%s 天）', v_acc.loan_principal, v_interest, v_days));
    INSERT INTO public.bank_logs (user_id, type, amount, detail)
    VALUES (p_user_id, 'credit_change', 5, '按时还款 +5');
    RETURN jsonb_build_object('success', true, 'message',
        format('已还款 %s NB币（本金 %s + 利息 %s），存款已解冻，信誉分 +5', v_total, v_acc.loan_principal, v_interest));
END;
$$;

-- 还信用贷（支持提前还，利息按实际借款天数）
CREATE OR REPLACE FUNCTION public.bank_repay_credit(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_acc record;
    v_loan_start timestamptz;
    v_days integer;
    v_interest bigint;
    v_total bigint;
    v_balance bigint;
BEGIN
    SELECT * INTO v_acc FROM public.bank_accounts WHERE user_id = p_user_id;
    IF v_acc.user_id IS NULL OR v_acc.loan_credit <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', '没有未还清的信用贷款');
    END IF;

    SELECT created_at INTO v_loan_start
      FROM public.bank_logs
     WHERE user_id = p_user_id AND type = 'loan_credit'
     ORDER BY id DESC LIMIT 1;
    IF v_loan_start IS NULL THEN
        v_loan_start := now() - interval '1 day';
    END IF;

    v_days := GREATEST(ceil(extract(epoch FROM (now() - v_loan_start)) / 86400), 1);
    v_interest := floor(v_acc.loan_credit * (CASE WHEN v_acc.credit_score >= 800 THEN 0.108 ELSE 0.12 END) * v_days / 30);
    v_total := v_acc.loan_credit + v_interest;

    SELECT nb_balance INTO v_balance FROM public.profiles WHERE id = p_user_id;
    IF v_balance < v_total THEN
        RETURN jsonb_build_object('success', false, 'message',
            format('余额不足（需还 %s NB币，当前余额 %s）', v_total, v_balance));
    END IF;

    UPDATE public.profiles SET nb_balance = nb_balance - v_total WHERE id = p_user_id;
    UPDATE public.bank_accounts
       SET loan_credit = 0, loan_credit_until = NULL
     WHERE user_id = p_user_id;
    UPDATE public.bank_accounts
       SET credit_score = LEAST(credit_score + 5, 1000)
     WHERE user_id = p_user_id;
    INSERT INTO public.bank_logs (user_id, type, amount, detail)
    VALUES (p_user_id, 'repay_credit', v_total, format('偿还信用贷（本金 %s + 利息 %s，%s 天）', v_acc.loan_credit, v_interest, v_days));
    INSERT INTO public.bank_logs (user_id, type, amount, detail)
    VALUES (p_user_id, 'credit_change', 5, '按时还款 +5');
    RETURN jsonb_build_object('success', true, 'message',
        format('已还款 %s NB币（本金 %s + 利息 %s），信誉分 +5', v_total, v_acc.loan_credit, v_interest));
END;
$$;

-- ========== 8. 每日结算（利息 + 到期贷款处理 + 逾期罚息） ==========

CREATE OR REPLACE FUNCTION public.bank_daily_settle()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_acc record;
    v_interest bigint;
    v_processed integer := 0;
BEGIN
    FOR v_acc IN SELECT * FROM public.bank_accounts WHERE
        deposit > 0 OR fixed7 > 0 OR fixed30 > 0 OR
        loan_principal > 0 OR loan_credit > 0
    LOOP
        -- 1) 活期利息 0.1%
        IF v_acc.deposit > 0 THEN
            v_interest := floor(v_acc.deposit * 0.001);   -- 活期 0.1%/天
            IF v_interest > 0 THEN
                UPDATE public.bank_accounts SET deposit = deposit + v_interest
                 WHERE user_id = v_acc.user_id;
                UPDATE public.profiles SET nb_balance = nb_balance + v_interest
                 WHERE id = v_acc.user_id;
                INSERT INTO public.bank_logs (user_id, type, amount, detail)
                VALUES (v_acc.user_id, 'interest', v_interest, '活期利息 0.1%');
            END IF;
        END IF;

        -- 2) 定期 7 天到期 → 转活期+利息
        IF v_acc.fixed7 > 0 AND v_acc.fixed7_until IS NOT NULL
           AND v_acc.fixed7_until <= now() THEN
            v_interest := floor(v_acc.fixed7 * 0.02);
            UPDATE public.bank_accounts
               SET deposit = deposit + v_acc.fixed7 + v_interest,
                   fixed7 = 0, fixed7_until = NULL
             WHERE user_id = v_acc.user_id;
            UPDATE public.profiles SET nb_balance = nb_balance + v_acc.fixed7 + v_interest
             WHERE id = v_acc.user_id;
            INSERT INTO public.bank_logs (user_id, type, amount, detail)
            VALUES (v_acc.user_id, 'interest', v_interest,
                format('定期7天到期（本金 %s + 利息 %s，总利率2%%）', v_acc.fixed7, v_interest));
        END IF;

        -- 3) 定期 30 天到期 → 转活期+利息
        IF v_acc.fixed30 > 0 AND v_acc.fixed30_until IS NOT NULL
           AND v_acc.fixed30_until <= now() THEN
            v_interest := floor(v_acc.fixed30 * 0.10);
            UPDATE public.bank_accounts
               SET deposit = deposit + v_acc.fixed30 + v_interest,
                   fixed30 = 0, fixed30_until = NULL
             WHERE user_id = v_acc.user_id;
            UPDATE public.profiles SET nb_balance = nb_balance + v_acc.fixed30 + v_interest
             WHERE id = v_acc.user_id;
            INSERT INTO public.bank_logs (user_id, type, amount, detail)
            VALUES (v_acc.user_id, 'interest', v_interest,
                format('定期30天到期（本金 %s + 利息 %s，总利率10%%）', v_acc.fixed30, v_interest));
        END IF;

        -- 4) 抵押贷到期 → 自动扣本息（按实际天数折算，7天≈2.33%、30天=10%）；余额不足 → 逾期罚息+信誉-15
        IF v_acc.loan_principal > 0 AND v_acc.loan_until IS NOT NULL
           AND v_acc.loan_until <= now() THEN
            DECLARE
                v_loan_start timestamptz;
                v_days integer;
            BEGIN
                SELECT created_at INTO v_loan_start
                  FROM public.bank_logs
                 WHERE user_id = v_acc.user_id AND type = 'loan'
                 ORDER BY id DESC LIMIT 1;
                IF v_loan_start IS NULL THEN v_loan_start := now() - interval '1 day'; END IF;
                v_days := GREATEST(ceil(extract(epoch FROM (now() - v_loan_start)) / 86400), 1);
                v_interest := floor(v_acc.loan_principal * 0.10 * v_days / 30);
                IF (SELECT nb_balance FROM public.profiles WHERE id = v_acc.user_id) >=
                   v_acc.loan_principal + v_interest THEN
                    UPDATE public.profiles SET nb_balance = nb_balance - v_acc.loan_principal - v_interest
                     WHERE id = v_acc.user_id;
                    UPDATE public.bank_accounts
                       SET loan_principal = 0, loan_until = NULL, frozen = false, frozen_amount = 0
                     WHERE user_id = v_acc.user_id;
                    UPDATE public.bank_accounts
                       SET credit_score = LEAST(credit_score + 5, 1000)
                     WHERE user_id = v_acc.user_id;
                    INSERT INTO public.bank_logs (user_id, type, amount, detail)
                    VALUES (v_acc.user_id, 'repay', v_acc.loan_principal + v_interest,
                        format('抵押贷自动还款（本金 %s + 利息 %s，%s 天）', v_acc.loan_principal, v_interest, v_days));
                    INSERT INTO public.bank_logs (user_id, type, amount, detail)
                    VALUES (v_acc.user_id, 'credit_change', 5, '按时还款 +5');
                ELSE
                    -- 逾期：罚息累加到本金（复利滚存）+ 信誉-15 + 顺延一天
                    v_interest := floor(v_acc.loan_principal * 0.001);
                    UPDATE public.bank_accounts
                       SET loan_principal = loan_principal + v_interest,
                           credit_score = GREATEST(credit_score - 15, 0),
                           loan_until = now() + interval '1 day'
                     WHERE user_id = v_acc.user_id;
                    INSERT INTO public.bank_logs (user_id, type, amount, detail)
                    VALUES (v_acc.user_id, 'penalty', v_interest,
                        format('抵押贷逾期罚息（本金 %s，罚息 %s 累加进本金）', v_acc.loan_principal, v_interest));
                    INSERT INTO public.bank_logs (user_id, type, amount, detail)
                    VALUES (v_acc.user_id, 'credit_change', -15, '贷款逾期 -15');
                END IF;
            END;
        END IF;

        -- 5) 信用贷到期 → 自动扣本息（按实际天数折算）；余额不足 → 逾期罚息+信誉-15
        IF v_acc.loan_credit > 0 AND v_acc.loan_credit_until IS NOT NULL
           AND v_acc.loan_credit_until <= now() THEN
            DECLARE
                v_loan_start2 timestamptz;
                v_days2 integer;
            BEGIN
                SELECT created_at INTO v_loan_start2
                  FROM public.bank_logs
                 WHERE user_id = v_acc.user_id AND type = 'loan_credit'
                 ORDER BY id DESC LIMIT 1;
                IF v_loan_start2 IS NULL THEN v_loan_start2 := now() - interval '1 day'; END IF;
                v_days2 := GREATEST(ceil(extract(epoch FROM (now() - v_loan_start2)) / 86400), 1);
                v_interest := floor(v_acc.loan_credit * (CASE WHEN v_acc.credit_score >= 800 THEN 0.108 ELSE 0.12 END) * v_days2 / 30);
                IF (SELECT nb_balance FROM public.profiles WHERE id = v_acc.user_id) >=
                   v_acc.loan_credit + v_interest THEN
                    UPDATE public.profiles SET nb_balance = nb_balance - v_acc.loan_credit - v_interest
                     WHERE id = v_acc.user_id;
                    UPDATE public.bank_accounts
                       SET loan_credit = 0, loan_credit_until = NULL
                     WHERE user_id = v_acc.user_id;
                    UPDATE public.bank_accounts
                       SET credit_score = LEAST(credit_score + 5, 1000)
                     WHERE user_id = v_acc.user_id;
                    INSERT INTO public.bank_logs (user_id, type, amount, detail)
                    VALUES (v_acc.user_id, 'repay_credit', v_acc.loan_credit + v_interest,
                        format('信用贷自动还款（本金 %s + 利息 %s，%s 天）', v_acc.loan_credit, v_interest, v_days2));
                    INSERT INTO public.bank_logs (user_id, type, amount, detail)
                    VALUES (v_acc.user_id, 'credit_change', 5, '按时还款 +5');
                ELSE
                    v_interest := floor(v_acc.loan_credit * 0.001);
                    UPDATE public.bank_accounts
                       SET loan_credit = loan_credit + v_interest,
                           credit_score = GREATEST(credit_score - 15, 0),
                           loan_credit_until = now() + interval '1 day'
                     WHERE user_id = v_acc.user_id;
                    INSERT INTO public.bank_logs (user_id, type, amount, detail)
                    VALUES (v_acc.user_id, 'penalty', v_interest,
                        format('信用贷逾期罚息（本金 %s，罚息 %s 累加进本金）', v_acc.loan_credit, v_interest));
                    INSERT INTO public.bank_logs (user_id, type, amount, detail)
                    VALUES (v_acc.user_id, 'credit_change', -15, '贷款逾期 -15');
                END IF;
            END;
        END IF;

        v_processed := v_processed + 1;
    END LOOP;
    RETURN v_processed;
END;
$$;

-- ========== 9. 日志查询 ==========
CREATE OR REPLACE FUNCTION public.get_bank_logs(p_user_id uuid, p_limit integer DEFAULT 30)
RETURNS TABLE (type text, amount bigint, detail text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT b.type, b.amount, b.detail, b.created_at
      FROM public.bank_logs b
     WHERE b.user_id = p_user_id
     ORDER BY b.id DESC
     LIMIT p_limit;
END;
$$;

-- ========== 10. 定时任务：每天北京时间 00:05 结算 ==========
DO $$
BEGIN
    BEGIN
        PERFORM cron.schedule('bank-daily-settle', '5 16 * * *',
            'SELECT public.bank_daily_settle()');
    EXCEPTION WHEN others THEN
        NULL;
    END;
END $$;

-- ========== 11. 权限 ==========
GRANT EXECUTE ON FUNCTION public.get_bank_account(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.bank_deposit(uuid, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.bank_fixed_deposit(uuid, integer, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.bank_withdraw(uuid, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.bank_fixed_withdraw(uuid, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.bank_loan(uuid, integer, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.bank_credit_loan(uuid, integer, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.bank_repay(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.bank_repay_credit(uuid) TO anon;
-- bank_daily_settle 不授权给 anon：只允许 pg_cron 定时任务调用
-- （否则任何用户都能手动触发全站结算；如需手动测试由管理员用 SQL 调用）
GRANT EXECUTE ON FUNCTION public.get_bank_logs(uuid, integer) TO anon;
-- 撤销（幂等，防止旧版本授权残留）
REVOKE EXECUTE ON FUNCTION public.bank_daily_settle() FROM anon, authenticated, public;
