#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <fund_id> <run_date> <out_prompt_path>" >&2
  exit 64
fi

fund_id="$1"
run_date="$2"
out_prompt_path="$3"

config_path="funds/${fund_id}/fund.config.json"
template_path="funds/${fund_id}/prompt.template.txt"

if [[ ! -f "$config_path" ]]; then
  echo "Missing fund config: $config_path" >&2
  exit 1
fi

if [[ ! -f "$template_path" ]]; then
  echo "Missing prompt template: $template_path" >&2
  exit 1
fi

IFS=$'\t' read -r fund_name provider model universe hold_horizon positions max_position max_sector rebalance paper_only < <(
  jq -r '[
    .name,
    .provider,
    .model,
    .universe,
    .hold_horizon_days,
    .positions,
    .max_position_pct,
    .max_sector_pct,
    .rebalance,
    .paper_only
  ] | @tsv' "$config_path"
)
max_crypto="$(jq -r '.max_crypto_pct // 10' "$config_path")"

if [[ "$paper_only" != "true" ]]; then
  echo "fund.config.json must set paper_only=true for ${fund_id}" >&2
  exit 1
fi

required_placeholders=(
  "{RUN_DATE}"
  "{FUND_NAME}"
  "{PROVIDER}"
  "{MODEL}"
  "{UNIVERSE}"
  "{HOLD_HORIZON_DAYS}"
  "{POSITIONS}"
  "{MAX_POSITION_PCT}"
  "{MAX_SECTOR_PCT}"
  "{MAX_CRYPTO_PCT}"
  "{REBALANCE}"
)

for placeholder in "${required_placeholders[@]}"; do
  if ! grep -qF "$placeholder" "$template_path"; then
    echo "Template ${template_path} is missing placeholder ${placeholder}" >&2
    exit 1
  fi
done

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\\/&]/\\&/g'
}

latest_successful_output_before_run() {
  local target_fund_id="$1"
  local target_provider="$2"
  local target_run_date="$3"
  local runs_root="funds/${target_fund_id}/runs"
  local prev_output=""
  local prev_date=""
  local candidate_output=""
  local candidate_meta=""
  local candidate_status=""

  if [[ -d "$runs_root" ]]; then
    while IFS= read -r d; do
      [[ "$d" < "$target_run_date" ]] || continue
      candidate_output="${runs_root}/${d}/${target_provider}/dexter_output.json"
      candidate_meta="${runs_root}/${d}/${target_provider}/run_meta.json"
      if [[ ! -f "$candidate_output" ]]; then
        continue
      fi
      if [[ -f "$candidate_meta" ]]; then
        candidate_status="$(jq -r '.status // "failed"' "$candidate_meta")"
        [[ "$candidate_status" == "success" ]] || continue
      fi
      prev_output="$candidate_output"
      prev_date="$d"
    done < <(find "$runs_root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort)
  fi

  printf '%s\t%s\n' "$prev_output" "$prev_date"
}

days_between_dates() {
  local from_date="$1"
  local to_date="$2"
  node - "$from_date" "$to_date" <<'NODE'
const fromDate = process.argv[2];
const toDate = process.argv[3];
const fromMs = Date.parse(`${fromDate}T00:00:00Z`);
const toMs = Date.parse(`${toDate}T00:00:00Z`);
if (!Number.isFinite(fromMs) || !Number.isFinite(toMs) || toMs < fromMs) {
  process.exit(1);
}
const days = Math.floor((toMs - fromMs) / 86400000);
process.stdout.write(`${days}\n`);
NODE
}

minimum_days_between_rebalances() {
  local cadence="$1"
  case "$cadence" in
    daily) printf '1\n' ;;
    weekly) printf '7\n' ;;
    monthly) printf '30\n' ;;
    *) printf '0\n' ;;
  esac
}

build_last7_summary_json() {
  local target_fund_id="$1"
  local target_provider="$2"
  local target_run_date="$3"
  node - "$target_fund_id" "$target_provider" "$target_run_date" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

const fundId = process.argv[2];
const provider = process.argv[3];
const runDate = process.argv[4];
const lookbackDays = 7;

function readJsonSafe(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }
}

function dateFromString(dateStr) {
  const ms = Date.parse(`${dateStr}T00:00:00Z`);
  return Number.isFinite(ms) ? ms : null;
}

