-- ============================================================
-- NB频道 - 日内走势线数据支持（替换快照保留策略）
-- 作用：把 stock_history_full 的自动清理从"保留30条"改为"保留2000条"，
--       以便绘制"当天从开盘到收盘的市值走势线"（约30小时采样）。
-- ============================================================

-- 1. 移除 stock_history_full 上原有的所有清理触发器（保留量未知，统一重建）
DO $$
DECLARE t record;
BEGIN
    FOR t IN SELECT tgname FROM pg_trigger
             WHERE tgrelid = 'public.stock_history_full'::regclass
               AND NOT tgisinternal
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.stock_history_full', t.tgname);
    END LOOP;
END $$;

-- 2. 重写清理函数：超过 2000 条才删最旧一条
CREATE OR REPLACE FUNCTION public.delete_old_history_full()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    row_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO row_count FROM public.stock_history_full;
    IF row_count > 2000 THEN
        DELETE FROM public.stock_history_full
        WHERE recorded_at = (SELECT recorded_at FROM public.stock_history_full ORDER BY recorded_at ASC LIMIT 1);
    END IF;
    RETURN NEW;
END;
$function$;

-- 3. 重新挂载触发器
DROP TRIGGER IF EXISTS trg_clean_history_full ON public.stock_history_full;
CREATE TRIGGER trg_clean_history_full
AFTER INSERT ON public.stock_history_full
FOR EACH ROW EXECUTE FUNCTION public.delete_old_history_full();

-- 4. 说明
-- 前端历史快照写入频率为 60 秒/条（saveFullSnapshot 节流），
-- 2000 条 × 60秒/条 ≈ 33 小时，可覆盖"当天从开盘到最新"的完整走势 + 前一天。
-- 若数据量担心，可自行把 2000 改小（如 1000 ≈ 16.7 小时）。
