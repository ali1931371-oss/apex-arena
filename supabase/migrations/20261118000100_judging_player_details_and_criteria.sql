-- APEX ARENA: secure per-match player judging details and categorized criteria
-- Apply manually in Supabase SQL Editor after reviewing. This file is NOT executed by GitHub/Cloudflare.

ALTER TABLE public.tournament_criteria
  ADD COLUMN IF NOT EXISTS criterion_group text NOT NULL DEFAULT 'general';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.tournament_criteria'::regclass
      AND conname = 'tournament_criteria_criterion_group_check'
  ) THEN
    ALTER TABLE public.tournament_criteria
      ADD CONSTRAINT tournament_criteria_criterion_group_check
      CHECK (criterion_group IN ('general','citizen','mafia','bonus','penalty'));
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.match_player_judging_details (
  match_id uuid NOT NULL,
  player_id uuid NOT NULL,
  side text NOT NULL CHECK (side IN ('شهروند','مافیا')),
  role_name text NOT NULL CHECK (length(btrim(role_name)) BETWEEN 1 AND 100),
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (match_id, player_id),
  CONSTRAINT match_player_judging_details_match_player_fkey
    FOREIGN KEY (match_id, player_id)
    REFERENCES public.match_players(match_id, player_id)
    ON DELETE CASCADE
);

ALTER TABLE public.match_player_judging_details ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.match_player_judging_details TO authenticated;
DROP POLICY IF EXISTS match_player_judging_details_manager_read
  ON public.match_player_judging_details;
CREATE POLICY match_player_judging_details_manager_read
  ON public.match_player_judging_details
  FOR SELECT TO authenticated
  USING (public.is_apex_manager());

REVOKE INSERT, UPDATE, DELETE ON public.match_player_judging_details FROM anon, authenticated;
REVOKE ALL ON public.match_player_judging_details FROM anon;

CREATE OR REPLACE FUNCTION public.get_manager_match_players(p_match_id uuid)
RETURNS TABLE(
  player_id uuid,
  display_name text,
  player_code text,
  side text,
  role_name text,
  seat_number integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر مجاز به مشاهده و ویرایش اطلاعات بازیکنان است.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.matches m WHERE m.id = p_match_id) THEN
    RAISE EXCEPTION 'مسابقه پیدا نشد.';
  END IF;

  RETURN QUERY
  SELECT pl.id, pl.display_name, pl.player_code,
         d.side, d.role_name, mp.seat_number
  FROM public.match_players mp
  JOIN public.players pl ON pl.id = mp.player_id
  LEFT JOIN public.match_player_judging_details d
    ON d.match_id = mp.match_id AND d.player_id = mp.player_id
  WHERE mp.match_id = p_match_id
  ORDER BY mp.seat_number NULLS LAST, pl.display_name;
END;
$$;

