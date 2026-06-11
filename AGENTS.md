# Hospex (repo: CorePMS)

Phoenix/Elixir hotel PMS. Open-source (MIT), AI-friendly, designed so other hotels can fork and customize. Greenfield, prototyped with Claude Code.

## Stack
Elixir 1.18 / Phoenix 1.7 / LiveView / PostgreSQL 16 / Oban / ex_json_schema / yaml_elixir

## Architecture
- **Git repos are the canonical source of truth** for property content (one public GitHub repo per property).
- **PostgreSQL is the operational cache** for bookings/stays/events/transactions — the live operational state staff add through the UI.
- **YAML files** under the configured property dir (default `examples/le_petit_madeleine/`, override via `PROPERTY_DIR` env) hold property/room-type/room/rate-plan/policy/content data, validated against JSON Schema in `priv/schemas/v{major}/{entity}.json` (draft-07).
- The calendar reads `room_groups` from YAML via `Hospex.Content.Property.room_groups/0`; bookings/stays/etc. from Postgres via `Hospex.Bookings`.

## Layout
- `lib/hospex/` — domain: `bookings` (Postgres), `accounts` (magic-link auth), `content` (YAML + booking drawer view data), `inventory`, `schema` (JSON Schema validator), `repo`, `mailer`.
- `lib/hospex_web/live/` — LiveViews: `calendar_live`, `bookings_live`, `inventory_live`, `dashboard_live`, `settings/{property,room_types,rooms}_live`.
- `lib/hospex_web/live/settings/shared.ex` — shared settings chrome (topbar parity, left rail, form components).
- `lib/hospex_web/user_auth.ex` — auth plugs + LiveView on_mount; `lib/hospex_web/live_params.ex` — safe parsing of client params (`safe_status/1`; `String.to_atom` on event params is banned).
- `assets/css/{app,calendar,dashboard,inventory,settings}.css` — design tokens live in `calendar.css :root`.
- `assets/js/app.js` — LiveView JS hooks (`CalendarGrid`, `CalendarSelect`, `SidebarScroll`, `QuickMenu`, `AtPoint`, `AutoDismiss`, `CalZoom`).
- `priv/schemas/v1/` — JSON Schemas (property, room_type, room, rate_plan, policy, content).
- `priv/repo/migrations/` — Ecto migrations.
- `examples/le_petit_madeleine/` — canonical example property's YAML files; default `PROPERTY_DIR`.

## Calendar LiveView
- ~1.9k lines `.ex` + ~1.9k lines `.heex`.
- Anchor + zoom model: `anchor` is leftmost visible date; `zoom_level` (1–5, `@zoom_levels`) sets `view_span` (7/14/21/30/45) AND cell size on both axes (`cell_w` × `cell_h`) — the toolbar's −/+ control replaces the old Week/2w/Month toggle, and the `CalZoom` hook persists the level in localStorage. Row heights flow from `--cell-h` (set inline on `.app`); `data-density` (normal/compact/tiny) gates pill-content CSS at small sizes. `derive_view/1` recomputes `dates`, `cell_w`, `cell_h`, `total_grid_w`, `today_col`, `visible_stays_flat`, `stays_by_room`, `room_lanes`, `stats` whenever anchor/zoom/filters change.
- Date picker (`@dp_open`, `@dp_month`): `open_dp` → `pick_date` (sets `anchor = picked - 3`) → `close_dp`. Outside-click dismissal via `phx-click-away` on the popover. **Don't add `onclick="event.stopPropagation()"` to LiveView popovers** — kills window-level `phx-click` delegation and silently drops events.
- Drag-select on empty cells creates `quick_create`; drag on pills resizes/moves stays (`CalendarSelect` hook).
- After drop, a confirmation popover (`drag-confirm`, z-index 81) sits over a scrim (80). The pending pill at the proposed position is `.booking.pending-confirm` (z-index 5) — keep it below modals.
- Lanes: greedy interval-coloring per room (`assign_lanes/1`); overbooked rows grow.
- Subscribes to PubSub topics: `"bookings"` (mutations from `Hospex.Bookings`) and `"content"` (YAML edits from Settings) — both trigger `derive_view`.
- **Booking URLs:** `/calendar?booking=ID` is the shareable address of an open drawer. `handle_params` is the source of truth (open/close follows the URL, back/forward works); selecting a booking `push_patch`es the param, closing patches it away. Out-of-window bookings re-anchor the calendar to their check-in. The bookings page deep-links rows here.
- **Drafts survive re-renders:** LiveView wipes typed-but-unsaved input in *unfocused* fields on any re-render. The notes textarea stages a draft via `phx-change="notes_change"` (fires on blur) rendered as `@notes_draft || saved`; `do_select_booking` distinguishes same-booking refreshes (PubSub, post-save) from switching bookings — refreshes preserve `notes_draft`, `block_edit`, `drawer_tab`, and `expanded_stays`. Any new in-drawer form must follow this pattern.
- **Drawer data is real:** `BookingDetails` no longer fabricates anything — pricing breakdown comes from `rate_night`/`cleaning_fee`/`tax_rate` columns, contact fields from the booking row ("—" when absent), payments exclusively from the `booking_transactions` ledger. Only avatar colors/initials are hash-derived. The one remaining fabricator is the History-tab `events_for` fallback for seeded bookings without stored events.

