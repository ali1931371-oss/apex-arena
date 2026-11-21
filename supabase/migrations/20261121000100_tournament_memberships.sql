-- APEX ARENA: tournament member roster, removal and disciplinary expulsion.
-- Adds a tournament-scoped membership ledger. Does not delete player accounts,
-- profiles, historical scores, completed matches or tournament records.

BEGIN;

CREATE TABLE IF NOT EXISTS public.tournament_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','removed','expelled')),
  joined_at timestamptz NOT NULL DEFAULT now(),
  removed_at timestamptz,
  removed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  removed_reason text,
  expelled_at timestamptz,
  expelled_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  expelled_reason text,
  UNIQUE (tournament_id, player_id),
  UNIQUE (tournament_id, user_id)
);

CREATE INDEX IF NOT EXISTS tournament_memberships_tournament_status_idx
  ON public.tournament_memberships (tournament_id, status);

ALTER TABLE public.tournament_memberships ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tournament_memberships FROM PUBLIC, anon, authenticated;

-- Backfill existing approved registrations. Active judges remain in the ledger,
-- but are omitted from the player roster until restored as players.
INSERT INTO public.tournament_memberships (tournament_id, player_id, user_id, status)
SELECT r.tournament_id, pl.id, r.user_id, 'active'
FROM public.tournament_registration_requests r
JOIN public.players pl ON pl.user_id = r.user_id
JOIN public.profiles pr ON pr.id = r.user_id AND pr.role = 'player'
WHERE r.status = 'approved'
ON CONFLICT (tournament_id, player_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.sync_tournament_membership_after_approval()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_player_id uuid;
BEGIN
  IF NEW.status = 'approved' AND OLD.status IS DISTINCT FROM NEW.status THEN
    SELECT pl.id INTO v_player_id
    FROM public.players pl
    JOIN public.profiles pr ON pr.id = pl.user_id
    WHERE pl.user_id = NEW.user_id AND pr.role = 'player'
    LIMIT 1;

    IF v_player_id IS NOT NULL THEN
      INSERT INTO public.tournament_memberships (tournament_id, player_id, user_id, status)
      VALUES (NEW.tournament_id, v_player_id, NEW.user_id, 'active')
      ON CONFLICT (tournament_id, player_id) DO UPDATE
      SET status = 'active',
          joined_at = now(),
          removed_at = NULL,
          removed_by = NULL,
          removed_reason = NULL,
          expelled_at = NULL,
          expelled_by = NULL,
          expelled_reason = NULL;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_tournament_membership_after_approval
  ON public.tournament_registration_requests;
CREATE TRIGGER sync_tournament_membership_after_approval
AFTER UPDATE OF status ON public.tournament_registration_requests
FOR EACH ROW
EXECUTE FUNCTION public.sync_tournament_membership_after_approval();

CREATE OR REPLACE FUNCTION public.get_tournament_public_members(p_tournament_id uuid)
RETURNS TABLE (display_name text, player_code text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pl.display_name, pl.player_code
  FROM public.tournament_memberships tm
  JOIN public.tournaments t ON t.id = tm.tournament_id
  JOIN public.players pl ON pl.id = tm.player_id
  WHERE tm.tournament_id = p_tournament_id
    AND tm.status = 'active'
    AND t.status IN ('registration','active','completed')
    AND NOT EXISTS (
      SELECT 1 FROM public.tournament_judges tj
      WHERE tj.tournament_id = tm.tournament_id
        AND tj.judge_id = tm.user_id
        AND tj.is_active = true
        AND tj.is_player_restored = false
    )
  ORDER BY pl.display_name, pl.player_code;
$$;

CREATE OR REPLACE FUNCTION public.get_tournament_manager_members(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'دسترسی مدیر یا مسئول مسابقه لازم است.';
  END IF;

  SELECT jsonb_build_object(
    'tournament_status', t.status,
    'members', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'membership_id', tm.id,
          'player_id', pl.id,
          'membership_status', tm.status,
          'display_name', pl.display_name,
          'player_code', pl.player_code,
          'audio_player_id', COALESCE(r.audio_player_id, pl.audio_player_id),
          'phone', COALESCE(r.phone, pr.phone),
          'username', COALESCE(r.username, pr.username),
          'removed_at', tm.removed_at,
          'removed_reason', tm.removed_reason,
          'expelled_at', tm.expelled_at,
          'expelled_reason', tm.expelled_reason
        ) ORDER BY pl.display_name
      )
      FROM public.tournament_memberships tm
      JOIN public.players pl ON pl.id = tm.player_id
      LEFT JOIN public.profiles pr ON pr.id = tm.user_id
      LEFT JOIN LATERAL (
        SELECT rr.audio_player_id, rr.phone, rr.username
        FROM public.tournament_registration_requests rr
        WHERE rr.tournament_id = tm.tournament_id AND rr.user_id = tm.user_id
        ORDER BY rr.reviewed_at DESC NULLS LAST, rr.created_at DESC
        LIMIT 1
      ) r ON true
      WHERE tm.tournament_id = t.id
        AND (
          tm.status <> 'active'
          OR NOT EXISTS (
            SELECT 1 FROM public.tournament_judges tj
            WHERE tj.tournament_id = tm.tournament_id
              AND tj.judge_id = tm.user_id
              AND tj.is_active = true
              AND tj.is_player_restored = false
          )
        )
    ), '[]'::jsonb)
  ) INTO v_result
  FROM public.tournaments t
  WHERE t.id = p_tournament_id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'تورنمنت موردنظر پیدا نشد.';
  END IF;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.remove_tournament_member(
  p_membership_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tournament_id uuid;
  v_player_id uuid;
  v_user_id uuid;
  v_status text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'دسترسی مدیر یا مسئول مسابقه لازم است.';
  END IF;

  SELECT tm.tournament_id, tm.player_id, tm.user_id, t.status
    INTO v_tournament_id, v_player_id, v_user_id, v_status
  FROM public.tournament_memberships tm
  JOIN public.tournaments t ON t.id = tm.tournament_id
  WHERE tm.id = p_membership_id AND tm.status = 'active'
  FOR UPDATE OF tm, t;

  IF NOT FOUND THEN RAISE EXCEPTION 'عضویت فعال پیدا نشد.'; END IF;
  IF v_status NOT IN ('draft','registration') THEN
    RAISE EXCEPTION 'حذف عضویت فقط پیش از شروع تورنمنت امکان‌پذیر است.';
  END IF;

  UPDATE public.tournament_memberships
  SET status = 'removed',
      removed_at = now(),
      removed_by = auth.uid(),
      removed_reason = NULLIF(btrim(COALESCE(p_reason,'')), '')
  WHERE id = p_membership_id;

  DELETE FROM public.match_players mp
  USING public.matches m
  WHERE mp.match_id = m.id
    AND mp.player_id = v_player_id
    AND m.tournament_id = v_tournament_id
    AND m.status = 'scheduled';

  UPDATE public.tournament_registration_requests
  SET status = 'cancelled'
  WHERE tournament_id = v_tournament_id
    AND user_id = v_user_id
    AND status = 'approved';

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.expel_tournament_member(
  p_membership_id uuid,
  p_reason text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tournament_id uuid;
  v_player_id uuid;
  v_status text;
  v_reason text := btrim(COALESCE(p_reason,''));
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'دسترسی مدیر یا مسئول مسابقه لازم است.';
  END IF;
  IF v_reason = '' THEN RAISE EXCEPTION 'ثبت دلیل اخراج الزامی است.'; END IF;
  IF length(v_reason) > 1000 THEN RAISE EXCEPTION 'دلیل اخراج بیش از حد طولانی است.'; END IF;

  SELECT tm.tournament_id, tm.player_id, t.status
    INTO v_tournament_id, v_player_id, v_status
  FROM public.tournament_memberships tm
  JOIN public.tournaments t ON t.id = tm.tournament_id
  WHERE tm.id = p_membership_id AND tm.status = 'active'
  FOR UPDATE OF tm, t;

  IF NOT FOUND THEN RAISE EXCEPTION 'عضویت فعال پیدا نشد.'; END IF;
  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'اخراج انضباطی فقط هنگام برگزاری تورنمنت امکان‌پذیر است.';
  END IF;

  UPDATE public.tournament_memberships
  SET status = 'expelled',
      expelled_at = now(),
      expelled_by = auth.uid(),
      expelled_reason = v_reason
  WHERE id = p_membership_id;

  -- Remove only future scheduled participation. Historical/live results remain.
  DELETE FROM public.match_players mp
  USING public.matches m
  WHERE mp.match_id = m.id
    AND mp.player_id = v_player_id
    AND m.tournament_id = v_tournament_id
    AND m.status = 'scheduled';

  RETURN true;
END;
$$;

-- Prevent removed or expelled players from being added to future matches.
CREATE OR REPLACE FUNCTION public.prevent_nonmember_as_match_player()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tournament_id uuid;
  v_user_id uuid;
BEGIN
  SELECT m.tournament_id, pl.user_id
    INTO v_tournament_id, v_user_id
  FROM public.matches m
  JOIN public.players pl ON pl.id = NEW.player_id
  WHERE m.id = NEW.match_id;

  IF v_tournament_id IS NULL THEN
    RAISE EXCEPTION 'مسابقه یا بازیکن معتبر نیست.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.tournament_memberships tm
    WHERE tm.tournament_id = v_tournament_id
      AND tm.player_id = NEW.player_id
      AND tm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'این بازیکن عضو فعال این تورنمنت نیست.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.tournament_judges tj
    WHERE tj.tournament_id = v_tournament_id
      AND tj.judge_id = v_user_id
      AND tj.is_active = true
      AND tj.is_player_restored = false
  ) THEN
    RAISE EXCEPTION 'داور فعال این تورنمنت نمی‌تواند شرکت‌کننده مسابقه باشد.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prevent_nonmember_as_match_player
  ON public.match_players;
CREATE TRIGGER prevent_nonmember_as_match_player
BEFORE INSERT OR UPDATE OF match_id, player_id ON public.match_players
FOR EACH ROW
EXECUTE FUNCTION public.prevent_nonmember_as_match_player();

REVOKE ALL ON FUNCTION public.sync_tournament_membership_after_approval() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_tournament_public_members(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_tournament_manager_members(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.remove_tournament_member(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.expel_tournament_member(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.prevent_nonmember_as_match_player() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_tournament_public_members(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_tournament_manager_members(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_tournament_member(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.expel_tournament_member(uuid, text) TO authenticated;

COMMIT;
