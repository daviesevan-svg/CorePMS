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
- `lib/hospex/` — domain: `bookings` (Postgres), `content` (YAML + mock inventory/calendar), `inventory`, `schema` (JSON Schema validator), `repo`.
- `lib/hospex_web/live/` — LiveViews: `calendar_live`, `bookings_live`, `inventory_live`, `dashboard_live`, `settings/{property,room_types,rooms}_live`.
- `lib/hospex_web/live/settings/shared.ex` — shared settings chrome (topbar parity, left rail, form components).
- `assets/css/{app,calendar,dashboard,inventory,settings}.css` — design tokens live in `calendar.css :root`.
- `assets/js/app.js` — LiveView JS hooks (`CalendarGrid`, `CalendarSelect`, `SidebarScroll`, `QuickMenu`, `AtPoint`, `AutoDismiss`).
- `priv/schemas/v1/` — JSON Schemas (property, room_type, room, rate_plan, policy, content).
- `priv/repo/migrations/` — Ecto migrations.
- `examples/le_petit_madeleine/` — canonical example property's YAML files; default `PROPERTY_DIR`.

## Calendar LiveView
- ~1.9k lines `.ex` + ~1.9k lines `.heex`.
- Anchor + view_span model: `anchor` is leftmost visible date; `view_span` is 7/14/30. `derive_view/1` recomputes `dates`, `cell_w`, `total_grid_w`, `today_col`, `visible_stays_flat`, `stays_by_room`, `room_lanes`, `stats` whenever anchor/span/filters change.
- Date picker (`@dp_open`, `@dp_month`): `open_dp` → `pick_date` (sets `anchor = picked - 3`) → `close_dp`. Outside-click dismissal via `phx-click-away` on the popover. **Don't add `onclick="event.stopPropagation()"` to LiveView popovers** — kills window-level `phx-click` delegation and silently drops events.
- Drag-select on empty cells creates `quick_create`; drag on pills resizes/moves stays (`CalendarSelect` hook).
- After drop, a confirmation popover (`drag-confirm`, z-index 81) sits over a scrim (80). The pending pill at the proposed position is `.booking.pending-confirm` (z-index 5) — keep it below modals.
- Lanes: greedy interval-coloring per room (`assign_lanes/1`); overbooked rows grow.
- Subscribes to PubSub topics: `"bookings"` (mutations from `Hospex.Bookings`) and `"content"` (YAML edits from Settings) — both trigger `derive_view`.

## Bookings persistence (Postgres)
- `Hospex.Bookings.Store` is a thin namespace over Repo (no longer an Agent — see commit 410462c). All mutations return updated maps in the shape the LiveView consumes; status/src/payment_collect are atoms in the map, strings in the DB.
- `Hospex.Bookings.BookingEvent` (audit log) and `Hospex.Bookings.BookingTransaction` (payment/refund/charge line items) are separate tables with `on_delete: :delete_all` FKs to `bookings`. Preloaded on every read, ordered newest-first.
- `notes` is a column on bookings (free-text staff notes).
- Side effects of mutations always persist: `apply_payment`/`add_transaction` update `paid`/`total` on the booking AND insert a transaction AND append an event, all in one `Repo.transaction`.
- Atom safety: every string→atom conversion goes through a whitelist with `String.to_existing_atom/1` + rescue + fallback (e.g. unknown status → `:unpaid`). Keeps stale DB values from crashing the calendar.

## Settings (YAML-backed)
- `/settings/property`, `/settings/room-types`, `/settings/rooms` edit YAML in the configured property dir.
- `Hospex.Content.Property` reads/writes YAML; every write validates against the JSON Schema via `Hospex.Schema.Validator` before touching disk.
- Round-trip preserves fields the UI doesn't expose (amenities, photos, i18n other than `.en`, bed configurations, geo coords). **Known issue:** the hand-rolled YAML writer strips some fields under round-trip — see Known follow-ups. Until fixed, save through the UI with caution on `property.yaml`.
- On any successful write, broadcasts `{:content_changed, kind, id}` on the `"content"` PubSub topic so the calendar refreshes live.

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

### Known follow-ups
- **YAML writer is lossy.** `Hospex.Content.Property.save_property/1` round-trip drops fields (saw `property.yaml` go 94→74 lines after one save). The hand-rolled writer in `lib/hospex/content/property.ex` doesn't handle nested i18n maps + folded scalars + comments cleanly. Either swap to a round-tripping library (none in the current Elixir ecosystem do this well — would need to vendor one or call out to `yq`), or rewrite the writer to walk the full parsed map preserving every leaf. Until fixed, avoid saving `property.yaml` through the UI.
- **`bookings_live.ex` `handle_event/3` grouping warning.** Same fix pattern as the calendar refactor.
- **`MIX_ENV=prod` won't compile** the router. `phoenix_live_dashboard` is `only: [:dev, :test]` but the router's `if Application.compile_env(:hospex, :dev_routes)` block isn't dead-code-eliminated by the Elixir compiler. Options: gate with `if Mix.env() in [:dev, :test]` (compiler can DCE), or move the dep to all envs.
- **Bed-configuration, amenities, photos editors** in Settings — preserved on round-trip but not editable in the UI. Bed configs are required by the room_type schema; new types currently get a hardcoded single `double` bed to satisfy `minItems: 1`.
- **Hidden coupling on room-type IDs.** `Hospex.Content.MockInventory` had hardcoded keys that crashed when the calendar switched to YAML-derived IDs. Use `Map.get` with a fallback, not `Map.fetch!`, at any boundary that consumes IDs from YAML.
- **Oban workers** for `git_sync` (push YAML edits to property's GitHub repo) and `media_ingest` (photo uploads to S3) — queues are configured but no worker modules exist.
- **Search only sees the windowed set.** The calendar now loads bookings whose stays overlap `anchor ± view_span ± 7d buffer` (see `Bookings.load_calendar/2`). The search bar still filters in-memory, so guests/refs outside that window won't match. Fix by hitting Postgres for the search predicate (probably via `Bookings.Store.search/1`).

## Conventions
- Money formatted via `format_money/1`; dates via `Calendar.strftime` or local helpers (`format_date_range`, `dow_abbr`, `month_abbr`).
- Status atoms: `:paid`, `:partial`, `:unpaid`, `:in`, `:hold`, `:cancelled`, `:ota_collect`.
- Server is the source of truth for popover/menu open state — keep DOM driven by assigns, not JS toggles.
- Design tokens live in `assets/css/calendar.css :root`. All new pages reuse them rather than inventing colors. The settings redesign followed this pattern — 0 inline styles in any settings page.