## Bookings persistence (Postgres)
- `Hospex.Bookings.Store` is a thin namespace over Repo. All mutations return updated maps in the shape the LiveView consumes; status/src/payment_collect are atoms in the map, strings in the DB.
- **Write path invariants** (don't regress these):
  - `Store.update_booking/2` is load → transform → persist under a `FOR UPDATE` row lock (prevents lost updates on `paid`/`total` under READ COMMITTED). It returns `{:ok, fresh}` / `{:error, :not_found | reason}`; transforms may return `{:error, reason}` to abort.
  - Every mutation + its audit event commit in ONE transaction via `Bookings.mutate_and_log/4` — a booking can't change without history recording it. Money mutations also insert the `BookingTransaction` ledger row in that transaction, so `paid` always equals the ledger sum (`apply_payment` delegates to `add_transaction`).
  - Payment status is derived, not stored ad hoc: every payment/refund/charge re-derives `:unpaid/:partial/:paid` from the balance (`derive_payment_status/3`), but never clobbers lifecycle statuses (`:in`, `:hold`, `:cancelled`, `:ota_collect`).
  - Refunds exceeding `paid` are rejected (`{:error, :refund_exceeds_paid}`); CHECK constraints back the money columns in the DB.
  - Stay `subtotal` semantics: `nil` = "no explicit per-stay split yet" (consumers fall back to even split of booking total); `0` = genuinely free. Never coalesce nil→0 — that's the bug that zeroed totals on drag.
  - `add_stay_to_booking` returns the real Postgres stay id (max id in the fresh snapshot under the row lock) — never fabricate ids.
- `Hospex.Bookings.BookingEvent` (audit log) and `BookingTransaction` (ledger) have `on_delete: :delete_all` FKs to `bookings`. Preloaded on every read, newest-first. `notes` is a column on bookings.
- Atom safety: every string→atom conversion goes through a whitelist with `String.to_existing_atom/1` + rescue + fallback. Block bookings use `src: "block"` (in the whitelist) — never `"—"`.

## Settings (YAML-backed)
- `/settings/property`, `/settings/room-types`, `/settings/rooms` edit YAML in the configured property dir.
- `Hospex.Content.Property` reads/writes YAML; every write validates against the JSON Schema via `Hospex.Schema.Validator` before touching disk.
- Round-trip preserves every field *value*, including ones the UI doesn't expose (amenities, photos, i18n other than `.en`, bed configurations, geo coords) — verified against all example files. Comments, key order, and block-scalar style are lost (accepted). No regression test guards this yet — see Known follow-ups.
- Writes are atomic (temp file + rename) and serialized per file; ids from client params are slug-validated before any disk access (path-traversal guard — keep `validate_id` on every new disk-touching entry point).
- On any successful write, broadcasts `{:content_changed, kind, id}` on the `"content"` PubSub topic so the calendar refreshes live.

## Auth (magic-link, passwordless)
- All app routes require login: `require_authenticated_user` plug + `live_session :staff` with `on_mount {HospexWeb.UserAuth, :ensure_authenticated}` (both layers required — plug guards HTTP, hook guards the websocket mount).
- `Hospex.Accounts` follows phx.gen.auth's token design: login tokens are emailed as `/login/t/:token`, stored **hashed**, valid 15 min, single-use; the link lands on a confirm page whose button POSTs (mail-scanner prefetch can't consume the token). Session tokens are DB-backed (14 days, revocable). 60s resend cooldown; the login form response never reveals whether an email is registered.
- No self-registration: users come from seeds (`ADMIN_EMAIL`, default `admin@example.com`) or `Hospex.Accounts.create_user/1` in IEx.
- Dev email lands in the local Swoosh mailbox at `/dev/mailbox`. Production must configure a real Swoosh adapter in runtime.exs (none configured yet).
- Logout: the `me-avatar` in every topbar is a `method="delete"` link to `/logout` (with `data-confirm`).

## Dev
```
mix setup           # deps + db create/migrate/seed + assets (first-time)
mix phx.server      # start dev server
mix test            # run tests
mix ecto.reset      # drop + create + migrate + seed
```

