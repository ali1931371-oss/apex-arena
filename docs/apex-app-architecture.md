# APEX ARENA App — Architecture

## Product decisions
- Platforms: Android, iOS, Web, Windows, macOS (Flutter targets; each target requires platform-specific QA).
- Modes: audio and video rooms.
- Theme: system / light / dark (user-selectable).
- Host: a player in the room, with server-enforced permissions.
- Room capacity: configurable from 6 to 20 seats.
- First milestone: real audio/video room, tested across at least two devices.

## System boundaries
1. Flutter client: presentation, device permissions, LiveKit room connection, user interactions.
2. APEX backend: authentication verification, room membership, seat allocation, host permissions, game state and authoritative actions.
3. LiveKit: media transport only. It does not decide game rules or reveal roles.
4. Supabase: identity and persistent application data. Existing tournament tables remain untouched until a reviewed integration migration is approved.

## Security invariants
- Never ship Supabase service-role keys or LiveKit API secrets in a client.
- Backend issues short-lived LiveKit access tokens after verifying the authenticated user and room membership.
- Private roles and night actions are server-only; clients receive only data authorized for that player.
- Votes are not disclosed before the configured reveal point.
- Host permissions are explicit server-side capabilities, not client-side UI flags.
- All schema changes for the app use the `app_` prefix and separate migrations.
- Do not modify production or the existing main branch as part of app development.

## Initial delivery sequence
1. Flutter shell and adaptive theme.
2. Supabase Auth integration using public client configuration only.
3. Room creation, joining, seat allocation and reconnect state.
4. LiveKit audio/video with backend-issued tokens.
5. Host controls and server-authoritative game engine.
6. Match history, subscriptions and tournament integration.

## First acceptance test
Two authenticated users on different devices can join the same private room, exchange audio, enable/disable camera, disconnect and reconnect without losing their room membership. This test must pass before implementing full Mafia rules.

## Deployment
The app is developed on `feature/apex-app-foundation`. Production branch and existing production deployment must remain unchanged. Preview deployment is for verification only.
