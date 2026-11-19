-- APEX ARENA: persist a scenario and its role configuration atomically.
-- Prepared for review. Do NOT run until explicitly approved.

CREATE OR REPLACE FUNCTION public.save_managed_scenario(
  p_scenario_id uuid,
  p_name text,
  p_roles jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scenario_id uuid;
  v_name text := btrim(coalesce(p_name, ''));
  v_role jsonb;
  v_role_name text;
  v_faction text;
  v_role_count integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر یا مسئول مسابقه مجاز به ذخیره سناریو است.';
  END IF;

  IF v_name = '' OR length(v_name) > 120 THEN
    RAISE EXCEPTION 'نام سناریو باید بین ۱ تا ۱۲۰ نویسه باشد.';
  END IF;

  IF p_roles IS NULL OR jsonb_typeof(p_roles) <> 'array' OR jsonb_array_length(p_roles) > 30 THEN
    RAISE EXCEPTION 'فهرست نقش‌ها معتبر نیست یا بیش از ۳۰ نقش دارد.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_roles) AS item
    GROUP BY btrim(item->>'name')
    HAVING btrim(item->>'name') = '' OR count(*) > 1
  ) THEN
    RAISE EXCEPTION 'نام نقش‌ها نباید خالی یا تکراری باشد.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_roles) AS item
    WHERE btrim(coalesce(item->>'name', '')) = ''
       OR length(btrim(item->>'name')) > 120
       OR btrim(coalesce(item->>'side', '')) = ''
       OR coalesce(item->>'count', '') !~ '^[0-9]+$'
       OR (item->>'count')::integer NOT BETWEEN 1 AND 20
  ) THEN
    RAISE EXCEPTION 'اطلاعات یکی از نقش‌ها معتبر نیست؛ نام، جناح و تعداد ۱ تا ۲۰ را بررسی کن.';
  END IF;

  IF p_scenario_id IS NULL THEN
    IF EXISTS (
      SELECT 1 FROM public.scenarios
      WHERE lower(btrim(name)) = lower(v_name)
    ) THEN
      RAISE EXCEPTION 'سناریویی با این نام از قبل وجود دارد.';
    END IF;

    INSERT INTO public.scenarios (name, description, is_active)
    VALUES (v_name, NULL, true)
    RETURNING id INTO v_scenario_id;
  ELSE
    SELECT id INTO v_scenario_id
    FROM public.scenarios
    WHERE id = p_scenario_id
    FOR UPDATE;

    IF v_scenario_id IS NULL THEN
      RAISE EXCEPTION 'سناریوی انتخاب‌شده پیدا نشد.';
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.scenarios
      WHERE lower(btrim(name)) = lower(v_name)
        AND id <> v_scenario_id
    ) THEN
      RAISE EXCEPTION 'سناریوی دیگری با این نام وجود دارد.';
    END IF;

    UPDATE public.scenarios
    SET name = v_name, is_active = true
    WHERE id = v_scenario_id;
  END IF;

  FOR v_role IN SELECT value FROM jsonb_array_elements(p_roles)
  LOOP
    v_role_name := btrim(v_role->>'name');
    v_faction := btrim(v_role->>'side');
    v_role_count := (v_role->>'count')::integer;

    UPDATE public.scenario_roles
    SET faction = v_faction,
        role_count = v_role_count,
        is_active = true
    WHERE scenario_id = v_scenario_id
      AND role_name = v_role_name;

    IF NOT FOUND THEN
      INSERT INTO public.scenario_roles
        (scenario_id, role_name, faction, description, is_active, role_count)
      VALUES
        (v_scenario_id, v_role_name, v_faction, NULL, true, v_role_count);
    END IF;
  END LOOP;

  DELETE FROM public.scenario_roles sr
  WHERE sr.scenario_id = v_scenario_id
    AND NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_roles) AS item
      WHERE btrim(item->>'name') = sr.role_name
    );

  RETURN v_scenario_id;
END;
$$;

REVOKE ALL ON FUNCTION public.save_managed_scenario(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_managed_scenario(uuid, text, jsonb) TO authenticated;
