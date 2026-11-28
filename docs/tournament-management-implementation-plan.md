# APEX ARENA — Tournament Management Implementation Plan

Target branch: `feature/apex-pages-refactor`

## Safety boundaries
- Never modify `main` or deploy Production as part of this work.
- Keep the existing judge-management and scoring workflows intact.
- Do not execute SQL or apply migrations from this repository change.
- Any database migration must be reviewed by the user and run only after separate explicit approval.
- No service-role key or other secret belongs in browser code.

## Existing structures to reuse
- `tournaments` and `tournament_registration_settings`: tournament identity and registration capacity.
- `tournament_stages`: ordered, manager-configurable stages; retain its `(tournament_id, stage_number)` uniqueness.
- `tournament_groups`: groups belonging to a stage.
- `matches` and `match_players`: games and their participants.
- `tournament_rule_versions`: immutable/versioned tournament rules using the existing JSONB fields (`group_settings`, `stage_settings`, `scoring_settings`, `advancement_rules`, `tie_break_rules`, `additional_rules`).
- `scenarios` and `scenario_roles`: existing scenario catalogue; do not replace or reseed the four existing scenarios.
- Existing `judge_assignments`, `tournament_judges`, `score_submissions`, `score_items`, and current judge RPCs remain the source of truth for current judging.

## Functional scope

### Tournament configuration
- Create and edit tournaments, subject to manager authorization and unique slugs.
- Configure registration capacity and registration state using the existing settings table.
- Add, rename, reorder, disable, and (only when safe) remove stages.
- Stage presets are optional: مقدماتی، یک‌چهارم نهایی، نیمه‌نهایی، فینال، رتبه‌بندی. Managers may use any subset, add custom stages, and choose the order.
- Configure groups per stage, players per group, games per group, special groups, advancement and elimination counts, and tie-break rules.
- Generate groups/matches only after the manager reviews the proposed structure; never silently overwrite games or participants.

### Scenarios and roles
- Preserve the four existing scenarios: بازپرس، مذاکره، نماینده، کاپو.
- Existing query result confirms one active شهروند ساده / شهروند row in each scenario. Current counts: بازپرس=1, مذاکره=1, نماینده=2, کاپو=2. The proposed data correction changes only بازپرس and مذاکره to 2.
- Managers can add/edit/disable scenarios and roles. Historical match snapshots must remain unchanged when catalogue entries are later edited.
- Before any role deletion/merge, inspect references and historical usage. No duplicate-role deletion is included in the initial data correction.

### Judge delegation and result workflow
- Keep judge appointment and match assignment integrated with `judge-management.html`.
- Add independent, revocable permissions scoped to tournament, stage, or match.
- Separate permission to submit a result from permission to approve it. Approval remains manager-only by default.
- Record submitter, approver, timestamps, and changes in an audit trail.
- Approved/locked results cannot be edited without a separately granted correction permission.
- Every SECURITY DEFINER RPC must validate the caller, active judge status, assignment, scope, and permission inside the database function. Hiding UI controls is not authorization.

## Delivery sequence
1. Confirm the current branch files and existing database definitions; avoid repeating already completed read-only checks.
2. Prepare a reviewed SQL migration draft: scoped judge grants, result/audit workflow, safe catalogue-count correction, and manager-only RPCs for configuration.
3. Build the admin UI around those RPC contracts with real forms, validation, save/error states, and safe confirmation for destructive actions.
4. Preserve current judge/scoring screens and connect tournament setup to the existing match/judge records.
5. Run static checks and review the diff. Runtime/Preview verification is reported only after it is actually performed.
6. Present the complete migration SQL and change summary. Do not execute the migration until the user explicitly approves that exact SQL in a separate message.

## Open implementation safeguards
- Stage reordering must avoid transient collisions on `UNIQUE(tournament_id, stage_number)`, for example through a transactional two-pass reorder.
- Existing matches and match-player assignments must not be deleted as a side effect of editing a stage.
- Rule versions and match snapshots must be retained for historical reproducibility.
- Tournament deletion, stage deletion, role deletion, and result correction need explicit dependency checks and confirmation.
- No new scenarios or roles are seeded. Only the two confirmed role_count values are candidates for correction.
