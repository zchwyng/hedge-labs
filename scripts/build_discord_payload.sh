#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <run_date>" >&2
  exit 64
fi

run_date="$1"
scoreboard_path="funds/arena/runs/${run_date}/scoreboard.json"

if [[ ! -f "$scoreboard_path" ]]; then
  echo "Missing scoreboard: $scoreboard_path" >&2
  exit 1
fi

all_success="$(jq -r '[.lanes[].status == "success"] | all' "$scoreboard_path")"
failed_count="$(jq -r '[.lanes[] | select(.status != "success")] | length' "$scoreboard_path")"

if [[ "$all_success" == "true" ]]; then
  overall_line="Overall: SUCCESS (all lanes completed)"
else
  overall_line="Overall: PARTIAL FAILURE (${failed_count} lane(s) failed)"
fi

message="**Fund Arena Daily - ${run_date}**"
message+=$'\n'
message+="$overall_line"
message+=$'\n'

while IFS= read -r lane; do
  fund_id="$(jq -r '.fund_id' <<<"$lane")"
  provider="$(jq -r '.provider' <<<"$lane")"
  status="$(jq -r '.status' <<<"$lane")"
  action="$(jq -r '.action' <<<"$lane")"
  add_ticker="$(jq -r '.add_ticker // "-"' <<<"$lane")"
  remove_ticker="$(jq -r '.remove_ticker // "-"' <<<"$lane")"
  constraints_ok="$(jq -r '.constraints_ok' <<<"$lane")"
  run_path="$(jq -r '.run_path' <<<"$lane")"

  if [[ "$status" == "success" ]]; then
    status_label="SUCCESS"
  else
    status_label="FAILED"
  fi

  if [[ "$constraints_ok" == "true" ]]; then
    constraints_label="OK"
  else
    constraints_label="FAIL"
  fi

  risk_snippet="n/a"
  output_path="${run_path}/dexter_output.json"
  if [[ -f "$output_path" ]]; then
    risk_snippet="$(jq -r '(.trade_of_the_day.risks // [] | map(select(type == "string")) | .[:2] | join("; ")) // "n/a"' "$output_path")"
    if [[ -z "$risk_snippet" ]]; then
      risk_snippet="n/a"
    fi
  fi

  message+=$'\n'
  message+="- ${fund_id}/${provider}: ${status_label} | action=${action} | change=${remove_ticker} -> ${add_ticker} | constraints=${constraints_label}"
  message+=$'\n'
  message+="  risks: ${risk_snippet}"
  message+=$'\n'
  message+="  files: ${run_path}/dexter_output.json"
done < <(jq -c '.lanes[]' "$scoreboard_path")

message+=$'\n\n'
message+="Scoreboard: funds/arena/runs/${run_date}/scoreboard.md"

max_len=2000
if (( ${#message} > max_len )); then
  cutoff=1997
  message="${message:0:cutoff}..."
fi

jq -Rn --arg content "$message" '{content: $content}'
