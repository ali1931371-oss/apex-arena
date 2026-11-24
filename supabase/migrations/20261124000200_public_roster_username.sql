-- Public tournament roster: show only the username supplied during registration and player code.
BEGIN;

CREATE OR REPLACE FUNCTION public.get_tournament_public_members(p_tournament_id uuid)
RETURNS TABLE (username text, player_code text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    COALESCE(
      NULLIF(btrim(r.username), ''),
      NULLIF(btrim(pr.username), ''),
      'بازیکن'
    ) AS username,
    pl.player_code
  FROM public.tournament_memberships tm
  JOIN public.tournaments t ON t.id = tm.tournament_id
  JOIN public.players pl ON pl.id = tm.player_id
  LEFT JOIN public.profiles pr ON pr.id = tm.user_id
  LEFT JOIN LATERAL (
    SELECT rr.username
    FROM public.tournament_registration_requests rr
    WHERE rr.tournament_id = tm.tournament_id
      AND rr.user_id = tm.user_id
    ORDER BY rr.reviewed_at DESC NULLS LAST, rr.created_at DESC
    LIMIT 1
  ) r ON true
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
  ORDER BY username, pl.player_code;
$$;

REVOKE ALL ON FUNCTION public.get_tournament_public_members(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_tournament_public_members(uuid) TO anon, authenticated;

COMMIT;
