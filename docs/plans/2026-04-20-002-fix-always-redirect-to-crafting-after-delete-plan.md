---
title: "fix: always redirect to crafting board after deleting a workflow session"
type: fix
status: active
date: 2026-04-20
---

# fix: always redirect to crafting board after deleting a workflow session

## Overview

Delete the referer-based post-delete redirect. After a user deletes a workflow session from the session detail page, always `push_navigate` to `/crafting` with a `"Session deleted"` flash, regardless of where the user came from. This also removes the router plug and LiveView helpers that capture and sanitize the `Referer` header for this route.

## Problem Frame

After clicking Delete on a session detail page, users currently see two different, inconsistent outcomes:

- **Symptom A:** flash reads `"Session not found"` and the user lands on `/crafting`.
- **Symptom B:** flash reads `"Session deleted"` and the user stays on what looks like the workflow runner page.

The user expects a single outcome: always redirect to `/crafting` with a `"Session deleted"` success flash. The inconsistency comes from the referer-based post-delete redirect introduced in the delete feature (see origin: `docs/plans/2026-04-17-002-feat-workflow-session-deletion-plan.md`). The referer can legitimately point to another `/sessions/:id-B` URL (e.g., the user navigated from session B to session A, then deleted A), and it can fall through the same-session guard under edge cases — producing either a bounce through the deleted session's URL (Symptom A) or a successful navigation to another session detail page that looks visually identical to the one just deleted (Symptom B).

Both symptoms disappear if the post-delete redirect is hard-coded to `/crafting`. That also matches the stated user expectation and mirrors how `handle_event("archive_session", ...)` already behaves.

## Requirements Trace

- R1. Deleting a workflow session from `/sessions/:id` always redirects to `/crafting`.
- R2. The flash after a successful delete always reads `"Session deleted"` (info level).
- R3. The destination is deterministic: it does not depend on the `Referer` header, prior navigation history, or session state (active, processing, archived, done).
- R4. `/sessions/:id` no longer captures the `Referer` header into the session cookie. The `session_detail` pipeline and `put_session_detail_referer/2` plug are removed.
- R5. Existing referer-behavior tests are removed; a single deterministic "delete redirects to /crafting with success flash" test remains, covering sessions in multiple states (active, archived, done).
- R6. The Gherkin feature file `features/session_deletion.feature` reflects the new deterministic behavior.

## Scope Boundaries

- No changes to `Destila.Workflows.delete_workflow_session/1` itself. Soft-delete semantics, `ServiceManager.cleanup/1`, `ClaudeSession.stop_for_workflow_session/1`, and the `:workflow_session_updated` broadcast stay exactly as they are.
- No changes to the Delete button's visibility rules, `data-confirm` copy, or placement.
- No changes to `get_workflow_session/1`'s not-found behavior in `WorkflowRunnerLive.mount/3` — the existing `"Session not found"` flash + `/crafting` redirect stays (it still applies when a user follows a stale deep link to an already-deleted session).
- No changes to archive/unarchive flows.
- No changes to the router's other pipelines or routes.
- No new PubSub events, no new schema fields.

## Context & Research

### Relevant Code and Patterns

- `lib/destila_web/live/workflow_runner_live.ex:119-130` — `handle_event("delete_session", ...)`. Currently navigates to `socket.assigns.post_delete_redirect`. This is the call site that changes to `~p"/crafting"`.
- `lib/destila_web/live/workflow_runner_live.ex:32-88` — `mount_session/3`. Line 36 computes `post_delete_redirect` from session cookie; line 61 assigns it. Both become dead code after the fix.
- `lib/destila_web/live/workflow_runner_live.ex:1453-1484` — `post_delete_redirect/2`, `local_path/1`, `local_uri?/1`, `points_to_session?/2`. All four helpers are deleted.
- `lib/destila_web/live/workflow_runner_live.ex:110-117` — existing `handle_event("archive_session", ...)`. Same one-liner shape the fixed delete handler mirrors: `push_navigate(to: ~p"/crafting")` with a success flash.
- `lib/destila_web/router.ex:15-29` — `pipeline :session_detail` and the private `put_session_detail_referer/2` plug. Removed.
- `lib/destila_web/router.ex:55-59` — `scope "/", DestilaWeb do pipe_through [:browser, :session_detail] live "/sessions/:id", WorkflowRunnerLive end`. The `/sessions/:id` route moves back into the main `:browser` scope alongside the other live routes.
- `test/destila_web/live/session_deletion_live_test.exs:53-183` — the entire `describe "delete from session detail"` block. The eight scenarios that depend on referer behavior are removed; a single deterministic scenario (plus the archived/processing/done visibility-and-delete scenarios already present) covers the new behavior. The `"Permanently delete..."` `data-confirm` assertion is preserved.
- `test/destila_web/live/session_deletion_live_test.exs:259-269` — `describe "deleted session direct navigation"`. Kept as-is; this still verifies the fallback 404 path for stale deep links.
- `features/session_deletion.feature` — the `Delete a session from the session detail page` scenario becomes a single deterministic one; no other scenarios reference referer behavior.

