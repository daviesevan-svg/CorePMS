# Hospex

Phoenix/Elixir platform replacing Channex's content management and IBE. Greenfield, prototyped with Claude Code.

## Stack
Elixir 1.16+ / Phoenix 1.7 / LiveView / PostgreSQL / Oban / ex_json_schema / yaml_elixir

## Architecture
- Git repos are canonical source of truth (one public GitHub repo per property).
- PostgreSQL is the operational cache.
- Property content lives as YAML files validated against JSON Schema in `priv/schemas/v{major}/{entity}.json` (draft-07).
- Entity types: `property`, `room_type`, `room`, `rate_plan`, `policy`, `content`.

## Layout
- `lib/hospex/` — domain contexts: `bookings`, `content`, `inventory`, `schema`, `repo`.
- `lib/hospex_web/live/` — LiveViews: `calendar_live`, `bookings_live`, `inventory_live`, `dashboard_live`.
- `assets/js/app.js` — LiveView JS hooks (`CalendarGrid`, `CalendarSelect`, `SidebarScroll`, `QuickMenu`, `AtPoint`).
- `priv/schemas/v1/` — JSON Schemas.
- `priv/repo/migrations/` — Ecto migrations.

## Calendar LiveView
- The big one: ~1.9k lines of `.ex` + ~1.9k lines of `.heex`.
- Anchor + view_span model: `anchor` is the leftmost visible date, `view_span` is 7/14/30. `derive_view/1` recomputes `dates`, `cell_w`, `total_grid_w`, `today_col`, `visible_stays_flat`, `stays_by_room`, `room_lanes`, `stats` whenever anchor/span/filters change.
- Date picker popover (`@dp_open`, `@dp_month`): `open_dp` → `pick_date` (sets `anchor = picked - 3`) → `close_dp`. Outside-click dismissal is handled by `phx-click-away` on the popover — **do not add `onclick="event.stopPropagation()"` to the popover**; it kills LiveView's window-level click delegation and silently drops `pick_date` and the month nav events.
- Drag-select on empty cells creates `quick_create`; drag on pills resizes/moves stays (`CalendarSelect` hook).
- Lanes: greedy interval-coloring per room (`assign_lanes/1`); overbooked rows grow.

## Dev
```
mix setup           # deps + db create/migrate/seed + assets (first-time setup)
mix phx.server      # start dev server
mix test            # run tests
mix ecto.reset      # drop + create + migrate + seed
```

### Prerequisites
- **Elixir 1.16+** and **Node 18+** on PATH.
- **PostgreSQL 14+ running on `localhost:5432`** with a superuser that matches `config/dev.exs` (defaults to `postgres`/`postgres`). `mix setup` will hang or fail on `ecto.create` if no Postgres is reachable. Quick options on macOS: `brew install postgresql@16 && brew services start postgresql@16` (then `createuser -s postgres` if needed), or install [Postgres.app](https://postgresapp.com), or `docker run -d --name hospex-pg -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:16`.

### Known follow-ups
- `lib/hospex_web/live/bookings_live.ex` still emits a `handle_event/3` clause-grouping warning. Same fix pattern as the (now-completed) calendar refactor.
- Production builds (`MIX_ENV=prod`) currently won't compile the router because `phoenix_live_dashboard` is `only: [:dev, :test]` but the router's `if Application.compile_env(:hospex, :dev_routes) do ... import Phoenix.LiveDashboard.Router` block isn't dead-code-eliminated by the Elixir compiler. Options: gate with `if Mix.env() in [:dev, :test]` (compiler can DCE), or move the dep to all envs.

## Conventions
- Money formatted via `format_money/1`; dates via `Calendar.strftime` or local helpers (`format_date_range`, `dow_abbr`, `month_abbr`).
- Status atoms: `:paid`, `:partial`, `:unpaid`, `:in`, `:hold`, `:cancelled`, `:ota_collect`.
- Server is the source of truth for popover/menu open state — keep DOM driven by assigns, not JS toggles.
