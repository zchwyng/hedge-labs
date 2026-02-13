#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <fund_id> <provider> <run_date> <prompt_file>" >&2
  exit 64
fi

fund_id="$1"
provider="$2"
run_date="$3"
prompt_file="$4"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
config_path="${repo_root}/funds/${fund_id}/fund.config.json"
if [[ ! -f "$config_path" ]]; then
  echo "Missing fund config: $config_path" >&2
  exit 1
fi

if [[ ! -f "$prompt_file" ]]; then
  echo "Missing prompt file: $prompt_file" >&2
  exit 1
fi

expected_provider="$(jq -r '.provider // ""' "$config_path")"
fund_name="$(jq -r '.name // ""' "$config_path")"
model="$(jq -r '.model // "unknown"' "$config_path")"
target_positions="$(jq -r '.positions // 0' "$config_path")"
max_position_pct="$(jq -r '.max_position_pct // 0' "$config_path")"
min_position_pct="$(jq -r '.min_position_pct // 2' "$config_path")"
max_sector_pct="$(jq -r '.max_sector_pct // 0' "$config_path")"
max_crypto_pct="$(jq -r '.max_crypto_pct // 10' "$config_path")"
rebalance_cadence="$(jq -r '.rebalance // "weekly"' "$config_path")"
if [[ "$expected_provider" != "$provider" ]]; then
  echo "Provider mismatch for ${fund_id}: config=${expected_provider}, arg=${provider}" >&2
  exit 1
fi
if ! awk -v min="$min_position_pct" -v max="$max_position_pct" 'BEGIN { exit !(min > 0 && min <= max) }'; then
  echo "Invalid min_position_pct for ${fund_id}: min=${min_position_pct}, max=${max_position_pct}" >&2
  exit 1
fi
if ! awk -v min="$min_position_pct" -v n="$target_positions" 'BEGIN { exit !((min * n) <= 100.0001) }'; then
  echo "Invalid min_position_pct for ${fund_id}: min=${min_position_pct} with positions=${target_positions} exceeds 100%" >&2
  exit 1
fi
if ! awk -v max_crypto="$max_crypto_pct" 'BEGIN { exit !(max_crypto >= 0 && max_crypto <= 100) }'; then
  echo "Invalid max_crypto_pct for ${fund_id}: ${max_crypto_pct}" >&2
  exit 1
fi

run_dir="${repo_root}/funds/${fund_id}/runs/${run_date}/${provider}"
mkdir -p "$run_dir"

