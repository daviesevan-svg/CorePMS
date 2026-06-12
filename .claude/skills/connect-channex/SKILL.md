---
name: connect-channex
description: Connect this PMS to the Channex channel manager (staging or production) so bookings, availability, and prices flow to/from OTAs like Booking.com and Airbnb. Use when the user wants to set up Channex, connect to a channel manager / OTAs, sync rates and availability, receive OTA bookings, or debug Channex sync issues.
---

# Connect this PMS to Channex

The integration is already built (see the "Channex integration" section
of AGENTS.md for architecture). This skill is the setup + verification
playbook for connecting a fork to a NEW Channex account, with the
gotchas baked in.

## Setup

1. **Credentials.** The user needs a Channex account — staging
   (https://staging.channex.io) for testing, production
   (https://app.channex.io) for go-live. API key: Channex dashboard →
   user settings → API keys. Never accept the key into a committed
   file: this repo template is PUBLIC.

2. **Local config.** Copy `.env.example` to `.env` (gitignored;
   loaded automatically in dev/test by `config/runtime.exs`) and set:
   - `CHANNEX_API_KEY` — required; integration is fully inert without it
   - `CHANNEX_BASE_URL` — default is staging; set `https://app.channex.io` for production
   - `CHANNEX_RATE_PLAN` — which rate-plan YAML id is sold through the
     channel (default `flexible`). Only ONE plan syncs per room type.

   In production set real environment variables instead of `.env`.
   After config changes, restart the server (Phoenix won't hot-reload
   config).

3. **Initial sync.** With the database migrated (`mix ecto.migrate`):

       mix channex.sync

   Creates/updates the property, room types, and the primary rate plan
   on Channex from the property YAML, then pushes availability + rates
   for the next 365 days. Idempotent — Channex UUIDs are remembered in
   the `channex_links` table, so re-runs update instead of duplicating.

4. **Verify.** Always verify with a live readback, never by assuming
   the push worked:

       mix channex.doctor

   It checks config, connectivity, link completeness, compares
   sampled availability/rates against what Channex actually has, and
   inspects the feed + push jobs. Exits non-zero on failure (CI-able).

5. **Test an inbound booking.** There is NO API to inject test
   bookings. In the Channex dashboard: Applications page → add the
   "Booking CRS" app → bookings page → Create. The poller ingests it
   within a minute; it appears on the PMS calendar with the guest,
   dates, price, and OTA ref. Cancel it in the dashboard and confirm
   the local booking flips to cancelled.

6. **Channel mapping (production).** Connecting actual OTAs
   (Booking.com etc.) to the Channex property is done in the Channex
   dashboard, not via this codebase. For PMS certification, see
   https://docs.channex.io/api-v.1-documentation/pms-certification-tests.md

## Best practices baked into this integration (don't regress)

- **Push deltas, not the world.** Booking changes push availability
  only; an inventory edit pushes only the touched `{room_type, date,
  field}` cells — Channex applies PARTIAL restriction updates, so a
  price edit sends `{rate}` alone. Full pushes are reserved for
  YAML/content changes and the hourly drift-correction cron.
- **Compress ranges.** Consecutive equal values collapse into
  `date_from`/`date_to` ranges before sending (payloads must stay <10MB).
- **Rates are minor units.** Channex wants cents; this PMS stores whole
  currency units. The conversion lives at the Channex boundary only.
- **Never push past dates.** Channex rejects them (422).
- **Ack discipline.** Every feed revision is acked AFTER it applies
  successfully; failures stay un-acked and retry next poll. Unacked
  revisions trigger Channex warning emails after ~30 min.
- **The feed is account-wide.** Revisions for properties without a
  local link are acked + skipped, so stray test properties on the same
  account can't wedge the poller.
- **`modified` revisions are logged + acked but NOT applied** — OTA
  modifications need human reconciliation. Tell the user when one
  appears in the logs.
- **Overbooking is accepted, not refused.** If no room is free, the
  booking still ingests into the first room and the calendar's
  overbooking lane flags it — a channel-manager booking must never be
  silently dropped.

## Debugging

- `mix channex.doctor` first — it localizes most problems.
- Push pipeline: events → `Hospex.Channex.Listener` (3s debounce) →
  Oban queue `:channex`. Inspect jobs: `Oban.Job` where queue =
  "channex" — the args show exactly what scope/cells were pushed.
- Rate "drift" on doctor while the app is running is usually an
  inventory override: overrides are process-local (in-memory Agent),
  visible only inside the running server. They also vanish on restart,
  reverting OTAs to YAML-computed rates on the next push.
- Verifying from a separate `mix run` VM races the running dev server
  (both push their own state). Trust Oban job args / `Req.Test`
  payload assertions over staging end-state when both are alive.
- Channex docs are LLM-friendly: append `.md` to any docs.channex.io
  page URL; `https://docs.channex.io/sitemap.md` lists everything.
- API responses wrap payloads as `{"data": ...}`; errors as
  `{"errors": {"code", "title", "details"}}`. Auth is the
  `user-api-key` header.
