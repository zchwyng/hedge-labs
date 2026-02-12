# hedge-labs

Paper-only "fund arena" that runs daily, stores model outputs in-repo, and posts a concise summary to Discord.

## What this does

- Runs two paper lanes side-by-side each day:
  - `fund-a` with `openai`
  - `fund-b` with `anthropic`
- Renders fund prompts from per-fund config files.
- Runs Dexter once per lane (`bun start < prompt.txt`).
- Stores lane outputs under dated folders in `funds/<fund-id>/runs/YYYY-MM-DD/<provider>/`.
- Builds an arena scoreboard in `funds/arena/runs/YYYY-MM-DD/`.
- Commits and pushes one daily consolidated update to `main`.
- Posts one daily Discord digest (including partial-failure status).

## Repository layout

```text
.github/workflows/fund-arena-daily.yml
funds/
  arena/runs/
  fund-a/
    fund.config.json
    prompt.template.txt
  fund-b/
    fund.config.json
    prompt.template.txt
scripts/
  render_prompt.sh
  run_fund_once.sh
  build_scoreboard.sh
  build_discord_payload.sh
```

## Prerequisites

- Bun available in CI/local (`bun install`, `bun start`).
- Dexter project behavior:
  - accepts stdin prompt for one run
  - writes scratchpads under `.dexter/scratchpad/*.jsonl`
- `jq` installed for JSON parsing/validation in scripts.

## GitHub Actions setup

In repo settings:

1. Enable **Actions > General > Workflow permissions > Read and write**.
2. Add the following repository secrets:
   - `FINANCIAL_DATASETS_API_KEY`
   - `OPENAI_API_KEY`
   - `ANTHROPIC_API_KEY`
   - `DISCORD_WEBHOOK_URL`

## Daily workflow behavior

Workflow file: `.github/workflows/fund-arena-daily.yml`

- Triggers:
  - `schedule`: `17 6 * * *` (06:17 UTC daily)
  - `workflow_dispatch`
- Job `run_lanes`:
  - runs both explicit lanes
  - renders prompt
  - runs Dexter once per lane
  - uploads lane artifacts
- Job `finalize_and_publish` (`if: always()`):
  - downloads all lane artifacts
  - builds scoreboard (`scoreboard.json`, `scoreboard.md`)
  - commits/pushes one consolidated change if files changed
  - posts one Discord summary
  - marks workflow failed if any lane failed (after publish)

## Output contract

Per lane:

- `funds/<fund-id>/runs/YYYY-MM-DD/<provider>/prompt.txt`
- `funds/<fund-id>/runs/YYYY-MM-DD/<provider>/dexter_stdout.txt`
- `funds/<fund-id>/runs/YYYY-MM-DD/<provider>/dexter_output.json`
- `funds/<fund-id>/runs/YYYY-MM-DD/<provider>/scratchpad.jsonl` (if found)
- `funds/<fund-id>/runs/YYYY-MM-DD/<provider>/run_meta.json`

Arena-level:

- `funds/arena/runs/YYYY-MM-DD/scoreboard.json`
- `funds/arena/runs/YYYY-MM-DD/scoreboard.md`

## Local usage

Render a prompt:

```bash
scripts/render_prompt.sh fund-a 2026-02-12 funds/fund-a/runs/2026-02-12/openai/prompt.txt
```

Run one lane:

```bash
scripts/run_fund_once.sh fund-a openai 2026-02-12 funds/fund-a/runs/2026-02-12/openai/prompt.txt
```

Build scoreboard + Discord payload:

```bash
scripts/build_scoreboard.sh 2026-02-12
scripts/build_discord_payload.sh 2026-02-12
```

## Notes

- This project is strictly **paper-only**. No brokerage/execution integration is included.
- `.dexter/scratchpad/*` is ignored; copied run-local scratchpads under `funds/.../runs/...` are tracked.
