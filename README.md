# hedge-labs

Paper-only fund arena using the real [virattt/dexter](https://github.com/virattt/dexter) agent runtime.

Lanes operate as **stateful rebalance engines**: each run references the previous successful portfolio for that lane, injects a 7-day aggregated context summary, and enforces cadence-aware rebalance behavior.

## What runs daily

- `fund-a` lane using OpenAI model from `funds/fund-a/fund.config.json`
- `fund-b` lane using Anthropic model from `funds/fund-b/fund.config.json`
- One consolidated commit to `main`
- One Discord digest post (even on partial failure)

Schedule: **06:17 UTC** (`17 6 * * *`).

## Runtime architecture

This repo does **not** use a custom financial agent anymore.

It runs Dexter from `package.json` dependency:

- `dexter-ts` pinned to `github:virattt/dexter#v2026.2.11`
- Installs dependencies with Bun during workflow
- Runs local wrapper `scripts/dexter_run_once.ts`
- Wrapper imports Dexter `Agent` from installed `dexter-ts` and runs `Agent.create(...)` non-interactively against the rendered prompt
- Does not patch files inside `node_modules`

Main scripts:

- `/Users/jonasdalesjo/code/hedge-labs/scripts/ensure_dexter.sh`
- `/Users/jonasdalesjo/code/hedge-labs/scripts/run_fund_once.sh`
- `/Users/jonasdalesjo/code/hedge-labs/scripts/render_prompt.sh`
- `/Users/jonasdalesjo/code/hedge-labs/scripts/build_scoreboard.sh`
- `/Users/jonasdalesjo/code/hedge-labs/scripts/build_discord_payload.sh`

## Financial Datasets enforcement

A lane is marked failed if:

- Dexter output is invalid JSON, or
- Dexter scratchpad is missing, or
- Dexter did not call both `financial_search` and `financial_metrics`, or
- Financial Datasets source coverage is too low / error ratio is too high

This enforces actual Financial Datasets tool usage in successful runs.

## Required GitHub secrets

- `FINANCIAL_DATASETS_API_KEY`
- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `DISCORD_WEBHOOK_URL`

Also set repo Actions permission to **Read and write**.

## Output locations

Per lane:

- `/Users/jonasdalesjo/code/hedge-labs/funds/<fund-id>/runs/YYYY-MM-DD/<provider>/prompt.txt`
- `/Users/jonasdalesjo/code/hedge-labs/funds/<fund-id>/runs/YYYY-MM-DD/<provider>/dexter_stdout.txt`
- `/Users/jonasdalesjo/code/hedge-labs/funds/<fund-id>/runs/YYYY-MM-DD/<provider>/dexter_output.json`
- `/Users/jonasdalesjo/code/hedge-labs/funds/<fund-id>/runs/YYYY-MM-DD/<provider>/scratchpad.jsonl`
- `/Users/jonasdalesjo/code/hedge-labs/funds/<fund-id>/runs/YYYY-MM-DD/<provider>/run_meta.json`

Arena summary:

- `/Users/jonasdalesjo/code/hedge-labs/funds/arena/runs/YYYY-MM-DD/scoreboard.json`
- `/Users/jonasdalesjo/code/hedge-labs/funds/arena/runs/YYYY-MM-DD/scoreboard.md`

## Local smoke run

Prereqs: Bun + `jq` installed.

```bash
cd /Users/jonasdalesjo/code/hedge-labs
RUN_DATE="$(date -u +%F)"
mkdir -p "funds/fund-a/runs/${RUN_DATE}/openai"
scripts/render_prompt.sh fund-a "$RUN_DATE" "funds/fund-a/runs/${RUN_DATE}/openai/prompt.txt"
scripts/run_fund_once.sh fund-a openai "$RUN_DATE" "funds/fund-a/runs/${RUN_DATE}/openai/prompt.txt"
```

## Notes

- Strictly paper-only. No broker/execution paths.
- Raw scratchpads in `/Users/jonasdalesjo/code/hedge-labs/.dexter/scratchpad/` are ignored; copied run-local scratchpads are tracked.