### Institutional Learnings

- From `docs/plans/2026-04-17-002-feat-workflow-session-deletion-plan.md` (the origin feature plan): the referer-based redirect was an explicit design choice motivated by a desire to return the user to where they came from without a JS hook. This plan documented the `points_to_session?` sanity check as the guard against redirecting back to the just-deleted page. The inconsistent-outcome reports are the signal that the guard's surface area is wider than the test suite covered, and that users did not value the referer return behavior enough to justify the complexity.
- The existing Archive handler (`handle_event("archive_session", ...)`) has always unconditionally navigated to `/crafting`. It has not produced the same inconsistent-outcome reports. That is the strongest local signal that an always-`/crafting` post-delete redirect is sufficient.
- From `docs/plans/2026-03-27-feat-archive-redirect-to-crafting-board-plan.md` (archive redirect): the same "always /crafting" choice was made for archive for the same reason — a single, predictable destination is better than a context-aware one for destructive or semi-destructive session actions.

### External References

None. The fix is a deletion of existing code and requires no external research.

## Key Technical Decisions

- **Remove the referer-based redirect entirely rather than patching the guard.** Every reported symptom traces back to the referer mechanism. Patching the guard with yet another corner case (e.g., "do not redirect to any `/sessions/:other-id`") would leave the mechanism in place and keep accumulating edge cases. The stated user expectation ("always redirected to the Crafting Board") is simpler than the current behavior, so the fix should delete the mechanism rather than repair it.
- **Mirror `archive_session`'s handler shape exactly.** `handle_event("delete_session", ...)` becomes `{:ok, _ws} = Workflows.delete_workflow_session(socket.assigns.workflow_session); {:noreply, socket |> put_flash(:info, "Session deleted") |> push_navigate(to: ~p"/crafting")}`. Keep the `{:error, _changeset}` branch that sets `"Could not delete session"` — that branch was added during the original P1/P2 hardening pass and is not part of the bug.
- **Drop the `session_detail` pipeline; keep `/sessions/:id` in the main `:browser` scope.** The referer plug is the only reason the pipeline existed. Once the plug is gone, there is nothing to pipe through. Moving the route back into the main scope keeps the router organized alongside the other `live` routes.
- **Do not clear `session_detail_referer` on deploy.** The session cookie is signed and short-lived relative to the key rotation window; any stale `session_detail_referer` entries become dead keys that nothing reads. No backwards-compat hack is needed.
- **Do not change the `"Session not found"` flash at mount.** That flash still applies when a user follows a stale deep link (e.g., from a bookmark, a Slack message, or a browser back-button into a deleted session's URL). The bug is specifically about the *immediately-after-delete* flow, not the generic "navigate to a deleted URL" flow.

## Open Questions

### Resolved During Planning

- **Should we keep the referer capture for some future use?** No. Nothing else reads `session_detail_referer` today, and YAGNI applies — a future feature that actually needs referer can re-add a scoped plug at that time.
- **Does the fix need any migration, backfill, or config change?** No. The session cookie may briefly contain stale `session_detail_referer` entries for active users. Those entries are unread after deploy and will expire naturally with the cookie.
- **Is there a timing/ordering bug in `delete_workflow_session/1` (two broadcasts during a delete) that also contributes?** Reviewed. `ServiceManager.cleanup/1` broadcasts `:workflow_session_updated` before the `deleted_at` update, which puts two messages in the LiveView's mailbox. When the LiveView's `handle_info` later calls `Workflows.get_workflow_session/1`, the row is already deleted (the second update runs synchronously before `handle_event` returns), so `get_workflow_session/1` returns `nil` and the handler is a no-op. This is benign and is **not** the source of the reported symptoms. No change required in this plan.
- **Does removing the referer plug break any other route?** No. Only `/sessions/:id` pipes through `:session_detail`. Grepping for `session_detail_referer` finds only the plug, the `post_delete_redirect/2` helper, and the deletion tests — all of which are removed in this plan.

### Deferred to Implementation

- **Exact neighboring-route placement.** The implementer chooses whether to place `live "/sessions/:id", WorkflowRunnerLive` directly above or directly below the existing `live "/sessions/:id/terminal", TerminalLive` line within the main `:browser` scope. The route must end up in the main scope block (see Unit 2 Approach) — the deferred choice is purely ordering among sibling `/sessions/...` routes.

## Implementation Units

- [ ] **Unit 1: Simplify the delete handler and drop `post_delete_redirect` from the LiveView**

**Goal:** Make `handle_event("delete_session", ...)` always navigate to `/crafting`. Remove the mount-time referer capture, the `post_delete_redirect` assign, and the four private helpers that existed solely to sanitize and gate the referer.

**Requirements:** R1, R2, R3

**Dependencies:** None

**Files:**
- Modify: `lib/destila_web/live/workflow_runner_live.ex`

**Approach:**
- In `handle_event("delete_session", _params, socket)` change the success branch's `push_navigate(to: socket.assigns.post_delete_redirect)` to `push_navigate(to: ~p"/crafting")`. Leave the `{:error, _changeset} -> put_flash(socket, :error, "Could not delete session")` branch untouched.
- In `mount_session/3` remove the line that computes `post_delete_redirect` and remove the `|> assign(:post_delete_redirect, post_delete_redirect)` line from the assign pipeline.
- Delete the four private helpers at the bottom of the module: `post_delete_redirect/2`, `local_path/1` (both clauses), `local_uri?/1` (both clauses), and `points_to_session?/2` (single clause).
- Leave the rest of `mount_session/3` (pubsub subscribes, session assigns, not-found flash branch) untouched. The not-found branch on mount still puts `"Session not found"` and navigates to `/crafting` — that is the correct behavior for stale deep links and is out of scope for this fix.
- Leave `handle_info({:workflow_session_updated, ...}, ...)` untouched.

**Patterns to follow:**
- `lib/destila_web/live/workflow_runner_live.ex:110-117` — `handle_event("archive_session", ...)` shape for the simplified delete handler.

**Test scenarios:**
- Happy path: clicking `#delete-btn` from an active session at `/sessions/:id` calls `Workflows.delete_workflow_session/1`, sets the `:info` flash to `"Session deleted"`, and `assert_redirect` returns `{"/crafting", %{"info" => "Session deleted"}}`.
- Happy path: clicking `#delete-btn` from an archived session at `/sessions/:id` redirects to `/crafting` with the success flash (this case previously only asserted button visibility).
- Happy path: clicking `#delete-btn` from a done session at `/sessions/:id` redirects to `/crafting` with the success flash.
- Happy path: clicking `#delete-btn` from a processing session at `/sessions/:id` redirects to `/crafting` with the success flash.
- Edge case: when the conn carries a `Referer: /sessions/:other-id` header, the redirect still targets `/crafting` (regression test locking in the fix; replaces the existing same-origin-absolute-URL test).
- Edge case: when the conn carries a `Referer: /crafting` header, the redirect still targets `/crafting` (regression test; replaces the existing referer-from-Referer test).
- Edge case: when the conn carries no `Referer` header, the redirect targets `/crafting` (this scenario already exists and keeps its assertion).
- Error path: when `Workflows.delete_workflow_session/1` returns `{:error, %Ecto.Changeset{}}`, the socket flashes `"Could not delete session"` and does **not** navigate. The changeset built inside `delete_workflow_session/1` (just `%{deleted_at: DateTime.utc_now()}`) has no natural validation failure path, so the only realistic way to exercise this branch is by stubbing `Destila.Workflows.delete_workflow_session/1` with Mimic. This requires two additions the implementer must make: (1) `Mimic.copy(Destila.Workflows)` in `test/test_helper.exs` alongside the existing `Mimic.copy(Destila.Deps)` and friends, and (2) `use Mimic` at the top of `session_deletion_live_test.exs`. If the implementer judges that the error branch's value does not justify the test_helper addition, it is acceptable to leave the branch uncovered and note the deferral in the PR description instead — the branch behavior is unchanged by this plan.

**Verification:**
- No reference to `post_delete_redirect`, `session_detail_referer`, `local_path`, `local_uri?`, or `points_to_session?` remains in `lib/destila_web/live/workflow_runner_live.ex`.
- `Workflows.delete_workflow_session/1` is still called from the delete handler and still produces soft-delete + broadcast behavior.
- The delete handler and archive handler are structurally parallel.

- [ ] **Unit 2: Remove the `:session_detail` router pipeline and plug**

**Goal:** Delete the only router machinery whose sole purpose was feeding `session_detail_referer` into the LiveView, and put `/sessions/:id` back into the main `:browser` scope.

**Requirements:** R4

**Dependencies:** Unit 1 (so nothing in the LiveView still reads the session cookie key)

**Files:**
- Modify: `lib/destila_web/router.ex`

**Approach:**
- Remove the `pipeline :session_detail do ... end` block.
- Remove the private `put_session_detail_referer/2` function.
- Remove the standalone `scope "/", DestilaWeb do pipe_through [:browser, :session_detail] ... end` block and place its single `live "/sessions/:id", WorkflowRunnerLive` line inside the existing main `scope "/", DestilaWeb do pipe_through :browser ... end` block, grouped with the other `/sessions/...` live routes (e.g., above or below `live "/sessions/:id/terminal", TerminalLive`).

**Patterns to follow:**
- `lib/destila_web/router.ex:37-53` — the main `scope "/", DestilaWeb` block for route placement.

**Test scenarios:**
- Test expectation: none at the router layer directly. Behavior is exercised by the LiveView test in Unit 1 and by a simple regression test in Unit 3 that mounts `/sessions/:id` with a `Referer` header set and asserts the session cookie does not contain `session_detail_referer` afterward (optional; if adding the assertion pulls in too much test scaffolding, the LiveView-level "redirects to /crafting regardless of referer" tests cover the observable behavior).

**Verification:**
- `mix compile` succeeds.
- Grep across `lib/` for `session_detail_referer` returns no matches.
- `/sessions/:id` still routes to `WorkflowRunnerLive` and still inherits the `:browser` pipeline (fetch_session, protect_from_forgery, etc.).

- [ ] **Unit 3: Prune and replace referer-dependent tests**

**Goal:** Remove the five tests in `session_deletion_live_test.exs` that assert referer-based redirect behavior, add the missing coverage for the simplified handler, and keep the unchanged-behavior tests as-is.

**Requirements:** R5

**Dependencies:** Unit 1

**Files:**
- Modify: `test/destila_web/live/session_deletion_live_test.exs`

**Approach:**
- Inside `describe "delete from session detail"`, delete these tests (all currently under `@tag feature: @feature, scenario: "Delete a session from the session detail page"`):
  - `"redirects to referer captured from the Referer header"` (lines 83-96)
  - `"falls back to /crafting when referer points back to same session"` (lines 98-115)
  - `"falls back to /crafting when referer points under same session path"` (lines 117-133)
  - `"falls back to /crafting when referer is a cross-origin absolute URL"` (lines 148-164)
  - `"redirects to referer path when referer is a same-origin absolute URL"` (lines 166-182)
- Keep and tighten:
  - `"redirects and flashes on delete"` (lines 54-68). Also assert the flash payload from `assert_redirect`'s second tuple element.
  - `"delete button has a data-confirm attribute"` (lines 70-81). No changes.
  - `"falls back to /crafting when no referer is present"` (lines 135-146). Rename to `"redirects to /crafting after deleting an active session"` since "falls back" no longer carries meaning.
- Add to the same describe block:
  - `"redirects to /crafting even when a Referer header is present"` — mount with `Plug.Conn.put_req_header(conn, "referer", "/sessions/\#{other_ws.id}")`, click `#delete-btn`, assert `{path, flash}` = `assert_redirect(view)`, `path == "/crafting"`, `flash["info"] == "Session deleted"`. The `other_ws` can be a second `create_session` in the test body.
  - `"redirects to /crafting after deleting an archived session"` — create, archive, mount, click `#delete-btn`, assert `{path, flash}` = `assert_redirect(view)`, `path == "/crafting"`, `flash["info"] == "Session deleted"`. The existing `"delete button renders for archived sessions"` test (lines 215-226) only asserts visibility; this adds the missing redirect assertion and carries `@tag scenario: "Delete an archived session"`.
  - `"redirects to /crafting after deleting a done session"` — same shape against a session with `done_at` set.
  - `"redirects to /crafting after deleting a processing session"` — same shape against a session with `status: :processing`.
- Leave `describe "cancel delete confirmation"` and `describe "delete button visibility"` untouched. `describe "deleted session direct navigation"` stays untouched — it still verifies the stale-deep-link path.
- Do not add tests at the router layer for the plug's absence; absence is verified by Unit 2's compile check and the LiveView tests' behavior.

**Patterns to follow:**
- `test/destila_web/live/session_deletion_live_test.exs:54-68` — existing `"redirects and flashes on delete"` for the canonical test shape.
- `test/destila_web/live/archived_sessions_live_test.exs` — archive + delete sequencing pattern if the implementer wants reference for the archived-session test.

**Test scenarios:**
- All test scenarios for this unit are the specific tests listed above; they are both the deliverable and the verification.

**Verification:**
- `mix test test/destila_web/live/session_deletion_live_test.exs` is green.
- No test in the file references the strings `"session_detail_referer"`, `"referer"` (header), or `put_req_header(..., "referer", ...)` — except the single regression test that confirms the `Referer` is ignored.
- `mix test --only feature:session_deletion` is green.

- [ ] **Unit 4: Update the Gherkin feature file**

**Goal:** Align `features/session_deletion.feature` with the new deterministic redirect behavior.

**Requirements:** R6

**Dependencies:** Units 1 and 3

**Files:**
- Modify: `features/session_deletion.feature`

**Approach:**
- Rewrite the `Scenario: Delete a session from the session detail page` body so the "Then" steps assert redirection to `/crafting` and a `"Session deleted"` success flash unconditionally.
- Remove any scenario or scenario step that references "returned to where they came from", "came from", or `Referer`.
- Add or tighten a scenario that covers archived-session deletion redirecting to `/crafting` if the existing file does not already cover it unambiguously (the existing `Scenario: Delete an archived session` likely covers visibility only — bring the redirect assertion into it).
- Verify every remaining scenario has at least one `@tag` reference from `session_deletion_live_test.exs` after Unit 3's edits.

**Patterns to follow:**
- `features/session_archiving.feature` — parallel archive flow, which already asserts unconditional crafting-board redirection.

**Test scenarios:**
- Test expectation: none — this is a documentation file. The linkage is verified by running `mix test --only feature:session_deletion` after Unit 3.

**Verification:**
- Running `mix test --only feature:session_deletion` matches every scenario in the feature file to at least one test.
- Grep across `features/session_deletion.feature` for `Referer`, `came from`, `referer` returns no matches.

- [ ] **Unit 5: Pre-commit hygiene**

**Goal:** Run the project's pre-commit checks and resolve any formatter, compiler, or test failures introduced by the removal.

**Requirements:** All

**Dependencies:** Units 1-4

**Files:** None (verification only)

**Approach:**
- Run `mix precommit` and address any pending issues (formatter, compiler warnings, credo, test failures, schema drift).

**Test scenarios:**
- Test expectation: none — verification-only step.

**Verification:**
- `mix precommit` exits 0.
- A manual UI walkthrough in `iex --sname debug --remsh destila@$(hostname -s)` followed by clicking Delete on (a) an active session reached from the crafting board, (b) an active session reached from another session's detail page, and (c) an archived session reached from the archived sessions page all produce the same outcome: redirect to `/crafting` with `"Session deleted"` flash.

## System-Wide Impact

- **Interaction graph:**
  - `WorkflowRunnerLive.handle_event("delete_session", ...)` — single call site changes; always navigates to `/crafting` now.
  - `WorkflowRunnerLive.mount/3` — no longer reads from the session cookie's `"session_detail_referer"` key.
  - `DestilaWeb.Router` — `:session_detail` pipeline and plug deleted; `/sessions/:id` moves to `:browser`-only.
  - No other LiveView reads `session_detail_referer` today (grepped), so there are no external consumers to coordinate.
- **Error propagation:** Unchanged. The `{:error, _changeset}` branch of `handle_event("delete_session", ...)` keeps its `"Could not delete session"` flash. `Workflows.delete_workflow_session/1` itself is untouched.
- **State lifecycle risks:**
  - Stale `session_detail_referer` entries may still live in users' session cookies post-deploy. Nothing reads them; they are harmless and expire with the cookie. No cookie invalidation or rotation is triggered by this fix.
  - The mount-time `"Session not found"` flash + `/crafting` redirect continues to handle navigation to already-deleted session URLs (stale links, back button). That path is unchanged.
- **API surface parity:** No external API changes. The internal LiveView surface shrinks by removing `post_delete_redirect/2`, `local_path/1`, `local_uri?/1`, and `points_to_session?/2`, and the internal router surface shrinks by removing `pipeline :session_detail` and `put_session_detail_referer/2`.
- **Integration coverage:** The LiveView tests in Unit 3 cover the delete flow end-to-end (including with a `Referer` header present to lock in the fix). Unit 5's manual walkthrough covers the real-browser behavior the unit tests cannot reproduce (full-page reload fallback when `live_session` is not configured).
- **Unchanged invariants:**
  - `Workflows.delete_workflow_session/1` behavior, including `ServiceManager.cleanup/1` and `ClaudeSession.stop_for_workflow_session/1` side effects and `:workflow_session_updated` broadcast.
  - `Workflows.get_workflow_session/1` not-found handling in `mount/3` (and the `"Session not found"` flash it produces for stale deep links).
  - Archive / unarchive flows.
  - Project-deletion guard (`count_by_project/1`) against soft-deleted sessions.
  - The Delete button's visibility, `data-confirm` copy, and DOM id.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A team member expected the referer-return behavior and relies on it in a workflow the PR author does not see. | The feature was recently added (April 17); the only consumer is the delete handler itself. The user's bug report explicitly asks for the always-`/crafting` behavior. Mention the change in the PR description so teammates have a chance to flag reliance. |
| Removing the `:session_detail` pipeline shifts the `/sessions/:id` route into `:browser`, changing the order plugs run in. | The `:session_detail` pipeline only added `put_session_detail_referer` after `:browser`. Removing it strictly reduces plug count; there is no ordering concern left. |
| A test outside `session_deletion_live_test.exs` implicitly relies on `session_detail_referer` being set. | Grep across `test/` for `session_detail_referer` before the PR lands. No hits today. If hits appear, treat them as part of Unit 3's scope. |
| The `{:error, _changeset}` branch of the delete handler is untested and could hide a regression. | Unit 3's error-path test either exercises this branch via a `:mimic` stub on `Workflows.delete_workflow_session/1` or explicitly notes the branch as deferred coverage if stubbing pulls in disproportionate complexity. Either outcome is acceptable for a fix PR; the branch behavior does not change in this plan. |

## Documentation / Operational Notes

- No documentation updates needed beyond the PR description. The session-deletion plan in `docs/plans/` stays as the historical record of how the feature shipped; this plan stands alongside it as the record of the revert.
- No rollout flag, no migration, no monitoring changes.
- After deploy, users with active sessions may carry a stale `session_detail_referer` session-cookie key until the cookie rotates. This is harmless.

## Sources & References

- **Origin defect report:** user prompt describing the two inconsistent post-delete outcomes.
- **Origin feature plan:** `docs/plans/2026-04-17-002-feat-workflow-session-deletion-plan.md` — introduced the referer-based redirect this fix removes.
- **Related code:** `lib/destila_web/live/workflow_runner_live.ex` — delete handler, mount, and the four private helpers being removed.
- **Related code:** `lib/destila_web/router.ex` — `:session_detail` pipeline and plug being removed.
- **Related code:** `lib/destila_web/live/workflow_runner_live.ex:110-117` — archive handler used as the structural template for the fixed delete handler.
- **Related plan (prior art):** `docs/plans/2026-03-27-feat-archive-redirect-to-crafting-board-plan.md` — establishes the "always-`/crafting`" precedent for session-level destructive actions.
- **Related feature file:** `features/session_deletion.feature` — updated in Unit 4 to match the new behavior.
- **Related test:** `test/destila_web/live/session_deletion_live_test.exs` — updated in Unit 3.
