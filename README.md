# hedge-labs

Paper-only fund arena powered by the real [virattt/dexter](https://github.com/virattt/dexter) runtime.

## Overview

This repository runs two simulated “fund lanes” on a daily schedule, then publishes a combined summary.

- `fund-a` lane uses the OpenAI model configured in `funds/fund-a/fund.config.json`.
- `fund-b` lane uses the Anthropic model configured in `funds/fund-b/fund.config.json`.
- Results are consolidated into a single commit.
- A Discord digest is posted, including partial-failure days.

Schedule: **06:17 UTC** (`17 6 * * *`).

## Runtime architecture

This repo uses Dexter directly from dependencies (no custom financial agent implementation):

- `dexter-ts` pinned to `github:virattt/dexter#v2026.2.11`.
- Dependencies are installed with Bun in CI.
- `scripts/dexter_run_once.ts` wraps and executes Dexter.
- The wrapper imports `Agent` from installed `dexter-ts` and runs `Agent.create(...)` non-interactively against a rendered prompt.
- Files in `node_modules` are not patched.

### Core scripts

- `scripts/ensure_dexter.sh`
- `scripts/run_fund_once.sh`
- `scripts/render_prompt.sh`
- `scripts/build_scoreboard.sh`
- `scripts/build_discord_payload.sh`

## Financial Datasets enforcement

A lane is marked failed if any of these conditions occur:

- Dexter output is invalid JSON.
- Dexter scratchpad is missing.
- Dexter did not call `financial_search` or `financial_metrics`.

This enforces Financial Datasets tool usage for successful runs.

## Required GitHub secrets

- `FINANCIAL_DATASETS_API_KEY`
- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `DISCORD_WEBHOOK_URL`

Also set repository Actions permission to **Read and write**.

## Output locations

### Per lane

- `funds/<fund-id>/runs/YYYY-MM-DD/<provider>/prompt.txt`
- `funds/<fund-id>/runs/YYYY-MM-DD/<provider>/dexter_stdout.txt`
- `funds/<fund-id>/runs/YYYY-MM-DD/<provider>/dexter_output.json`
- `funds/<fund-id>/runs/YYYY-MM-DD/<provider>/scratchpad.jsonl`
- `funds/<fund-id>/runs/YYYY-MM-DD/<provider>/run_meta.json`

### Arena summary

- `funds/arena/runs/YYYY-MM-DD/scoreboard.json`
- `funds/arena/runs/YYYY-MM-DD/scoreboard.md`

## Local smoke run

Prerequisites: Bun and `jq` installed.

```bash
RUN_DATE="$(date -u +%F)"
mkdir -p "funds/fund-a/runs/${RUN_DATE}/openai"
scripts/render_prompt.sh fund-a "$RUN_DATE" "funds/fund-a/runs/${RUN_DATE}/openai/prompt.txt"
scripts/run_fund_once.sh fund-a openai "$RUN_DATE" "funds/fund-a/runs/${RUN_DATE}/openai/prompt.txt"
```

## Notes

- Strictly paper-only; no broker or execution paths.
- Raw scratchpads under `.dexter/scratchpad/` are ignored.
- Run-local scratchpads copied into each lane run directory are tracked.
