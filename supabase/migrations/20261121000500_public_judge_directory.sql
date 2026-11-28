-- APEX ARENA: public directory of active tournament judges.
-- Exposes only judge display names and active tournament names; no emails or account IDs.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_public_judge_directory()
RETURNS TABLE (
  judge_name text,
  tournaments jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    COALESCE(NULLIF(btrim(p.display_name), ''), 'داور') AS judge_name,
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'tournament_id', tj.tournament_id,
          'tournament_name', t.name
        )
        ORDER BY t.name
      ),
      '[]'::jsonb
    ) AS tournaments
  FROM public.tournament_judges AS tj
  JOIN public.tournaments AS t ON t.id = tj.tournament_id
  JOIN public.profiles AS p ON p.id = tj.judge_id
  WHERE tj.is_active = true
  GROUP BY p.id, p.display_name
  ORDER BY p.display_name;
$$;

REVOKE ALL ON FUNCTION public.get_public_judge_directory() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_judge_directory() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
