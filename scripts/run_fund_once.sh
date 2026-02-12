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

config_path="funds/${fund_id}/fund.config.json"
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

run_dir="funds/${fund_id}/runs/${run_date}/${provider}"
mkdir -p "$run_dir"

canonical_prompt="${run_dir}/prompt.txt"
if [[ "$prompt_file" != "$canonical_prompt" ]]; then
  cp "$prompt_file" "$canonical_prompt"
fi

stdout_path="${run_dir}/dexter_stdout.txt"
json_path="${run_dir}/dexter_output.json"
meta_path="${run_dir}/run_meta.json"
scratchpad_copy_path="${run_dir}/scratchpad.jsonl"

started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
start_epoch="$(date +%s)"

status="success"
reason=""

set +e
bun start < "$canonical_prompt" | tee "$stdout_path"
bun_exit_code="${PIPESTATUS[0]}"
set -e

if [[ "$bun_exit_code" -ne 0 ]]; then
  status="failed"
  reason="bun start exited with code ${bun_exit_code}"
fi

if [[ "$status" == "success" ]]; then
  if jq -e . "$stdout_path" >/dev/null 2>&1; then
    jq . "$stdout_path" > "$json_path"
  else
    status="failed"
    reason="stdout was not valid JSON"
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
for scratch in .dexter/scratchpad/*.jsonl; do
  [[ -e "$scratch" ]] || continue
  mtime="$(stat -f '%m' "$scratch" 2>/dev/null || stat -c '%Y' "$scratch" 2>/dev/null || echo 0)"
  if [[ "$mtime" -ge "$start_epoch" && "$mtime" -gt "$latest_mtime" ]]; then
    latest_mtime="$mtime"
    latest_scratchpad="$scratch"
  fi
done

if [[ -n "$latest_scratchpad" ]]; then
  cp "$latest_scratchpad" "$scratchpad_copy_path"
fi

ended_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [[ "$status" == "success" ]]; then
  exit_code=0
else
  exit_code=1
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
  --argjson bun_exit_code "$bun_exit_code" \
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
    bun_exit_code: $bun_exit_code,
    scratchpad_found: $scratchpad_found,
    scratchpad_source: (if $scratchpad_source == "" then null else $scratchpad_source end)
  }' > "$meta_path"

exit "$exit_code"