function turnoverPct(prevPortfolio, currPortfolio) {
  const prev = new Map();
  const curr = new Map();
  for (const item of prevPortfolio || []) {
    if (!item || typeof item.ticker !== 'string') continue;
    prev.set(item.ticker.toUpperCase(), Number(item.weight_pct || 0));
  }
  for (const item of currPortfolio || []) {
    if (!item || typeof item.ticker !== 'string') continue;
    curr.set(item.ticker.toUpperCase(), Number(item.weight_pct || 0));
  }
  const tickers = new Set([...prev.keys(), ...curr.keys()]);
  let sumAbs = 0;
  for (const ticker of tickers) {
    sumAbs += Math.abs((curr.get(ticker) || 0) - (prev.get(ticker) || 0));
  }
  return Number((sumAbs / 2).toFixed(2));
}

const runDateMs = dateFromString(runDate);
if (runDateMs == null) {
  process.stdout.write('{}\n');
  process.exit(0);
}

const minDateMs = runDateMs - (lookbackDays * 86400000);
const runsRoot = path.join('funds', fundId, 'runs');
if (!fs.existsSync(runsRoot)) {
  process.stdout.write(JSON.stringify({
    lookback_days: lookbackDays,
    successful_runs: 0,
    successful_run_dates: [],
    action_history: [],
    average_turnover_pct: null,
    market_summary_bullets: [],
    thesis_damage_counts: [],
    recurring_holdings: []
  }) + '\n');
  process.exit(0);
}

const runDates = fs.readdirSync(runsRoot)
  .filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d))
  .filter((d) => {
    const ms = dateFromString(d);
    return ms != null && ms < runDateMs && ms >= minDateMs;
  })
  .sort();

const runs = [];
for (const d of runDates) {
  const outputPath = path.join(runsRoot, d, provider, 'dexter_output.json');
  const metaPath = path.join(runsRoot, d, provider, 'run_meta.json');
  if (!fs.existsSync(outputPath)) continue;
  const meta = readJsonSafe(metaPath);
  if (meta && meta.status && meta.status !== 'success') continue;
  const out = readJsonSafe(outputPath);
  if (!out) continue;
  runs.push({
    date: d,
    output: out
  });
}

const actionHistory = runs.map((r) => ({
  run_date: r.date,
  trade_of_the_day: {
    action: r.output?.trade_of_the_day?.action ?? 'UNKNOWN',
    add_ticker: r.output?.trade_of_the_day?.add_ticker ?? null,
    remove_ticker: r.output?.trade_of_the_day?.remove_ticker ?? null,
    size_change_pct: Number(r.output?.trade_of_the_day?.size_change_pct ?? 0)
  },
  rebalance_actions_count: Array.isArray(r.output?.rebalance_actions) ? r.output.rebalance_actions.length : 0
}));

const turnovers = [];
for (let i = 1; i < runs.length; i += 1) {
  const prev = runs[i - 1].output?.target_portfolio || [];
  const curr = runs[i].output?.target_portfolio || [];
  turnovers.push(turnoverPct(prev, curr));
}
const averageTurnover = turnovers.length > 0
  ? Number((turnovers.reduce((a, b) => a + b, 0) / turnovers.length).toFixed(2))
  : null;

const marketSummarySet = new Set();
for (const r of runs) {
  for (const line of (r.output?.market_summary || [])) {
    if (typeof line === 'string' && line.trim().length > 0) {
      marketSummarySet.add(line.trim());
    }
  }
}
const marketSummaryBullets = [...marketSummarySet].slice(0, 12);

const thesisDamageMap = new Map();
for (const r of runs) {
  for (const item of (r.output?.thesis_damage_flags || [])) {
    if (!item || typeof item.ticker !== 'string') continue;
    const ticker = item.ticker.trim().toUpperCase();
    if (!ticker) continue;
    thesisDamageMap.set(ticker, (thesisDamageMap.get(ticker) || 0) + 1);
  }
}
const thesisDamageCounts = [...thesisDamageMap.entries()]
  .map(([ticker, count]) => ({ ticker, count }))
  .sort((a, b) => {
    if (b.count !== a.count) return b.count - a.count;
    return a.ticker.localeCompare(b.ticker);
  })
  .slice(0, 10);

