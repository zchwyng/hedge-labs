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
if [[ "$expected_provider" != "$provider" ]]; then
  echo "Provider mismatch for ${fund_id}: config=${expected_provider}, arg=${provider}" >&2
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

rm -f "$json_path" "$scratchpad_copy_path"

started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
start_epoch="$(date +%s)"

status="success"
reason=""

DEXTER_ROOT="${DEXTER_ROOT:-}" "${repo_root}/scripts/ensure_dexter.sh" >/dev/null

set +e
(
  cd "$repo_root"
  DEXTER_MODEL="$model" \
  DEXTER_PROMPT_FILE="$canonical_prompt" \
  DEXTER_MAX_ITERATIONS="${DEXTER_MAX_ITERATIONS:-10}" \
  bun run scripts/dexter_run_once.ts
) 2>&1 | tee "$stdout_path"
dexter_exit_code="${PIPESTATUS[0]}"
set -e

if [[ "$dexter_exit_code" -ne 0 ]]; then
  status="failed"
  reason="dexter run exited with code ${dexter_exit_code}"

  runner_error="$(grep -Eo 'Error: .*' "$stdout_path" | tail -n 1 | sed -E 's/^Error:[[:space:]]*//' || true)"
  if [[ -n "$runner_error" ]]; then
    reason="$runner_error"
  else
    last_line="$(tail -n 1 "$stdout_path" | tr -d '\r' || true)"
    if [[ -n "$last_line" ]]; then
      reason="$last_line"
    fi
  fi
fi

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

if [[ "$status" == "success" ]]; then
  json_candidate="$(extract_json_from_output "$stdout_path" || true)"
  if [[ -n "$json_candidate" ]] && jq -e . <<<"$json_candidate" >/dev/null 2>&1; then
    printf '%s\n' "$json_candidate" | jq . > "$json_path"
  else
    status="failed"
    reason="stdout did not contain a valid JSON object"
  fi
fi

if [[ "$status" == "success" ]]; then
  if ! jq -e '
    .paper_only == true and
    (.run_date | type == "string") and
    (.fund_name | type == "string") and
    (
      .trade_of_the_day.action == "Add" or
      .trade_of_the_day.action == "Trim" or
      .trade_of_the_day.action == "Replace" or
      .trade_of_the_day.action == "Do nothing"
    ) and
    (.target_portfolio | type == "array") and
    (.constraints_check.max_position_ok | type == "boolean") and
    (.constraints_check.max_sector_ok | type == "boolean")
  ' "$json_path" >/dev/null 2>&1; then
    status="failed"
    reason="JSON schema validation failed"
  fi
fi

latest_scratchpad=""
latest_mtime=0
scratchpad_dir="${repo_root}/.dexter/scratchpad"
for scratch in "$scratchpad_dir"/*.jsonl; do
  [[ -e "$scratch" ]] || continue
  mtime="$(stat -c '%Y' "$scratch" 2>/dev/null || stat -f '%m' "$scratch" 2>/dev/null || echo 0)"
  if ! [[ "$mtime" =~ ^[0-9]+$ ]]; then
    mtime=0
  fi
  if [[ "$mtime" -ge "$start_epoch" && "$mtime" -gt "$latest_mtime" ]]; then
    latest_mtime="$mtime"
    latest_scratchpad="$scratch"
  fi
done

if [[ -n "$latest_scratchpad" ]]; then
  cp "$latest_scratchpad" "$scratchpad_copy_path"
fi

if [[ "$status" == "success" ]]; then
  if [[ ! -f "$scratchpad_copy_path" ]]; then
    status="failed"
    reason="Dexter scratchpad file was not produced"
  else
    fd_calls="$(
      {
        jq -r 'select(.type == "tool_result") | .toolName // empty' "$scratchpad_copy_path" 2>/dev/null \
          | grep -E '^(financial_search|financial_metrics)$' || true
      } | wc -l | tr -d ' '
    )"
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
    grep -Ei '\[[^]]+ API\]|HTTP [0-9]{3}:|rate limit|quota|billing|insufficient|unauthorized|forbidden|invalid api key|timed out|timeout|service unavailable|connection refused|financial_datasets|financial datasets' "$stdout_path" || true
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
