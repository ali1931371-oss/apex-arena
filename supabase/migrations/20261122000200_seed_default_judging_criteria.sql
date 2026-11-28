-- APEX ARENA: attach the established 280-point rubric to every tournament.
-- Existing tournament-specific criteria are preserved; only missing standard rows are added.
-- New tournaments receive the same default rubric automatically.

BEGIN;

CREATE OR REPLACE FUNCTION public.seed_default_tournament_criteria(
  p_tournament_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_tournament_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.tournament_criteria (
    tournament_id,
    criterion_name,
    description,
    min_points,
    max_points,
    weight,
    score_type,
    is_active,
    display_order,
    criterion_group
  )
  SELECT
    p_tournament_id,
    v.criterion_name,
    v.description,
    v.min_points,
    v.max_points,
    1,
    v.score_type,
    true,
    v.display_order,
    v.criterion_group
  FROM (VALUES
    ('تحلیل و استدلال','کیفیت تحلیل اتفاقات و رفتارها بر پایه اطلاعات بازی',0::numeric,20::numeric,'positive'::text,1,'general'),
    ('فکت‌سازی مستند','ارائه فکت دقیق، مرتبط و قابل پیگیری',0,20,'positive',2,'general'),
    ('تشخیص و استنتاج','رسیدن به نتیجه منطقی درباره نقش‌ها و موقعیت‌ها',0,20,'positive',3,'general'),
    ('کیفیت تصمیم‌گیری','انتخاب تصمیم مناسب با توجه به اطلاعات موجود',0,20,'positive',4,'general'),
    ('مدیریت رأی','زمان‌بندی و هدفمندی رأی در جهت پیروزی ساید',0,20,'positive',5,'general'),
    ('مدیریت جریان بازی','اثرگذاری مؤثر بر روند بحث و تصمیم‌های بازی',0,20,'positive',6,'general'),
    ('استفاده از قابلیت نقش','استفاده درست، به‌موقع و مؤثر از توانایی نقش',0,20,'positive',7,'general'),
    ('ثبات عملکرد','حفظ انسجام تحلیل و تصمیم‌ها در طول بازی',0,20,'positive',8,'general'),

    ('تشخیص اعضای مافیا','شناسایی مستدل و دقیق بازیکنان مافیا',0,20,'positive',9,'citizen'),
    ('رأی‌گیری هدفمند','رأی مستند و مؤثر برای حذف تهدید اصلی',0,20,'positive',10,'citizen'),
    ('تیم‌سازی شهروندی','ایجاد ائتلاف منطقی بر پایه شواهد',0,20,'positive',11,'citizen'),
    ('کشف تناقض‌ها','شناسایی تناقض رفتاری و گفتاری',0,20,'positive',12,'citizen'),
    ('هم‌جهت‌سازی شهروندان','کمک به تصمیم جمعی بدون ایجاد سردرگمی',0,20,'positive',13,'citizen'),
    ('حفظ انسجام ساید','تقویت هماهنگی شهروندان در مراحل حساس',0,20,'positive',14,'citizen'),

    ('فریب و پنهان‌سازی هویت','حفظ پوشش و مدیریت ظن به‌شکل هوشمندانه',0,20,'positive',15,'mafia'),
    ('نفوذ در تصمیم شهروندان','اثرگذاری بر برداشت و انتخاب شهروندان',0,20,'positive',16,'mafia'),
    ('انحراف تحلیلی','ایجاد ابهام و مسیر تحلیلی گمراه‌کننده',0,20,'positive',17,'mafia'),
    ('هماهنگی با هم‌تیمی‌ها','مدیریت ارتباط و انسجام ساید مافیا',0,20,'positive',18,'mafia'),
    ('رأی‌سازی و جهت‌دهی','هدایت رأی‌ها در راستای هدف ساید',0,20,'positive',19,'mafia'),
    ('دفاع از خود و هم‌تیمی','دفاع مؤثر و مدیریت موقعیت‌های بحرانی',0,20,'positive',20,'mafia'),

    ('اخلاق حرفه‌ای و احترام','رعایت احترام به بازیکنان و داوران؛ حداکثر ۵ امتیاز',0,5,'positive',21,'bonus'),
    ('بازی جوانمردانه و عادلانه','رعایت انصاف و قوانین؛ حداکثر ۵ امتیاز',0,5,'positive',22,'bonus'),
    ('معارفه خلاقانه و حرفه‌ای','کیفیت معارفه؛ حداکثر ۳ امتیاز',0,3,'positive',23,'bonus'),
    ('کنترل خشم و ادب در تنش','حفظ آرامش و ادب؛ حداکثر ۵ امتیاز',0,5,'positive',24,'bonus'),
    ('همکاری و تعامل سازنده','تعامل مؤثر؛ حداکثر ۲ امتیاز',0,2,'positive',25,'bonus'),

    ('بی‌احترامی به بازیکن یا داور','کسر امتیاز؛ حداکثر ۵ امتیاز',0,5,'negative',26,'penalty'),
    ('فحاشی و کلام زشت','کسر امتیاز؛ حداکثر ۸ امتیاز',0,8,'negative',27,'penalty'),
    ('تخریب شخصیت و توهین شخصی','کسر امتیاز؛ حداکثر ۸ امتیاز',0,8,'negative',28,'penalty'),
    ('رفتار ناجوانمردانه یا اخلال','کسر امتیاز؛ حداکثر ۱۰ امتیاز',0,10,'negative',29,'penalty'),
    ('عدم کنترل خشم و ایجاد تنش','کسر امتیاز؛ حداکثر ۵ امتیاز',0,5,'negative',30,'penalty'),
    ('نقض قوانین مسابقه','کسر امتیاز؛ حداکثر ۱۰ امتیاز',0,10,'negative',31,'penalty')
  ) AS v(
    criterion_name,
    description,
    min_points,
    max_points,
    score_type,
    display_order,
    criterion_group
  )
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.tournament_criteria existing
    WHERE existing.tournament_id = p_tournament_id
      AND existing.criterion_name = v.criterion_name
  );
END;
$$;

REVOKE ALL ON FUNCTION public.seed_default_tournament_criteria(uuid)
  FROM PUBLIC, anon, authenticated;

-- Backfill every tournament already in the system, including tournaments
-- created after the original test-tournament-only criteria migration.
DO $$
DECLARE
  v_tournament_id uuid;
BEGIN
  FOR v_tournament_id IN
    SELECT id FROM public.tournaments
  LOOP
    PERFORM public.seed_default_tournament_criteria(v_tournament_id);
  END LOOP;
END;
$$;

-- Ensure tournaments created in the future also start with the same rubric.
CREATE OR REPLACE FUNCTION public.seed_criteria_after_tournament_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public.seed_default_tournament_criteria(NEW.id);
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.seed_criteria_after_tournament_insert()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS seed_default_criteria_for_new_tournament
  ON public.tournaments;

CREATE TRIGGER seed_default_criteria_for_new_tournament
AFTER INSERT ON public.tournaments
FOR EACH ROW
EXECUTE FUNCTION public.seed_criteria_after_tournament_insert();

NOTIFY pgrst, 'reload schema';

COMMIT;