### Prerequisites
- **Elixir 1.18 / Node 22 / Erlang 28** — `.mise.toml` pins these; `mise install` from the repo root gets the whole toolchain.
- **PostgreSQL 14+ on `localhost:5432`** with a `postgres`/`postgres` superuser. `mix setup` fails on `ecto.create` otherwise.
  - `brew install postgresql@16 && brew services start postgresql@16 && createuser -s postgres`
  - Or [Postgres.app](https://postgresapp.com)
  - Or `docker run -d --name hospex-pg -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:16`

### Restart-required gotcha
If you change `config/config.exs`, the Phoenix code reloader returns a 500 with the message *"You must restart your server after changing configuration files"*. Restart `mix phx.server` — don't waste time chasing a phantom compile error.

### Asset watcher gotcha
The esbuild `--watch` watchers occasionally miss edits to `assets/js/app.js` / `assets/css/*.css` (seen twice: stale bundle served while the source had the change). If a JS hook or CSS rule "doesn't work", first `grep` the built bundle in `priv/static/assets/` for your change; rebuild manually with `mix assets.build` if it's missing.

### Browser verification
`.claude/launch.json` defines a `hospex` preview server config (Claude Preview drives a real browser against it). Login in dev: `admin@example.com` on `/login`, then grab the magic link from `/dev/mailbox`. Note: synthetic JS events (`new Event("input")` etc.) are not tracked by LiveView bindings — use native fills / `el.click()` and confirm events arrived via the server log before concluding something is broken.

### Known follow-ups
- **Make `MIX_ENV=prod` build.** Three blockers: no `config/prod.exs` (config import fails); the router's `if Application.compile_env(:hospex, :dev_routes)` block isn't DCE'd while `phoenix_live_dashboard` is `only: [:dev, :test]`; the committed LiveView `signing_salt` in `config.exs` is used in prod (move to runtime env, like `secret_key_base`). Production also needs a real Swoosh mail adapter in `runtime.exs` for login emails.
- **Inventory overrides are process-local.** `Hospex.Inventory.Store` is still an Agent — rate/min-stay/closure edits vanish on restart. Move to Postgres (the bookings layer shows the pattern).
- **Server-side availability validation.** Drag-drop / quick-create accept any room/dates/price from the client; overlaps become silent overbookings flagged after the fact. Validate on write; make true conflicts an explicit confirm.
- **Hot-path performance.** Calendar reads preload the ever-growing events/transactions on every load (split preloads: calendar needs only `:stays`); `Property.room_groups/0` re-parses every YAML file per interaction (cache in ETS/persistent_term, invalidate from the `"content"` PubSub topic); computed check-out fragments can't use indexes (generated `check_out` column).
- **DB-backed search + windowed bookings page.** Calendar search only matches the loaded window; `/bookings` loads all bookings and re-renders the whole table per keystroke (wants `stream` + DB-side filter/sort).
- **History tab fallback fabricates a timeline** (`BookingDetails.events_for`) for seeded bookings without stored events. Real bookings use the real audit log; backfill seeds and delete the generator.
- **No user management UI.** Adding staff = `Hospex.Accounts.create_user/1` in IEx or seeds. A `/settings/users` page is the natural next step.
- **YAML writer round-trip has no regression test.** The hand-rolled writer currently preserves every field *value* (verified against all example files — only comments/key order/scalar style are lost), but nothing guards that. Add a round-trip property test. Concurrent saves are serialized per file, but same-field edits are last-writer-wins (no version check).
- **Bed-configuration, amenities, photos editors** in Settings — preserved on round-trip but not editable in the UI. Bed configs are required by the room_type schema; new types currently get a hardcoded single `double` bed to satisfy `minItems: 1`.
- **Hidden coupling on room-type IDs.** Use `Map.get` with a fallback, not `Map.fetch!`, at any boundary that consumes IDs from YAML.
- **Oban workers** for `git_sync` (push YAML edits to property's GitHub repo) and `media_ingest` (photo uploads to S3) — queues are configured but no worker modules exist.
- **`bookings_live.ex` `handle_event/3` grouping warning.** Same fix pattern as the calendar refactor.
- **Pre-existing test failure:** `validator_test.exs:133` ("property — required fields, missing schema_version") fails on a clean tree — predates all recent work; every suite run shows "N tests, 1 failure" because of it.

## Conventions
- Money formatted via `format_money/1`; dates via `Calendar.strftime` or local helpers (`format_date_range`, `dow_abbr`, `month_abbr`).
- Status atoms: `:paid`, `:partial`, `:unpaid`, `:in`, `:hold`, `:cancelled`, `:ota_collect`.
- Server is the source of truth for popover/menu open state — keep DOM driven by assigns, not JS toggles.
- Design tokens live in `assets/css/calendar.css :root`. All new pages reuse them rather than inventing colors. The settings redesign followed this pattern — 0 inline styles in any settings page.
