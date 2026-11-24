# APEX ARENA Backend

The first backend release will be a modular TypeScript service. Keep room authorization, host permissions, room state and the authoritative game engine on the server.

## Modules
- auth: validate Supabase access tokens.
- rooms: create/join/leave rooms, reserve seats (6–20), host transfer and reconnect.
- media: issue short-lived LiveKit participant tokens after membership checks.
- game: authoritative phase transitions, role assignment, votes and event log.
- integrations: future connection to existing APEX tournament and judging services.

## Rules
- LiveKit transports media; it is not the source of truth for game state.
- Never trust a client-supplied role, vote count, host flag or game phase.
- Never expose service-role or LiveKit API secrets to clients.
- Use app_-prefixed database tables and reviewed migrations.
- Do not modify existing tournament/judging tables in the initial app milestone.

The backend implementation starts after the Flutter shell and the room/auth contract are agreed.