const holdingMap = new Map();
for (const r of runs) {
  const seenThisRun = new Set();
  for (const item of (r.output?.target_portfolio || [])) {
    if (!item || typeof item.ticker !== 'string') continue;
    const ticker = item.ticker.trim().toUpperCase();
    if (!ticker || seenThisRun.has(ticker)) continue;
    seenThisRun.add(ticker);
    holdingMap.set(ticker, (holdingMap.get(ticker) || 0) + 1);
  }
}
const recurringHoldings = [...holdingMap.entries()]
  .map(([ticker, appearance_count]) => ({ ticker, appearance_count }))
  .sort((a, b) => {
    if (b.appearance_count !== a.appearance_count) return b.appearance_count - a.appearance_count;
    return a.ticker.localeCompare(b.ticker);
  })
  .slice(0, 12);

process.stdout.write(JSON.stringify({
  lookback_days: lookbackDays,
  successful_runs: runs.length,
  successful_run_dates: runs.map((r) => r.date),
  action_history: actionHistory,
  average_turnover_pct: averageTurnover,
  market_summary_bullets: marketSummaryBullets,
  thesis_damage_counts: thesisDamageCounts,
  recurring_holdings: recurringHoldings
}) + '\n');
NODE
}

mkdir -p "$(dirname "$out_prompt_path")"

sed \
  -e "s/{RUN_DATE}/$(escape_sed "$run_date")/g" \
  -e "s/{FUND_NAME}/$(escape_sed "$fund_name")/g" \
  -e "s/{PROVIDER}/$(escape_sed "$provider")/g" \
  -e "s/{MODEL}/$(escape_sed "$model")/g" \
  -e "s/{UNIVERSE}/$(escape_sed "$universe")/g" \
  -e "s/{HOLD_HORIZON_DAYS}/$(escape_sed "$hold_horizon")/g" \
  -e "s/{POSITIONS}/$(escape_sed "$positions")/g" \
  -e "s/{MAX_POSITION_PCT}/$(escape_sed "$max_position")/g" \
  -e "s/{MAX_SECTOR_PCT}/$(escape_sed "$max_sector")/g" \
  -e "s/{MAX_CRYPTO_PCT}/$(escape_sed "$max_crypto")/g" \
  -e "s/{REBALANCE}/$(escape_sed "$rebalance")/g" \
  "$template_path" > "$out_prompt_path"

if grep -Eq '\{[A-Z_]+\}' "$out_prompt_path"; then
  echo "Unresolved placeholders remain in ${out_prompt_path}" >&2
  exit 1
fi

prev_output_path=""
prev_output_date=""
days_since_previous="N/A"
previous_portfolio_json='[]'
previous_trade_json='{}'
rebalance_due="true"
min_rebalance_days="$(minimum_days_between_rebalances "$rebalance")"

IFS=$'\t' read -r prev_output_path prev_output_date < <(latest_successful_output_before_run "$fund_id" "$provider" "$run_date")
if [[ -n "$prev_output_path" && -f "$prev_output_path" ]]; then
  previous_portfolio_json="$(jq -c '.target_portfolio // []' "$prev_output_path")"
  previous_trade_json="$(jq -c '.trade_of_the_day // {}' "$prev_output_path")"
fi

if [[ -n "$prev_output_date" ]]; then
  if days_candidate="$(days_between_dates "$prev_output_date" "$run_date" 2>/dev/null)"; then
    days_since_previous="$days_candidate"
    if [[ "$min_rebalance_days" -gt 0 && "$days_candidate" -lt "$min_rebalance_days" ]]; then
      rebalance_due="false"
    fi
  fi
fi

last7_summary_json="$(build_last7_summary_json "$fund_id" "$provider" "$run_date")"

cat >> "$out_prompt_path" <<EOF

Stateful rebalance context (system-provided):
- Prior successful run date: ${prev_output_date:-NONE}
- Days since prior successful run: ${days_since_previous}
- Rebalance due today: ${rebalance_due}
- Rebalance cadence minimum spacing (days): ${min_rebalance_days}
- Prior target_portfolio JSON: ${previous_portfolio_json}
- Prior trade_of_the_day JSON: ${previous_trade_json}
- Last 7-day aggregated context JSON: ${last7_summary_json}

Execution policy:
- Treat prior target_portfolio as the starting portfolio when available.
- If "Rebalance due today" is false, output action "Do nothing" and keep target_portfolio exactly unchanged.
- If "Rebalance due today" is true, make only justified changes and keep turnover efficient.
- On rebalance-due days, use the 7-day aggregated context explicitly when selecting actions and sizing.
- On rebalance-due days, output full action list in \`rebalance_actions\` (can contain multiple actions).
EOF

echo "Rendered prompt: ${out_prompt_path}"
