-- APEX ARENA: prevent duplicate registration requests for the same player in the same tournament.
-- Prepared only. Review and run manually in Supabase SQL Editor after checking existing duplicates.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.tournament_registration_requests
    GROUP BY tournament_id, user_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Duplicate registration requests already exist for a player in a tournament. Review those rows before creating the unique index.';
  END IF;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_registration_requests_tournament_user
ON public.tournament_registration_requests (tournament_id, user_id);
