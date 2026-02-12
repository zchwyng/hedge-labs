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
model="$(jq -r '.model // "unknown"' "$config_path")"
target_positions="$(jq -r '.positions // 0' "$config_path")"
max_position_pct="$(jq -r '.max_position_pct // 0' "$config_path")"
min_position_pct="$(jq -r '.min_position_pct // 2' "$config_path")"
max_sector_pct="$(jq -r '.max_sector_pct // 0' "$config_path")"
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

run_dir="${repo_root}/funds/${fund_id}/runs/${run_date}/${provider}"
mkdir -p "$run_dir"

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
  if ! jq -e '
    .paper_only == true and
    (.run_date | type == "string") and
    (.fund_name | type == "string") and
    (.trade_of_the_day | type == "object") and
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
    (.constraints_check.max_sector_ok == true)
  ' "$input_json" >/dev/null 2>&1; then
    reason="JSON validation failed (schema or risk constraints)"
    return 1
  fi

  if ! jq -e \
    --argjson expected_positions "$target_positions" \
    --argjson min_position "$min_position_pct" \
    --argjson max_position "$max_position_pct" \
    --argjson max_sector "$max_sector_pct" \
    '
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
        [ .target_portfolio[].ticker | ascii_upcase ] as $tickers
        | ($tickers | length) == ($tickers | unique | length)
      ) and
      (
        (.target_portfolio | map(.weight_pct) | add) as $total_weight
        | ($total_weight >= 99.5 and $total_weight <= 100.5)
      ) and
      (
        .target_portfolio
        | sort_by(.sector)
        | group_by(.sector)
        | map(map(.weight_pct) | add)
        | all(. <= ($max_sector + 0.0001))
      )
    ' "$input_json" >/dev/null 2>&1; then
    reason="Portfolio validation failed (positions, weights, or sector limits)"
    return 1
  fi

  return 0
}

rebalance_portfolio_if_possible() {
  local input_json="$1"
  node - "$input_json" "$target_positions" "$max_position_pct" "$max_sector_pct" <<'NODE'
const fs = require('node:fs');

const [, , jsonPath, expectedPositionsRaw, maxPositionRaw, maxSectorRaw] = process.argv;
const expectedPositions = Number(expectedPositionsRaw);
const maxPosition = Number(maxPositionRaw);
const maxSector = Number(maxSectorRaw);
const targetTotalBp = 10000;
const minWeightBp = 1;
const maxPositionBp = Math.floor(maxPosition * 100 + 1e-6);
const maxSectorBp = Math.floor(maxSector * 100 + 1e-6);

if (!Number.isFinite(expectedPositions) || expectedPositions <= 0) process.exit(1);
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
  notes: "Weights were deterministically rebalanced to satisfy position and sector constraints."
};

fs.writeFileSync(jsonPath, `${JSON.stringify(doc, null, 2)}\n`);
NODE
}

attempt_rebalance_if_needed() {
  # Do not auto-rewrite portfolio weights here. Invalid constraints should force model retry.
  return 1
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
}

run_dexter_attempt "$canonical_prompt"
attempt_rebalance_if_needed || true

if [[ "$status" == "failed" && ( "$reason" == "JSON validation failed (schema or risk constraints)" || "$reason" == "Portfolio validation failed (positions, weights, or sector limits)" || "$reason" == "stdout did not contain a valid JSON object" ) ]]; then
  retry_used=true
  retry_prompt="${run_dir}/prompt.retry.txt"
  previous_output="$(cat "$json_path" 2>/dev/null || echo '{}')"
  cat > "$retry_prompt" <<EOF
Your previous response failed deterministic validation. Fix it and return ONLY one valid JSON object.

Validation requirements:
- target_portfolio must contain exactly ${target_positions} holdings.
- No CASH, UNKNOWN, duplicate tickers, ETFs, or crypto.
- Each weight_pct must be >= ${min_position_pct} and <= ${max_position_pct}.
- Total weight must be 100% (acceptable range 99.5-100.5).
- Any single sector total must be <= ${max_sector_pct}.
- If action is "Trim", both remove_ticker and add_ticker are required (paired reallocation).
- If action is "Replace", both remove_ticker and add_ticker are required.
- constraints_check.max_position_ok and constraints_check.max_sector_ok must both be true and consistent with your portfolio.

Previous failure reason:
${reason}

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

count_fd_calls_since_start() {
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
          | grep -E '^(financial_search|financial_metrics)$' || true
      } | wc -l | tr -d ' '
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
    fd_calls="$(count_fd_calls_since_start)"
    if [[ "$fd_calls" == "0" ]]; then
      tool_retry_prompt="${run_dir}/prompt.tools.retry.txt"
      cat > "$tool_retry_prompt" <<EOF
Tool-use requirement was not met in your previous response.

Before finalizing your JSON:
1) Call \`financial_search\` at least once to gather verifiable market/news/company context.
2) Call \`financial_metrics\` at least once to validate key financial/valuation metrics for your chosen holdings.
3) Then return ONLY one valid JSON object matching all assignment constraints.

Failure to call both required tools is treated as a failed run.

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
    fd_calls="$(count_fd_calls_since_start)"
    if [[ "$fd_calls" == "0" ]]; then
      status="failed"
      reason="Dexter did not call Financial Datasets tools (financial_search/financial_metrics)"
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