latest_successful_output_before_run() {
  local target_fund_id="$1"
  local target_provider="$2"
  local target_run_date="$3"
  local runs_root="${repo_root}/funds/${target_fund_id}/runs"
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

prev_output_path=""
prev_output_date=""
days_since_previous=""
min_rebalance_days="$(minimum_days_between_rebalances "$rebalance_cadence")"
rebalance_due=true

IFS=$'\t' read -r prev_output_path prev_output_date < <(latest_successful_output_before_run "$fund_id" "$provider" "$run_date")
if [[ -n "$prev_output_date" ]]; then
  if days_candidate="$(days_between_dates "$prev_output_date" "$run_date" 2>/dev/null)"; then
    days_since_previous="$days_candidate"
    if [[ "$min_rebalance_days" -gt 0 && "$days_candidate" -lt "$min_rebalance_days" ]]; then
      rebalance_due=false
    fi
  fi
fi

canonical_prompt="${run_dir}/prompt.txt"
resolve_path() {
  local p="$1"
  local d
  d="$(cd "$(dirname "$p")" && pwd -P)"
  printf '%s/%s\n' "$d" "$(basename "$p")"
}

if [[ "$(resolve_path "$prompt_file")" != "$(resolve_path "$canonical_prompt")" ]]; then
  cp "$prompt_file" "$canonical_prompt"
fi

stdout_path="${run_dir}/dexter_stdout.txt"
json_path="${run_dir}/dexter_output.json"
meta_path="${run_dir}/run_meta.json"
scratchpad_copy_path="${run_dir}/scratchpad.jsonl"
scratchpad_dir="${repo_root}/.dexter/scratchpad"

rm -f "$json_path" "$scratchpad_copy_path"

started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
start_epoch="$(date +%s)"

status="success"
reason=""
retry_used=false

DEXTER_ROOT="${DEXTER_ROOT:-}" "${repo_root}/scripts/ensure_dexter.sh" >/dev/null

dexter_exit_code=0

extract_json_from_output() {
  local file_path="$1"
  node - "$file_path" <<'NODE'
const fs = require('node:fs');

function stripCodeFences(text) {
  return text
    .replace(/^```json\s*/i, '')
    .replace(/^```\s*/i, '')
    .replace(/\s*```$/i, '')
    .trim();
}

function parseBalancedJsonObject(text) {
  let inString = false;
  let escaped = false;
  let depth = 0;
  let start = -1;
  let lastParsed = null;

  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];

    if (escaped) {
      escaped = false;
      continue;
    }

    if (ch === '\\') {
      if (inString) escaped = true;
      continue;
    }

    if (ch === '"') {
      inString = !inString;
      continue;
    }

    if (inString) continue;

    if (ch === '{') {
      if (depth === 0) start = i;
      depth += 1;
      continue;
    }

    if (ch === '}') {
      if (depth > 0) {
        depth -= 1;
        if (depth === 0 && start >= 0) {
          const candidate = text.slice(start, i + 1);
          try {
            lastParsed = JSON.parse(candidate);
          } catch {
            // Continue searching
          }
        }
      }
    }
  }

  return lastParsed;
}

const path = process.argv[2];
const raw = fs.readFileSync(path, 'utf8').trim();
if (!raw) process.exit(1);

try {
  const parsed = JSON.parse(stripCodeFences(raw));
  process.stdout.write(`${JSON.stringify(parsed)}\n`);
  process.exit(0);
} catch {
  const parsed = parseBalancedJsonObject(raw);
  if (!parsed) process.exit(1);
  process.stdout.write(`${JSON.stringify(parsed)}\n`);
}
NODE
}

validate_json_output() {
  local input_json="$1"
  local disallowed_broad_index_etfs_json='["SPY","IVV","VOO","VTI","QQQ","IWM","DIA","VT","ACWI","EFA","EEM","VEA","IEFA","IEMG"]'
  if ! jq -e \
    --arg expected_run_date "$run_date" \
    --arg expected_fund_name "$fund_name" \
    '
    def norm_str:
      tostring
      | gsub("\\s+"; " ")
      | sub("^\\s+"; "")
      | sub("\\s+$"; "");
    .paper_only == true and
    (.run_date | type == "string") and
    (.run_date | norm_str) == $expected_run_date and
    (.fund_name | type == "string") and
    (.fund_name | norm_str) == $expected_fund_name and
    (.trade_of_the_day | type == "object") and
    (.rebalance_actions | type == "array") and
    (
      all(
        .rebalance_actions[]?;
        (.action == "Add" or .action == "Trim" or .action == "Replace" or .action == "Do nothing") and
        (.size_change_pct | type == "number") and
        (.size_change_pct >= 0) and
        (
          if .action == "Add" then
            (
              (.add_ticker | type == "string" and length > 0 and (ascii_upcase != "UNKNOWN")) and
              ((.remove_ticker // null) == null or (.remove_ticker | type == "string" and length == 0))
            )
          elif .action == "Trim" or .action == "Replace" then
            (
              (.add_ticker | type == "string" and length > 0 and (ascii_upcase != "UNKNOWN")) and
              (.remove_ticker | type == "string" and length > 0 and (ascii_upcase != "UNKNOWN")) and
              ((.remove_ticker | ascii_upcase) != (.add_ticker | ascii_upcase))
            )
          else
            true
          end
        )
      )
    ) and
    (
      .trade_of_the_day.action == "Add" or
      .trade_of_the_day.action == "Trim" or
      .trade_of_the_day.action == "Replace" or
      .trade_of_the_day.action == "Do nothing"
    ) and
    (
      if .trade_of_the_day.action == "Add" then
        (.trade_of_the_day.add_ticker | type == "string" and length > 0 and (ascii_upcase != "UNKNOWN"))
      elif .trade_of_the_day.action == "Trim" then
        (
          (.trade_of_the_day.remove_ticker | type == "string" and length > 0 and (ascii_upcase != "UNKNOWN")) and
          (.trade_of_the_day.add_ticker | type == "string" and length > 0 and (ascii_upcase != "UNKNOWN")) and
          ((.trade_of_the_day.remove_ticker | ascii_upcase) != (.trade_of_the_day.add_ticker | ascii_upcase))
        )
      elif .trade_of_the_day.action == "Replace" then
        (
          (.trade_of_the_day.add_ticker | type == "string" and length > 0 and (ascii_upcase != "UNKNOWN")) and
          (.trade_of_the_day.remove_ticker | type == "string" and length > 0 and (ascii_upcase != "UNKNOWN")) and
          ((.trade_of_the_day.remove_ticker | ascii_upcase) != (.trade_of_the_day.add_ticker | ascii_upcase))
        )
      else
        true
      end
    ) and
    (.target_portfolio | type == "array" and length > 0) and
    (
      all(
        .target_portfolio[]?;
        (.ticker | type == "string") and
        ((.ticker | ascii_upcase) != "UNKNOWN") and
        (.weight_pct | type == "number")
      )
    ) and
    (.constraints_check.max_position_ok == true) and
    (.constraints_check.max_sector_ok == true) and
    (.constraints_check.max_crypto_ok == true)
  ' "$input_json" >/dev/null 2>&1; then
    reason="JSON validation failed (schema or risk constraints)"
    return 1
  fi

  if ! jq -e \
    --arg expected_run_date "$run_date" \
    --arg expected_fund_name "$fund_name" \
    --argjson expected_positions "$target_positions" \
    --argjson min_position "$min_position_pct" \
    --argjson max_position "$max_position_pct" \
    --argjson max_sector "$max_sector_pct" \
    --argjson max_crypto "$max_crypto_pct" \
    --argjson disallowed_broad_index_etfs "$disallowed_broad_index_etfs_json" \
    --argjson crypto_etfs '[
      "IBIT","FBTC","GBTC","ARKB","BITB","HODL","BTCO","BRRR","EZBC","BTCW","BITO",
      "ETHA","ETHE","FETH","ETHW"
    ]' \
    '
      def norm_str:
        tostring
        | gsub("\\s+"; " ")
        | sub("^\\s+"; "")
        | sub("\\s+$"; "");
      def sector_key:
        (.sector | norm_str | ascii_upcase | gsub("[^A-Z0-9]+"; ""));
      def is_crypto:
        (
          ((.sector | norm_str | ascii_upcase) | contains("CRYPTO"))
          or
          ((.ticker | ascii_upcase) | test("-(USD|USDT)$"))
          or
          (($crypto_etfs | index((.ticker | ascii_upcase))) != null)
          or
          ((.ticker | ascii_upcase) | test("(BTC|ETH)"))
        );
      (.run_date | norm_str) == $expected_run_date and
      (.fund_name | norm_str) == $expected_fund_name and
      (.target_portfolio | length == $expected_positions) and
      (
        all(
          .target_portfolio[];
          (.ticker | type == "string") and
          ((.ticker | ascii_upcase) != "UNKNOWN") and
          ((.ticker | ascii_upcase) != "CASH") and
          (.sector | type == "string") and
          ((.sector | ascii_upcase) != "UNKNOWN") and
          (.weight_pct | type == "number") and
          (.weight_pct >= ($min_position - 0.0001)) and
          (.weight_pct <= ($max_position + 0.0001))
        )
      ) and
      (
        all(
          .target_portfolio[];
          (.ticker | ascii_upcase) as $ticker
          | ($disallowed_broad_index_etfs | index($ticker) | not)
        )
      ) and
      (
        [ .target_portfolio[].ticker | ascii_upcase ] as $tickers
        | ($tickers | length) == ($tickers | unique | length)
      ) and
      (
        (.target_portfolio | map(.weight_pct) | add) as $total_weight
        | ($total_weight >= 99.5 and $total_weight <= 100.5)
      ) and
      (
        .target_portfolio
        | sort_by(sector_key)
        | group_by(sector_key)
        | map(map(.weight_pct) | add)
        | all(. <= ($max_sector + 0.0001))
      ) and
      (
        ([ .target_portfolio[]
          | select(is_crypto)
          | .weight_pct
        ] | add) as $crypto_weight
        | (($crypto_weight // 0) <= ($max_crypto + 0.0001))
      )
    ' "$input_json" >/dev/null 2>&1; then
    reason="Portfolio validation failed (positions, weights, sector, or crypto limits)"
    return 1
  fi

  return 0
}

validate_rebalance_policy() {
  local input_json="$1"

  if [[ -z "${prev_output_path:-}" || ! -f "${prev_output_path}" ]]; then
    return 0
  fi

  local policy_error=""
  if ! policy_error="$(
    node - "$prev_output_path" "$input_json" "$rebalance_due" <<'NODE'
const fs = require('node:fs');

const prevPath = process.argv[2];
const currPath = process.argv[3];
const rebalanceDue = String(process.argv[4] || '').toLowerCase() === 'true';
const tolerance = 0.01;

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, 'utf8'));
}

function asMap(portfolio) {
  const map = new Map();
  for (const item of portfolio || []) {
    if (!item || typeof item.ticker !== 'string') continue;
    const ticker = item.ticker.trim().toUpperCase();
    const weight = Number(item.weight_pct || 0);
    if (!ticker || !Number.isFinite(weight)) continue;
    map.set(ticker, weight);
  }
  return map;
}

function getWeight(map, ticker) {
  if (!ticker) return 0;
  return map.get(ticker) ?? 0;
}

function approxEqual(a, b) {
  return Math.abs(a - b) <= tolerance;
}

function fail(message) {
  process.stdout.write(`${message}\n`);
  process.exit(1);
}

let prev;
let curr;
try {
  prev = readJson(prevPath);
  curr = readJson(currPath);
} catch {
  fail('Failed to parse portfolio state for rebalance policy validation.');
}

const prevMap = asMap(prev?.target_portfolio || []);
const currMap = asMap(curr?.target_portfolio || []);
const keys = [...new Set([...prevMap.keys(), ...currMap.keys()])];
const changedTickers = keys.filter((ticker) => !approxEqual(getWeight(prevMap, ticker), getWeight(currMap, ticker)));
const samePortfolio = changedTickers.length === 0;

const action = String(curr?.trade_of_the_day?.action || '').trim();
const addTicker = String(curr?.trade_of_the_day?.add_ticker || '').trim().toUpperCase();
const removeTicker = String(curr?.trade_of_the_day?.remove_ticker || '').trim().toUpperCase();
const rebalanceActions = Array.isArray(curr?.rebalance_actions) ? curr.rebalance_actions : [];
const actionfulRebalanceActions = rebalanceActions.filter(
  (a) => String(a?.action || '').trim() !== 'Do nothing'
);
const deltaByTicker = new Map(
  keys.map((ticker) => [ticker, getWeight(currMap, ticker) - getWeight(prevMap, ticker)])
);

function increased(ticker) {
  return (deltaByTicker.get(String(ticker || '').toUpperCase()) || 0) > tolerance;
}

function decreased(ticker) {
  return (deltaByTicker.get(String(ticker || '').toUpperCase()) || 0) < -tolerance;
}

if (!rebalanceDue) {
  if (action !== 'Do nothing') {
    fail('Rebalance cadence not due yet: action must be "Do nothing".');
  }
  if (!samePortfolio) {
    fail('Rebalance cadence not due yet: target_portfolio must remain unchanged.');
  }
  if (actionfulRebalanceActions.length > 0) {
    fail('Rebalance cadence not due yet: rebalance_actions must be empty (or only "Do nothing").');
  }
  process.exit(0);
}

if (action === 'Do nothing') {
  if (!samePortfolio) {
    fail('Action "Do nothing" requires an unchanged target_portfolio.');
  }
  if (actionfulRebalanceActions.length > 0) {
    fail('When headline action is "Do nothing", rebalance_actions cannot include active trades.');
  }
  process.exit(0);
}

if (samePortfolio) {
  fail(`Action "${action}" requires at least one portfolio weight change.`);
}

if (actionfulRebalanceActions.length === 0) {
  fail('Rebalance due today with portfolio changes: rebalance_actions must include at least one active action.');
}

if (action === 'Add') {
  if (!addTicker) {
    fail('Action "Add" requires add_ticker.');
  }
  if (removeTicker) {
    fail('Action "Add" must not set remove_ticker.');
  }
  if (!increased(addTicker)) {
    fail('Action "Add" requires add_ticker weight to increase vs prior portfolio.');
  }
  process.exit(0);
}

if (action === 'Trim') {
  if (!addTicker || !removeTicker) {
    fail('Action "Trim" requires both add_ticker and remove_ticker.');
  }
  if (!decreased(removeTicker)) {
    fail('Action "Trim" requires remove_ticker weight to decrease vs prior portfolio.');
  }
  if (!increased(addTicker)) {
    fail('Action "Trim" requires add_ticker weight to increase vs prior portfolio.');
  }
}

if (action === 'Replace') {
  if (!addTicker || !removeTicker) {
    fail('Action "Replace" requires both add_ticker and remove_ticker.');
  }
  if (!decreased(removeTicker)) {
    fail('Action "Replace" requires remove_ticker weight to decrease vs prior portfolio.');
  }
  if (!increased(addTicker)) {
    fail('Action "Replace" requires add_ticker weight to increase vs prior portfolio.');
  }
}

for (const rawAction of actionfulRebalanceActions) {
  const actionType = String(rawAction?.action || '').trim();
  const actionAdd = String(rawAction?.add_ticker || '').trim().toUpperCase();
  const actionRemove = String(rawAction?.remove_ticker || '').trim().toUpperCase();
  if (actionType === 'Add') {
    if (!actionAdd || !increased(actionAdd)) {
      fail(`rebalance_actions Add is not reflected in portfolio deltas for ticker ${actionAdd || 'UNKNOWN'}.`);
    }
    continue;
  }
  if (actionType === 'Trim' || actionType === 'Replace') {
    if (!actionAdd || !actionRemove) {
      fail(`rebalance_actions ${actionType} requires add_ticker and remove_ticker.`);
    }
    if (!decreased(actionRemove)) {
      fail(`rebalance_actions ${actionType} requires remove_ticker ${actionRemove} to decrease vs prior portfolio.`);
    }
    if (!increased(actionAdd)) {
      fail(`rebalance_actions ${actionType} requires add_ticker ${actionAdd} to increase vs prior portfolio.`);
    }
    continue;
  }
}

if (action !== 'Add' && action !== 'Trim' && action !== 'Replace') {
  fail(`Unsupported trade_of_the_day.action for rebalance policy validation: "${action}"`);
}
NODE
  )"; then
    reason="Rebalance policy validation failed: ${policy_error:-Unknown policy violation}"
    return 1
  fi

  return 0
}

rebalance_portfolio_if_possible() {
  local input_json="$1"
  node - "$input_json" "$target_positions" "$min_position_pct" "$max_position_pct" "$max_sector_pct" <<'NODE'
const fs = require('node:fs');

const [, , jsonPath, expectedPositionsRaw, minPositionRaw, maxPositionRaw, maxSectorRaw] = process.argv;
const expectedPositions = Number(expectedPositionsRaw);
const minPosition = Number(minPositionRaw);
const maxPosition = Number(maxPositionRaw);
const maxSector = Number(maxSectorRaw);
const targetTotalBp = 10000;
const minWeightBp = Math.round(minPosition * 100);
const maxPositionBp = Math.floor(maxPosition * 100 + 1e-6);
const maxSectorBp = Math.floor(maxSector * 100 + 1e-6);

if (!Number.isFinite(expectedPositions) || expectedPositions <= 0) process.exit(1);
if (!Number.isFinite(minWeightBp) || minWeightBp <= 0) process.exit(1);
if (!Number.isFinite(maxPositionBp) || maxPositionBp < minWeightBp) process.exit(1);
if (!Number.isFinite(maxSectorBp) || maxSectorBp < minWeightBp) process.exit(1);

let doc;
try {
  doc = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
} catch {
  process.exit(1);
}

if (!doc || !Array.isArray(doc.target_portfolio) || doc.target_portfolio.length !== expectedPositions) {
  process.exit(1);
}

const portfolio = doc.target_portfolio;
const tickers = new Set();
const sectors = [];
const weightsBp = [];

for (const item of portfolio) {
  if (!item || typeof item.ticker !== 'string' || typeof item.sector !== 'string') process.exit(1);
  const ticker = item.ticker.trim().toUpperCase();
  const sector = item.sector.trim();
  const rawWeight = Number(item.weight_pct);
  if (!ticker || ticker === 'UNKNOWN' || ticker === 'CASH' || tickers.has(ticker)) process.exit(1);
  if (!sector || sector.toUpperCase() === 'UNKNOWN') process.exit(1);
  if (!Number.isFinite(rawWeight) || rawWeight <= 0) process.exit(1);
  tickers.add(ticker);
  sectors.push(sector);
  weightsBp.push(Math.max(minWeightBp, Math.round(rawWeight * 100)));
}

const buildSectorSums = () => {
  const sums = new Map();
  for (let i = 0; i < weightsBp.length; i += 1) {
    sums.set(sectors[i], (sums.get(sectors[i]) ?? 0) + weightsBp[i]);
  }
  return sums;
};

const distribute = (amount) => {
  let remaining = amount;
  let guard = 0;
  while (remaining > 0 && guard < 20000) {
    guard += 1;
    const sectorSums = buildSectorSums();
    let bestIndex = -1;
    let bestRoom = 0;
    for (let i = 0; i < weightsBp.length; i += 1) {
      const posRoom = maxPositionBp - weightsBp[i];
      const sectorRoom = maxSectorBp - (sectorSums.get(sectors[i]) ?? 0);
      const room = Math.min(posRoom, sectorRoom);
      if (room > bestRoom) {
        bestRoom = room;
        bestIndex = i;
      }
    }
    if (bestIndex < 0 || bestRoom <= 0) return false;
    const add = Math.min(remaining, bestRoom);
    weightsBp[bestIndex] += add;
    remaining -= add;
  }
  return remaining === 0;
};

const removeOverweightSectors = () => {
  const sectorSums = buildSectorSums();
  let moved = 0;
  const overSectors = [...sectorSums.keys()].sort().filter((sector) => (sectorSums.get(sector) ?? 0) > maxSectorBp);
  for (const sector of overSectors) {
    let excess = (sectorSums.get(sector) ?? 0) - maxSectorBp;
    const indices = weightsBp
      .map((weight, i) => ({ i, weight, ticker: String(portfolio[i].ticker).toUpperCase() }))
      .filter((entry) => sectors[entry.i] === sector)
      .sort((a, b) => {
        if (b.weight !== a.weight) return b.weight - a.weight;
        return a.ticker.localeCompare(b.ticker);
      })
      .map((entry) => entry.i);

    for (const idx of indices) {
      if (excess <= 0) break;
      const removable = weightsBp[idx] - minWeightBp;
      if (removable <= 0) continue;
      const cut = Math.min(removable, excess);
      weightsBp[idx] -= cut;
      excess -= cut;
      moved += cut;
    }
    if (excess > 0) return null;
  }
  return moved;
};

for (let i = 0; i < weightsBp.length; i += 1) {
  if (weightsBp[i] > maxPositionBp) {
    weightsBp[i] = maxPositionBp;
  }
}

let currentTotal = weightsBp.reduce((sum, v) => sum + v, 0);
if (currentTotal > targetTotalBp) {
  let needRemove = currentTotal - targetTotalBp;
  const sorted = weightsBp
    .map((w, i) => ({ i, w }))
    .sort((a, b) => b.w - a.w)
    .map((entry) => entry.i);
  for (const idx of sorted) {
    if (needRemove <= 0) break;
    const removable = weightsBp[idx] - minWeightBp;
    if (removable <= 0) continue;
    const cut = Math.min(removable, needRemove);
    weightsBp[idx] -= cut;
    needRemove -= cut;
  }
  if (needRemove > 0) process.exit(1);
} else if (currentTotal < targetTotalBp) {
  if (!distribute(targetTotalBp - currentTotal)) process.exit(1);
}

for (let iter = 0; iter < 12; iter += 1) {
  const moved = removeOverweightSectors();
  if (moved === null) process.exit(1);
  if (moved === 0) break;
  if (!distribute(moved)) process.exit(1);
}

currentTotal = weightsBp.reduce((sum, v) => sum + v, 0);
if (currentTotal < targetTotalBp) {
  if (!distribute(targetTotalBp - currentTotal)) process.exit(1);
} else if (currentTotal > targetTotalBp) {
  let needRemove = currentTotal - targetTotalBp;
  const sorted = weightsBp
    .map((w, i) => ({ i, w }))
    .sort((a, b) => b.w - a.w)
    .map((entry) => entry.i);
  for (const idx of sorted) {
    if (needRemove <= 0) break;
    const removable = weightsBp[idx] - minWeightBp;
    if (removable <= 0) continue;
    const cut = Math.min(removable, needRemove);
    weightsBp[idx] -= cut;
    needRemove -= cut;
  }
  if (needRemove > 0) process.exit(1);
}

const finalSectorSums = buildSectorSums();
for (const sum of finalSectorSums.values()) {
  if (sum > maxSectorBp) process.exit(1);
}
for (const weight of weightsBp) {
  if (weight < minWeightBp || weight > maxPositionBp) process.exit(1);
}
if (weightsBp.reduce((sum, v) => sum + v, 0) !== targetTotalBp) process.exit(1);

for (let i = 0; i < portfolio.length; i += 1) {
  portfolio[i].weight_pct = Number((weightsBp[i] / 100).toFixed(2));
}
doc.constraints_check = {
  max_position_ok: true,
  max_sector_ok: true,
  max_crypto_ok: true,
  notes: "Weights were deterministically rebalanced to satisfy position and sector constraints."
};

fs.writeFileSync(jsonPath, `${JSON.stringify(doc, null, 2)}\n`);
NODE
}

attempt_rebalance_if_needed() {
  if [[ "$status" != "failed" ]]; then
    return 1
  fi

  if [[ "$reason" != "Portfolio validation failed (positions, weights, sector, or crypto limits)" ]]; then
    return 1
  fi

  if [[ ! -f "$json_path" ]]; then
    return 1
  fi

  if ! rebalance_portfolio_if_possible "$json_path"; then
    return 1
  fi

  if ! validate_json_output "$json_path"; then
    return 1
  fi
  if ! validate_rebalance_policy "$json_path"; then
    return 1
  fi

  status="success"
  reason=""
  echo "Auto-corrected portfolio weights to satisfy deterministic constraints." | tee -a "$stdout_path"
  return 0
}

run_dexter_attempt() {
  local prompt_path="$1"
  rm -f "$json_path"
  status="success"
  reason=""

  set +e
  (
    cd "$repo_root"
    DEXTER_MODEL="$model" \
    DEXTER_PROMPT_FILE="$prompt_path" \
    DEXTER_MAX_ITERATIONS="${DEXTER_MAX_ITERATIONS:-10}" \
    bash -lc '
      if command -v timeout >/dev/null 2>&1; then
        timeout "${DEXTER_TIMEOUT_SECONDS:-900}" bun run scripts/dexter_run_once.ts
      else
        bun run scripts/dexter_run_once.ts
      fi
    '
  ) 2>&1 | tee "$stdout_path"
  dexter_exit_code="${PIPESTATUS[0]}"
  set -e

  if [[ "$dexter_exit_code" -ne 0 ]]; then
    status="failed"
    if [[ "$dexter_exit_code" -eq 124 ]]; then
      reason="dexter run timed out after ${DEXTER_TIMEOUT_SECONDS:-900}s"
    else
      reason="dexter run exited with code ${dexter_exit_code}"
    fi

    runner_error="$(grep -Eo 'Error: .*' "$stdout_path" | tail -n 1 | sed -E 's/^Error:[[:space:]]*//' || true)"
    if [[ -n "$runner_error" ]]; then
      reason="$runner_error"
    else
      last_line="$(tail -n 1 "$stdout_path" | tr -d '\r' || true)"
      if [[ -n "$last_line" ]]; then
        reason="$last_line"
      fi
    fi
    return
  fi

  json_candidate="$(extract_json_from_output "$stdout_path" || true)"
  if [[ -n "$json_candidate" ]] && jq -e . <<<"$json_candidate" >/dev/null 2>&1; then
    printf '%s\n' "$json_candidate" | jq . > "$json_path"
  else
    status="failed"
    reason="stdout did not contain a valid JSON object"
    return
  fi

  if ! validate_json_output "$json_path"; then
    status="failed"
    return
  fi
  if ! validate_rebalance_policy "$json_path"; then
    status="failed"
    return
  fi
}

run_dexter_attempt "$canonical_prompt"
attempt_rebalance_if_needed || true

if [[ "$status" == "failed" && ( "$reason" == "JSON validation failed (schema or risk constraints)" || "$reason" == "Portfolio validation failed (positions, weights, sector, or crypto limits)" || "$reason" == "stdout did not contain a valid JSON object" || "$reason" == Rebalance\ policy\ validation\ failed:* ) ]]; then
  retry_used=true
  retry_prompt="${run_dir}/prompt.retry.txt"
  previous_output="$(cat "$json_path" 2>/dev/null || echo '{}')"
  previous_portfolio_for_retry='[]'
  if [[ -n "${prev_output_path:-}" && -f "${prev_output_path}" ]]; then
    previous_portfolio_for_retry="$(jq -c '.target_portfolio // []' "$prev_output_path")"
  fi
  cat > "$retry_prompt" <<EOF
Your previous response failed deterministic validation. Fix it and return ONLY one valid JSON object.

Validation requirements:
- target_portfolio must contain exactly ${target_positions} holdings.
- No CASH, UNKNOWN, or duplicate tickers. Equities, ETFs, and major crypto assets are allowed.
- Broad index ETFs are not allowed (e.g., SPY, IVV, VOO, VTI, QQQ, IWM, DIA, VT, ACWI, EFA, EEM).
- Each weight_pct must be >= ${min_position_pct} and <= ${max_position_pct}.
- Total weight must be 100% (acceptable range 99.5-100.5).
- Any single sector total must be <= ${max_sector_pct}.
- Crypto exposure must be <= ${max_crypto_pct}%.
- If action is "Trim", both remove_ticker and add_ticker are required (paired reallocation).
- If action is "Replace", both remove_ticker and add_ticker are required.
- \`rebalance_actions\` must be an array and include the full action set for this run (empty only when no rebalance activity).
- constraints_check.max_position_ok, constraints_check.max_sector_ok, and constraints_check.max_crypto_ok must all be true and consistent with your portfolio.
- Rebalance cadence: ${rebalance_cadence}. Rebalance due today: ${rebalance_due}. Minimum spacing: ${min_rebalance_days} days.
- If rebalance is not due, action must be "Do nothing" and target_portfolio must exactly match the prior portfolio.

Previous failure reason:
${reason}

Prior portfolio (previous successful run):
${previous_portfolio_for_retry}

Previous invalid output:
${previous_output}

Original assignment:
$(cat "$canonical_prompt")
EOF
  run_dexter_attempt "$retry_prompt"
  attempt_rebalance_if_needed || true
  rm -f "$retry_prompt"
  if [[ "$status" == "failed" ]]; then
    reason="Retry failed: ${reason}"
  fi
fi

scratchpad_mtime() {
  local scratch="$1"
  local mtime
  mtime="$(stat -c '%Y' "$scratch" 2>/dev/null || stat -f '%m' "$scratch" 2>/dev/null || echo 0)"
  if ! [[ "$mtime" =~ ^[0-9]+$ ]]; then
    mtime=0
  fi
  printf '%s\n' "$mtime"
}

copy_latest_scratchpad_since_start() {
  latest_scratchpad=""
  latest_mtime=0
  for scratch in "$scratchpad_dir"/*.jsonl; do
    [[ -e "$scratch" ]] || continue
    mtime="$(scratchpad_mtime "$scratch")"
    if [[ "$mtime" -ge "$start_epoch" && "$mtime" -gt "$latest_mtime" ]]; then
      latest_mtime="$mtime"
      latest_scratchpad="$scratch"
    fi
  done
  if [[ -n "$latest_scratchpad" ]]; then
    cp "$latest_scratchpad" "$scratchpad_copy_path"
  fi
}

count_fd_tool_calls_since_start() {
  local required_tool="$1"
  if [[ -f "$scratchpad_copy_path" ]]; then
    local count
    count="$(
      {
        jq -r 'select(.type == "tool_result") | .toolName // empty' "$scratchpad_copy_path" 2>/dev/null \
          | grep -E "^${required_tool}$" || true
      } | wc -l | tr -d ' '
    )"
    printf '%s\n' "$count"
    return 0
  fi
  local total=0
  local count=0
  local scratch=""
  local mtime=0
  for scratch in "$scratchpad_dir"/*.jsonl; do
    [[ -e "$scratch" ]] || continue
    mtime="$(scratchpad_mtime "$scratch")"
    [[ "$mtime" -ge "$start_epoch" ]] || continue
    count="$(
      {
        jq -r 'select(.type == "tool_result") | .toolName // empty' "$scratch" 2>/dev/null \
          | grep -E "^${required_tool}$" || true
      } | wc -l | tr -d ' '
    )"
    if [[ "$count" =~ ^[0-9]+$ ]]; then
      total=$((total + count))
    fi
  done
  printf '%s\n' "$total"
}

count_fd_source_urls_since_start() {
  if [[ -f "$scratchpad_copy_path" ]]; then
    jq -rs '
      def is_fd_tool_result:
        .type == "tool_result" and ((.toolName == "financial_search") or (.toolName == "financial_metrics"));
      def source_url_count:
        [
          .result.sourceUrls?,
          .result.source_urls?,
          .result.data.sourceUrls?,
          .result.data.source_urls?
        ]
        | map(
            if type == "array" then .[]
            elif type == "string" then .
            else empty
            end
          )
        | length;
      [ .[] | select(is_fd_tool_result) | source_url_count ] | add // 0
    ' "$scratchpad_copy_path" 2>/dev/null || echo 0
    return 0
  fi
  local total=0
  local count=0
  local scratch=""
  local mtime=0
  for scratch in "$scratchpad_dir"/*.jsonl; do
    [[ -e "$scratch" ]] || continue
    mtime="$(scratchpad_mtime "$scratch")"
    [[ "$mtime" -ge "$start_epoch" ]] || continue
    count="$(
      jq -rs '
        def is_fd_tool_result:
          .type == "tool_result" and ((.toolName == "financial_search") or (.toolName == "financial_metrics"));
        def source_url_count:
          [
            .result.sourceUrls?,
            .result.source_urls?,
            .result.data.sourceUrls?,
            .result.data.source_urls?
          ]
          | map(
              if type == "array" then .[]
              elif type == "string" then .
              else empty
              end
            )
          | length;
        [ .[] | select(is_fd_tool_result) | source_url_count ] | add // 0
      ' "$scratch" 2>/dev/null || echo 0
    )"
    if [[ "$count" =~ ^[0-9]+$ ]]; then
      total=$((total + count))
    fi
  done
  printf '%s\n' "$total"
}

count_fd_errors_since_start() {
  if [[ -f "$scratchpad_copy_path" ]]; then
    jq -rs '
      def is_fd_tool_result:
        .type == "tool_result" and ((.toolName == "financial_search") or (.toolName == "financial_metrics"));
      def error_count:
        [
          .result.data._errors?,
          .result._errors?,
          .result.data.errors?,
          .result.errors?
        ]
        | map(
            if type == "array" then .[]
            elif . == null then empty
            else .
            end
          )
        | length;
      [ .[] | select(is_fd_tool_result) | error_count ] | add // 0
    ' "$scratchpad_copy_path" 2>/dev/null || echo 0
    return 0
  fi
  local total=0
  local count=0
  local scratch=""
  local mtime=0
  for scratch in "$scratchpad_dir"/*.jsonl; do
    [[ -e "$scratch" ]] || continue
    mtime="$(scratchpad_mtime "$scratch")"
    [[ "$mtime" -ge "$start_epoch" ]] || continue
    count="$(
      jq -rs '
        def is_fd_tool_result:
          .type == "tool_result" and ((.toolName == "financial_search") or (.toolName == "financial_metrics"));
        def error_count:
          [
            .result.data._errors?,
            .result._errors?,
            .result.data.errors?,
            .result.errors?
          ]
          | map(
              if type == "array" then .[]
              elif . == null then empty
              else .
              end
            )
          | length;
        [ .[] | select(is_fd_tool_result) | error_count ] | add // 0
      ' "$scratch" 2>/dev/null || echo 0
    )"
    if [[ "$count" =~ ^[0-9]+$ ]]; then
      total=$((total + count))
    fi
  done
  printf '%s\n' "$total"
}

copy_latest_scratchpad_since_start

if [[ "$status" == "success" ]]; then
  if [[ ! -f "$scratchpad_copy_path" ]]; then
    status="failed"
    reason="Dexter scratchpad file was not produced"
  else
    fd_search_calls="$(count_fd_tool_calls_since_start "financial_search")"
    if [[ "$fd_search_calls" == "0" ]]; then
      tool_retry_prompt="${run_dir}/prompt.tools.retry.txt"
      cat > "$tool_retry_prompt" <<EOF
Tool-use requirement was not met in your previous response.

Before finalizing your JSON:
1) Call \`financial_search\` at least once to gather verifiable market/news/company context.
2) Then return ONLY one valid JSON object matching all assignment constraints.
3) Ensure data quality: provide enough successful source coverage and avoid unresolved API-error-heavy output.
4) If rebalance is due, provide full action list in \`rebalance_actions\`; if not due, set \`rebalance_actions\` to [].

Failure to call the required \`financial_search\` tool is treated as a failed run.

Original assignment:
$(cat "$canonical_prompt")
EOF
      run_dexter_attempt "$tool_retry_prompt"
      attempt_rebalance_if_needed || true
      rm -f "$tool_retry_prompt"
      if [[ "$status" == "failed" ]]; then
        reason="Retry failed: ${reason}"
      fi
      copy_latest_scratchpad_since_start
    fi
  fi
fi

if [[ "$status" == "success" ]]; then
  if [[ ! -f "$scratchpad_copy_path" ]]; then
    status="failed"
    reason="Dexter scratchpad file was not produced"
  else
    fd_search_calls="$(count_fd_tool_calls_since_start "financial_search")"
    if [[ "$fd_search_calls" == "0" ]]; then
      status="failed"
      reason="Dexter did not call required Financial Datasets tool (financial_search)"
    else
      fd_source_urls="$(count_fd_source_urls_since_start)"
      fd_errors="$(count_fd_errors_since_start)"
      fd_min_source_urls="${FD_MIN_SOURCE_URLS:-6}"
      fd_max_error_ratio="${FD_MAX_ERROR_RATIO:-0.35}"
      fd_error_ratio="$(awk -v e="$fd_errors" -v s="$fd_source_urls" 'BEGIN { d=e+s; if (d <= 0) printf "1.000000"; else printf "%.6f", (e/d) }')"
      if awk -v s="$fd_source_urls" -v min="$fd_min_source_urls" 'BEGIN { exit !(s < min) }'; then
        status="failed"
        reason="Insufficient Financial Datasets source coverage (${fd_source_urls} successful source URLs; required >= ${fd_min_source_urls})"
      elif awk -v r="$fd_error_ratio" -v max="$fd_max_error_ratio" 'BEGIN { exit !(r > max) }'; then
        status="failed"
        reason="Financial Datasets error ratio too high (ratio=${fd_error_ratio}, errors=${fd_errors}, sources=${fd_source_urls}, max=${fd_max_error_ratio})"
      fi
    fi
  fi
fi

ended_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [[ "$status" == "success" ]]; then
  exit_code=0
else
  exit_code=1
fi

api_errors_json='[]'
if [[ -f "$stdout_path" ]]; then
  api_lines="$({
    grep -Ei '^\[[^]]+ API\]|^Error:|HTTP [0-9]{3}:|rate limit|quota exceeded|billing|insufficient_(quota|credits|balance)|unauthorized|forbidden|invalid api key|timed out|timeout|service unavailable|connection refused|financial_datasets( api)? error|financial datasets api error' "$stdout_path" || true
    if [[ -n "$reason" ]]; then
      printf '%s\n' "$reason"
    fi
  } | sed -E 's/\r$//; s/[[:space:]]+/ /g; s/^ //; s/ $//' | awk 'length > 0 && !seen[$0]++' | head -n 8)"

  if [[ -n "$api_lines" ]]; then
    api_errors_json="$(printf '%s\n' "$api_lines" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  fi
fi

jq -n \
  --arg fund_id "$fund_id" \
  --arg provider "$provider" \
  --arg model "$model" \
  --arg run_date "$run_date" \
  --arg started_at "$started_at" \
  --arg ended_at "$ended_at" \
  --arg status "$status" \
  --arg reason "$reason" \
  --arg scratchpad_source "$latest_scratchpad" \
  --argjson api_errors "$api_errors_json" \
  --argjson dexter_exit_code "$dexter_exit_code" \
  --argjson scratchpad_found "$( [[ -n "$latest_scratchpad" ]] && echo true || echo false )" \
  '{
    fund_id: $fund_id,
    provider: $provider,
    model: $model,
    run_date: $run_date,
    started_at: $started_at,
    ended_at: $ended_at,
    status: $status,
    reason: $reason,
    api_errors: $api_errors,
    dexter_exit_code: $dexter_exit_code,
    scratchpad_found: $scratchpad_found,
    scratchpad_source: (if $scratchpad_source == "" then null else $scratchpad_source end)
  }' > "$meta_path"

exit "$exit_code"
