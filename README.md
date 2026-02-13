# hedge-labs

Paper-only fund arena powered by the real [virattt/dexter](https://github.com/virattt/dexter) runtime.

Lanes operate as **stateful rebalance engines**: each run references the previous successful portfolio for that lane, injects a 7-day aggregated context summary, and enforces cadence-aware rebalance behavior.

## Overview

This repository runs one or more simulated “fund lanes” on a daily schedule, then publishes a combined summary.

- Fund lanes are discovered automatically from `funds/fund-*/fund.config.json`.
- Results are consolidated into a single commit.
- A Discord digest is posted, including partial-failure days.

Schedule: **06:17 UTC** (`17 6 * * *`).

## GitHub Actions

Primary workflow: `/.github/workflows/fund-arena-daily.yml`.

- Scheduled runs (cron) commit/push updated `funds/**` outputs to `main` and post the Discord digest.
- Manual runs (`workflow_dispatch`) default to *not* publishing and *not* posting to Discord; set inputs to enable.
- Optional input `run_date` overrides the UTC run date (`YYYY-MM-DD`).

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

## Strategy, Signals, and Trade-Offs

Each lane is a paper-only, stateful rebalance engine. There is no deterministic “alpha model” in this repo; the lane’s strategy is primarily encoded in its prompt template and then executed by the Dexter agent under hard risk/format constraints.

### How It Chooses What To "Buy" (Paper)

1. Lane configuration comes from `funds/fund-*/fund.config.json` and `funds/fund-*/prompt.template.txt` (universe, horizon, positions, caps, provider/model, and the qualitative "style").
2. `scripts/render_prompt.sh` renders the prompt template and appends **stateful context**:
   - prior successful `target_portfolio`
   - prior `trade_of_the_day`
   - a 7-day aggregated context JSON summary (recent actions, recurring holdings, thesis-damage counts, average turnover, and deduped market-summary bullets)
   - whether a rebalance is due today (based on the lane's cadence and last successful run date)
3. Dexter executes the prompt and is required (by prompt + validation) to call `financial_search` to fetch verifiable market data. The template also pushes a "single combined query" workflow and caps the ticker count to reduce broad scanning.
4. The agent outputs a full `target_portfolio` (exactly `positions` tickers with weights) plus a `trade_of_the_day` headline action and `rebalance_actions` list for the run.

### What Trading Is Based On

Trading decisions are based on:

- tool-fetched, verifiable data from `financial_search` (for example: price snapshots, limited historical price windows, and key ratios when needed)
- the lane's stated time horizon and universe (from `fund.config.json` / prompt template)
- prior portfolio continuity and recent lane history (the appended 7-day summary and the prior portfolio/trade context)

Anything the model cannot verify via tools is expected to be marked `UNKNOWN` by the prompt rules.

### How Rebalancing Works (Mechanics and Enforcement)

Rebalancing is both *suggested* to the model (via prompt context) and *enforced* in the runner:

- Cadence is configured per lane via `fund.config.json` -> `rebalance` (supported: `daily`, `weekly`, `monthly`).
- For each run, the runner finds the **previous successful run** for that lane and computes `rebalance_due` using a minimum spacing of 1/7/30 days.
- If `rebalance_due` is false, the prompt explicitly instructs: action must be `"Do nothing"` and `target_portfolio` must remain **exactly unchanged**.
- `scripts/run_fund_once.sh` validates that policy. Any portfolio change or active action on a non-due day fails the lane.
- If `rebalance_due` is true and the model makes changes, validation also checks internal consistency:
  - `trade_of_the_day` must match actual portfolio deltas (e.g., add_ticker weight increases, remove_ticker decreases)
  - `rebalance_actions` must include at least one non-"Do nothing" action when the portfolio changed

### Guardrails (What Makes A Run "Valid")

In addition to the rebalance policy, `scripts/run_fund_once.sh` enforces a set of deterministic constraints so runs are comparable and machine-checkable:

- output must be a single valid JSON object (no prose), with required fields populated
- `target_portfolio` must contain exactly `positions` unique tickers (no `UNKNOWN` / `CASH`)
- each `weight_pct` must be within `[min_position_pct, max_position_pct]` and total weight must sum to ~100%
- sector exposure must be under `max_sector_pct`
- crypto exposure must be under `max_crypto_pct` (via `sector == "Crypto"` or `*-USD`/`*-USDT` tickers)
- broad index ETFs are disallowed (see prompt template for examples)
- `constraints_check.max_position_ok`, `max_sector_ok`, and `max_crypto_ok` must all be `true` and consistent with the portfolio

If a run fails deterministic validation due to portfolio weight/sector constraint issues, the runner may apply a deterministic weight adjustment to satisfy constraints and re-validate. If it fails due to malformed JSON or policy issues, the runner generates a retry prompt describing the failure and asks the agent to correct it.

### Why Weekly (and When Not To)

Current lane configs use `weekly` rebalancing. The trade-offs are:

- Weekly reduces churn/turnover and avoids noisy day-to-day overreaction, while still updating often enough to incorporate meaningful new information (earnings, guidance changes, macro shocks).
- Daily increases responsiveness but tends to produce more turnover and tool usage (and makes it easier for the model to "thrash" the portfolio).
- Monthly further reduces churn but can lag real regime shifts.

This is intentionally configurable per lane in `fund.config.json`.

## Financial Datasets enforcement

A lane is marked failed if any of these conditions occur:

- Dexter output is invalid JSON.
- Dexter scratchpad is missing.
- Dexter did not call `financial_search`.
- Financial Datasets source coverage is too low or error ratio is too high.

This enforces Financial Datasets tool usage for successful runs.

## Required GitHub secrets

- `FINANCIAL_DATASETS_API_KEY` (required for successful lane runs)
- Provider keys (required depending on `fund.config.json` -> `provider`):
  - `OPENAI_API_KEY`
  - `ANTHROPIC_API_KEY`
  - `XAI_API_KEY`
- `DISCORD_WEBHOOK_URL` (required to post the digest; scheduled runs post by default)

Also set repository Actions permission to **Read and write**.

## Adding a fund lane

1. Create a new lane directory: `funds/fund-<id>/`.
1. Add `funds/fund-<id>/fund.config.json` with `paper_only=true` and a `provider` (for example: `openai`, `anthropic`, or `xai`).
1. Add `funds/fund-<id>/prompt.template.txt`.
1. The next workflow run will auto-discover it via `funds/fund-*/fund.config.json`.

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
- `funds/arena/runs/YYYY-MM-DD/scoreboard.txt` (plain-text snippet used in Discord "Scoreboard" block)

### Arena config

- `funds/arena/indices.json` (tickers used for the "Indices" performance block)

## Local smoke run

Prerequisites: Bun, Node.js, and `jq` installed. Export required API keys in your environment, or create a local `.env` file (gitignored).

```bash
bun install

RUN_DATE="$(date -u +%F)"

fund_id="fund-a"
provider="$(jq -r '.provider' "funds/${fund_id}/fund.config.json")"
run_path="funds/${fund_id}/runs/${RUN_DATE}/${provider}"

mkdir -p "$run_path"
scripts/render_prompt.sh "$fund_id" "$RUN_DATE" "${run_path}/prompt.txt"
scripts/run_fund_once.sh "$fund_id" "$provider" "$RUN_DATE" "${run_path}/prompt.txt"

scripts/build_scoreboard.sh "$RUN_DATE"
```

## Notes

- Strictly paper-only; no broker or execution paths.
- Raw scratchpads under `.dexter/scratchpad/` are ignored.
- Run-local scratchpads copied into each lane run directory are tracked.

## Performance Tracking

Scoreboard and Discord display fund performance as a NAV-style return **since inception** (the first successful run date for that lane). Benchmark comparisons use the fund's configured benchmark index (`fund.config.json` -> `benchmark`).

On days a lane fails, performance is still shown based on the last successful portfolio and is labeled as **stale** with the last successful run date.