CREATE OR REPLACE FUNCTION public.save_match_player_judging_details(
  p_match_id uuid,
  p_player_id uuid,
  p_side text,
  p_role_name text,
  p_seat_number integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر مجاز به ثبت اطلاعات بازیکنان است.';
  END IF;

  IF p_side NOT IN ('شهروند','مافیا') THEN
    RAISE EXCEPTION 'ساید باید شهروند یا مافیا باشد.';
  END IF;
  IF p_role_name IS NULL OR length(btrim(p_role_name)) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'نام نقش باید بین ۱ تا ۱۰۰ نویسه باشد.';
  END IF;
  IF p_seat_number IS NOT NULL AND p_seat_number NOT BETWEEN 1 AND 99 THEN
    RAISE EXCEPTION 'شماره صندلی باید بین ۱ تا ۹۹ باشد.';
  END IF;

  UPDATE public.match_players
  SET seat_number = p_seat_number
  WHERE match_id = p_match_id AND player_id = p_player_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'این بازیکن در مسابقه انتخاب‌شده ثبت نشده است.';
  END IF;

  INSERT INTO public.match_player_judging_details
    (match_id, player_id, side, role_name, created_by, updated_at)
  VALUES
    (p_match_id, p_player_id, p_side, btrim(p_role_name), auth.uid(), now())
  ON CONFLICT (match_id, player_id)
  DO UPDATE SET
    side = EXCLUDED.side,
    role_name = EXCLUDED.role_name,
    updated_at = now();

  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_judge_match_details(p_match_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_assigned_tournament_judge(p_match_id) THEN
    RAISE EXCEPTION 'شما داور این مسابقه نیستید.';
  END IF;

  SELECT jsonb_build_object(
    'match', jsonb_build_object(
      'id', m.id,
      'tournament_id', m.tournament_id,
      'match_number', m.match_number,
      'status', m.status,
      'stage_id', m.stage_id,
      'group_id', m.group_id
    ),
    'players', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'player_id', pl.id,
        'display_name', pl.display_name,
        'player_code', pl.player_code,
        'audio_player_id', pl.audio_player_id,
        'seat_number', mp.seat_number,
        'side', d.side,
        'role_name', d.role_name
      ) ORDER BY mp.seat_number NULLS LAST, pl.display_name)
      FROM public.match_players mp
      JOIN public.players pl ON pl.id = mp.player_id
      LEFT JOIN public.match_player_judging_details d
        ON d.match_id = mp.match_id AND d.player_id = mp.player_id
      WHERE mp.match_id = m.id
        AND NOT EXISTS (
          SELECT 1 FROM public.tournament_judges tj
          WHERE tj.tournament_id = m.tournament_id
            AND tj.judge_id = pl.user_id
            AND tj.is_player_restored = false
        )
    ), '[]'::jsonb),
    'criteria', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', tc.id,
        'criterion_name', tc.criterion_name,
        'description', tc.description,
        'min_points', tc.min_points,
        'max_points', tc.max_points,
        'weight', tc.weight,
        'score_type', tc.score_type,
        'calculation_type', tc.calculation_type,
        'aggregation_method', tc.aggregation_method,
        'display_order', tc.display_order,
        'criterion_group', tc.criterion_group
      ) ORDER BY tc.display_order)
      FROM public.tournament_criteria tc
      WHERE tc.tournament_id = m.tournament_id
        AND tc.is_active = true
    ), '[]'::jsonb),
    'submissions', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', ss.id,
        'player_id', ss.player_id,
        'status', ss.status,
        'items', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'criterion_id', si.criterion_id,
            'raw_points', si.raw_points,
            'notes', si.notes
          ))
          FROM public.score_items si
          WHERE si.submission_id = ss.id
        ), '[]'::jsonb)
      ))
      FROM public.score_submissions ss
      WHERE ss.match_id = m.id
        AND ss.judge_id = auth.uid()
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.matches m
  WHERE m.id = p_match_id;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_manager_match_players(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_match_player_judging_details(uuid, uuid, text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_judge_match_details(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_manager_match_players(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_match_player_judging_details(uuid, uuid, text, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_judge_match_details(uuid) TO authenticated;

-- Initial judging criteria for the existing APEX ARENA test tournament only.
INSERT INTO public.tournament_criteria
  (tournament_id, criterion_name, description, min_points, max_points, weight,
   score_type, is_active, calculation_type, aggregation_method, display_order, criterion_group)
SELECT
  'dfdb829e-1198-4f1a-9be5-d21549272865'::uuid,
  v.criterion_name, v.description, v.min_points, v.max_points, 1,
  v.score_type, true, NULL, NULL, v.display_order, v.criterion_group
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
) AS v(criterion_name,description,min_points,max_points,score_type,display_order,criterion_group)
WHERE EXISTS (
  SELECT 1 FROM public.tournaments t
  WHERE t.id = 'dfdb829e-1198-4f1a-9be5-d21549272865'::uuid
)
AND NOT EXISTS (
  SELECT 1 FROM public.tournament_criteria existing
  WHERE existing.tournament_id = 'dfdb829e-1198-4f1a-9be5-d21549272865'::uuid
    AND existing.criterion_name = v.criterion_name
);
