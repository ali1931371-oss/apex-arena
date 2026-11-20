-- APEX ARENA: safely delete one tournament and only its dependent data.
-- PREPARED ONLY. Do not run until reviewed and explicitly approved.
-- This migration does not execute a tournament deletion by itself.

CREATE OR REPLACE FUNCTION public.log_score_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_old jsonb;
  v_new jsonb;
  v_id uuid;
  v_action text;
BEGIN
  -- Suppress audit rows only inside the authorized tournament-delete transaction.
  IF current_setting('app.suppress_audit', true) = 'on' THEN
    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_new := to_jsonb(NEW);
    v_id := NEW.id;
    v_action := 'INSERT';
  ELSIF TG_OP = 'UPDATE' THEN
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
    v_id := NEW.id;
    v_action := 'UPDATE';
  ELSIF TG_OP = 'DELETE' THEN
    v_old := to_jsonb(OLD);
    v_id := OLD.id;
    v_action := 'DELETE';
  END IF;

  INSERT INTO public.audit_logs (
    actor_id, entity_type, entity_id, action, old_data, new_data
  )
  VALUES (
    (SELECT auth.uid()), TG_TABLE_NAME, v_id, v_action, v_old, v_new
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$function$;

-- Published rule versions remain protected in normal use.
-- The only exception is a DELETE for the exact tournament being deleted,
-- and only when the caller is an authenticated APEX admin.
CREATE OR REPLACE FUNCTION public.prevent_published_rule_version_changes()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
BEGIN
  IF OLD.version_status = 'published' THEN
    IF NOT (
      TG_OP = 'DELETE'
      AND public.is_apex_admin()
      AND current_setting('app.tournament_delete_id', true) = OLD.tournament_id::text
    ) THEN
      RAISE EXCEPTION 'نسخه منتشرشده قوانین قابل ویرایش یا حذف نیست؛ نسخه جدید ایجاد کنید.';
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_managed_tournament(p_tournament_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_locked_tournament_id uuid;
  v_match_ids uuid[] := ARRAY[]::uuid[];
  v_stage_ids uuid[] := ARRAY[]::uuid[];
  v_group_ids uuid[] := ARRAY[]::uuid[];
  v_criterion_ids uuid[] := ARRAY[]::uuid[];
  v_submission_ids uuid[] := ARRAY[]::uuid[];
  v_assignment_ids uuid[] := ARRAY[]::uuid[];
  v_adjustment_ids uuid[] := ARRAY[]::uuid[];
  v_score_item_ids uuid[] := ARRAY[]::uuid[];
  v_judge_ids uuid[] := ARRAY[]::uuid[];
BEGIN
  -- This RPC is intentionally stricter than tournament creation/management.
  IF auth.uid() IS NULL OR NOT public.is_apex_admin() THEN
    RAISE EXCEPTION 'فقط مدیر اصلی (admin) مجاز به حذف کامل تورنمنت است.'
      USING ERRCODE = '42501';
  END IF;

  IF p_tournament_id IS NULL THEN
    RAISE EXCEPTION 'شناسه تورنمنت مشخص نشده است.';
  END IF;

  -- Lock and verify exactly one target tournament before collecting descendants.
  SELECT t.id
    INTO v_locked_tournament_id
  FROM public.tournaments AS t
  WHERE t.id = p_tournament_id
  FOR UPDATE;

  IF v_locked_tournament_id IS NULL THEN
    RAISE EXCEPTION 'تورنمنت موردنظر پیدا نشد.';
  END IF;

  SELECT COALESCE(array_agg(m.id), ARRAY[]::uuid[])
    INTO v_match_ids
  FROM public.matches AS m
  WHERE m.tournament_id = p_tournament_id;

  SELECT COALESCE(array_agg(st.id), ARRAY[]::uuid[])
    INTO v_stage_ids
  FROM public.tournament_stages AS st
  WHERE st.tournament_id = p_tournament_id;

  SELECT COALESCE(array_agg(g.id), ARRAY[]::uuid[])
    INTO v_group_ids
  FROM public.tournament_groups AS g
  WHERE g.stage_id = ANY(v_stage_ids);

  SELECT COALESCE(array_agg(c.id), ARRAY[]::uuid[])
    INTO v_criterion_ids
  FROM public.tournament_criteria AS c
  WHERE c.tournament_id = p_tournament_id;

  SELECT COALESCE(array_agg(ss.id), ARRAY[]::uuid[])
    INTO v_submission_ids
  FROM public.score_submissions AS ss
  WHERE ss.match_id = ANY(v_match_ids);

  SELECT COALESCE(array_agg(ja.id), ARRAY[]::uuid[])
    INTO v_assignment_ids
  FROM public.judge_assignments AS ja
  WHERE ja.match_id = ANY(v_match_ids);

  SELECT COALESCE(array_agg(sa.id), ARRAY[]::uuid[])
    INTO v_adjustment_ids
  FROM public.score_adjustments AS sa
  WHERE sa.match_id = ANY(v_match_ids);

  SELECT COALESCE(array_agg(si.id), ARRAY[]::uuid[])
    INTO v_score_item_ids
  FROM public.score_items AS si
  WHERE si.submission_id = ANY(v_submission_ids)
     OR si.criterion_id = ANY(v_criterion_ids);

  SELECT COALESCE(array_agg(tj.id), ARRAY[]::uuid[])
    INTO v_judge_ids
  FROM public.tournament_judges AS tj
  WHERE tj.tournament_id = p_tournament_id;

  -- Transaction-local flags. They automatically expire at transaction end.
  PERFORM set_config('app.suppress_audit', 'on', true);
  PERFORM set_config('app.tournament_delete_id', p_tournament_id::text, true);

  -- Remove only audit entries whose entity IDs were collected from this tournament.
  -- Also cover tournament_judges logs whose JSON stores tournament_id.
  DELETE FROM public.audit_logs AS al
  WHERE
    (al.entity_type = 'judge_assignments' AND al.entity_id = ANY(v_assignment_ids))
    OR (al.entity_type = 'score_adjustments' AND al.entity_id = ANY(v_adjustment_ids))
    OR (al.entity_type = 'score_items' AND al.entity_id = ANY(v_score_item_ids))
    OR (al.entity_type = 'score_submissions' AND al.entity_id = ANY(v_submission_ids))
    OR (
      al.entity_type = 'tournament_judges'
      AND (
        al.entity_id = ANY(v_judge_ids)
        OR al.old_data ->> 'tournament_id' = p_tournament_id::text
        OR al.new_data ->> 'tournament_id' = p_tournament_id::text
      )
    );

  -- Child-first deletion. Shared players, profiles, auth users and scenarios are never deleted.
  DELETE FROM public.score_items AS si
  WHERE si.submission_id = ANY(v_submission_ids)
     OR si.criterion_id = ANY(v_criterion_ids);

  DELETE FROM public.auto_events AS ae
  WHERE ae.match_id = ANY(v_match_ids);

  DELETE FROM public.judge_assignments AS ja
  WHERE ja.match_id = ANY(v_match_ids);

  DELETE FROM public.score_adjustments AS sa
  WHERE sa.match_id = ANY(v_match_ids);

  DELETE FROM public.match_players AS mp
  WHERE mp.match_id = ANY(v_match_ids);
  -- match_player_judging_details is removed by its declared ON DELETE CASCADE
  -- from match_players; its rows are scoped by those exact match/player pairs.

  DELETE FROM public.score_submissions AS ss
  WHERE ss.id = ANY(v_submission_ids);

  DELETE FROM public.matches AS m
  WHERE m.id = ANY(v_match_ids);

  DELETE FROM public.tournament_groups AS g
  WHERE g.id = ANY(v_group_ids);

  DELETE FROM public.tournament_stages AS st
  WHERE st.id = ANY(v_stage_ids);

  DELETE FROM public.tournament_criteria AS c
  WHERE c.id = ANY(v_criterion_ids);

  DELETE FROM public.tournament_registration_requests AS rr
  WHERE rr.tournament_id = p_tournament_id;

  DELETE FROM public.tournament_registration_settings AS rs
  WHERE rs.tournament_id = p_tournament_id;

  DELETE FROM public.tournament_rule_versions AS rv
  WHERE rv.tournament_id = p_tournament_id;

  -- Delete only tournament-to-scenario links, never the shared scenarios.
  DELETE FROM public.tournament_scenarios AS ts
  WHERE ts.tournament_id = p_tournament_id;

  DELETE FROM public.tournament_judges AS tj
  WHERE tj.tournament_id = p_tournament_id;

  DELETE FROM public.tournaments AS t
  WHERE t.id = p_tournament_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_managed_tournament(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_managed_tournament(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_managed_tournament(uuid) TO authenticated;

COMMENT ON FUNCTION public.delete_managed_tournament(uuid) IS
'Deletes one tournament and its dependent rows; callable only by APEX admin. Prepared for reviewed deployment.';
