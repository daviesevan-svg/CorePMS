# Hospex

A hospitality content platform for managing property content as structured data in public Git repositories, backed by a Phoenix/LiveView web application.

Built as a strategic initiative to replace and supersede the content management and IBE (Internet Booking Engine) features in [Channex](https://channex.io).

---

## What this is

Hospex treats property content — room types, photos, rate plans, policies, marketing copy — as **structured data with a documented schema**, committed to a public Git repository. This makes the content:

- **Portable**: any consumer (IBE, OTA sync, RMS, AI agent) can read it without going through an API
- **Auditable**: the full change history of a property's content is in Git
- **AI-readable**: YAML + JSON Schema is trivially parseable by any language model
- **Recoverable**: if our database is wiped, we rebuild from the repos

The PostgreSQL database is a cache and operational layer. Git is the source of truth.

---

## Repository layout (per property)

Each property gets a public GitHub repository under the Channex organisation. The repo looks like this:

```
le-petit-madeleine/          ← repo root = property ID
├── property.yaml            ← property profile, contact, amenities, photos
├── room_types/
│   ├── classic-room.yaml
│   ├── deluxe-sea-view.yaml
│   └── junior-suite.yaml
├── rooms/
│   ├── room-101.yaml        ← physical unit references its room type
│   ├── room-102.yaml
│   └── room-301.yaml
├── rate_plans/
│   ├── flexible.yaml
│   ├── non-refundable.yaml
│   └── bed-and-breakfast.yaml
├── policies/
│   └── policies.yaml        ← cancellation policies, check-in/out, pets, etc.
└── content/
    └── content.yaml         ← marketing copy, FAQs, nearby places
```

The `examples/le_petit_madeleine/` directory in this repo is the **canonical example** — a complete fictional boutique hotel that demonstrates every schema feature. Read it before writing your own content.

---

## Schema versioning

Every YAML file begins with:

```yaml
schema_version: "1.0"
```

Schemas live in `priv/schemas/v{major}/`. The version in each file must match a `1.x` version (major version 1). Minor version bumps (1.0 → 1.1) add optional fields and are backwards compatible. Major version bumps (1.x → 2.0) may break existing files and require migration tooling.

Schema files (`*.json`) are [JSON Schema draft-07](https://json-schema.org/draft-07/json-schema-validation.html).

---

## Multilingual text

Any field that appears to guests uses a `multilingual_text` structure: an object keyed by [ISO 639-1](https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes) language code.

```yaml
name:
  en: Classic Room
  fr: Chambre Classique
  de: Klassisches Zimmer
```

At minimum, provide `en`. The property's `languages` array declares which languages are maintained.

---

## Rate plans

Rate plans are the most complex entity. A nightly rate is computed as:

```
final_rate = base_rate × seasonal_modifier × dow_modifier
```

Where:
- `base_rate` is the per-room-type rate in `pricing.room_rates`
- `seasonal_modifier` is the adjustment from the **first matching** date range in `pricing.seasonal_modifiers` (1.0 if no range matches)
- `dow_modifier` is the adjustment from `pricing.dow_modifiers` for the night's day of week (1.0 if not specified)

Modifiers are written as strings: `"+25%"` or `"-10%"` for percentage adjustments, `"+30"` or `"-20.50"` for fixed amounts in the property currency.

**Example**: a Classic Room (base €120) on a Saturday in July (summer peak):
```
120 × 1.35 × 1.15 = €186.30
```

### Cancellation terms

Rate plans either reference a named policy from `policies/policies.yaml`:

```yaml
cancellation:
  policy_id: flexible-48h
```

Or define their terms inline:

```yaml
cancellation:
  terms:
    - before_days: 7    # cancel 7+ days before: full refund
      refund_percent: 100
    - before_days: 0    # cancel <7 days before: no refund
      refund_percent: 0
```

Terms are evaluated from top to bottom; the first tier where `before_days` ≤ days until arrival applies.

---

## Validation

### In the platform

```elixir
# Validate a file on disk
Hospex.Schema.Validator.validate_file("path/to/rate_plans/flexible.yaml", :rate_plan)
# => :ok

# Validate a YAML string
Hospex.Schema.Validator.validate_string(yaml_string, :property)
# => {:error, [%{path: "#/address/country", message: "Value \"gb\" does not match pattern..."}]}
```

Entity type atoms: `:property`, `:room_type`, `:room`, `:rate_plan`, `:policy`, `:content`

### In GitHub Actions

Each property repo includes a GitHub Actions workflow that runs on every push. The workflow validates all YAML files against the schema and fails the push if any file is invalid, preventing malformed content from entering the repo.

The platform double-validates on ingest — it does not trust the upstream GitHub Actions run.

---

## For AI agents

If you're an AI coding assistant (Claude Code, Cursor, Aider, Codex, etc.) picking up this project, read [`AGENTS.md`](AGENTS.md) first — it has the stack, file layout, calendar LiveView model, dev commands, and known gotchas. `CLAUDE.md` is a symlink to the same file.

The roadmap below ("What's next") tells you where to keep going.

---

## Running locally

```bash
# One-shot: deps + db create/migrate/seed + assets
mix setup

# Or step by step:
mix deps.get
mix ecto.setup

# Run tests (schema validation tests don't need a database)
mix test test/hospex/schema/

# Start the development server
mix phx.server
```

Requires Elixir 1.16+, Node 18+, and PostgreSQL 14+.

### Toolchain

The repo ships a [`.mise.toml`](.mise.toml) pinning Erlang/Elixir/Node versions. If you use [mise](https://mise.jdx.dev), `mise install` from the repo root sets up everything in one step. Otherwise install Elixir + Node manually to match.

### Postgres

**Postgres must be running on `localhost:5432`** before `mix setup`, with a superuser named `postgres` (password `postgres`) to match `config/dev.exs`.

```bash
# macOS via Homebrew
brew install postgresql@16
brew services start postgresql@16
createuser -s postgres                                  # or:
# psql -d postgres -c "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';"

# Or a container (no Homebrew needed)
docker run -d --name hospex-pg -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:16

# Or GUI: install Postgres.app from postgresapp.com
```

---

## License

[MIT](LICENSE). Free to use, fork, modify, and deploy for your own property — commercial use included.

### Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `DATABASE_URL` | prod only | PostgreSQL connection string |
| `SECRET_KEY_BASE` | prod only | Phoenix secret key (generate with `mix phx.gen.secret`) |
| `PHX_HOST` | prod only | Public hostname |
| `GITHUB_TOKEN` | yes | Token with repo creation and write access to the org |
| `GITHUB_ORG` | yes | GitHub organisation for property repos |
| `S3_BUCKET` | yes | Bucket for photo storage |
| `AWS_REGION` | yes | AWS region for the S3 bucket |

---

## Project structure

```
lib/
├── hospex/
│   ├── application.ex       ← OTP application, supervision tree
│   ├── repo.ex              ← Ecto repo
│   ├── content/             ← content context (Ecto schemas, queries) — next session
│   └── schema/
│       ├── validator.ex     ← YAML → JSON Schema validation
│       └── errors.ex        ← structured error types
└── hospex_web/
    ├── endpoint.ex
    ├── router.ex
    ├── live/                ← LiveView modules — next session
    └── components/          ← shared UI components — next session

priv/
└── schemas/
    └── v1/
        ├── property.json
        ├── room_type.json
        ├── room.json
        ├── rate_plan.json
        ├── policy.json
        └── content.json

examples/
└── le_petit_madeleine/      ← canonical example — read before writing content
```

---

## What's next

| Session | Focus |
|---------|-------|
| Next | Ecto schemas for the database cache layer; LiveView UI for property editing |
| Later | Git integration — creating repos, committing content changes |
| Later | GitHub Actions validation workflow template |
| Later | IBE templates and booking flow |
| Later | API for PMS partner content ingestion |
| Later | Migration of existing Channex properties |
