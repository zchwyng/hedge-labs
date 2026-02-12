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
overlap_pct="$(jq -r '.comparison.portfolio_overlap_pct // 0' "$scoreboard_path")"
turnover_pct="$(jq -r '.comparison.turnover_estimate_pct // 0' "$scoreboard_path")"
comparison_notes="$(jq -r '.comparison.notes // ""' "$scoreboard_path")"

if [[ "$all_success" == "true" ]]; then
  overall_line="All funds ran successfully today."
else
  overall_line="Some runs failed (${failed_count} lane(s))."
fi

message="**Daily Paper Fund Update - ${run_date}**"
message+=$'\n'
message+="$overall_line"
message+=$'\n\n'
message+="Scoreboard"
message+=$'\n'
message+="- Portfolio overlap: ${overlap_pct}%"
message+=$'\n'
message+="- Turnover estimate: ${turnover_pct}%"
if [[ -n "$comparison_notes" && "$comparison_notes" != "null" ]]; then
  message+=$'\n'
  message+="- Notes: ${comparison_notes}"
fi

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

  fund_label="$(printf '%s' "$fund_id" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) tolower(substr($i,2))} print}')"
  risk_snippet="n/a"
  holdings_snippet="n/a"
  performance_summary="n/a"
  stock_performance_summary="n/a"
  output_path="${run_path}/dexter_output.json"
  if [[ -f "$output_path" ]]; then
    risk_snippet="$(jq -r '(.trade_of_the_day.risks // [] | map(select(type == "string")) | .[:2] | join("; ")) // "n/a"' "$output_path")"
    if [[ -z "$risk_snippet" ]]; then
      risk_snippet="n/a"
    fi

    # Keep holdings concise for Discord size limits while still showing portfolio composition.
    holdings_snippet="$(jq -r '
      (.target_portfolio // []) as $p
      | ($p | length) as $n
      | ($p
          | map(select(.ticker != null and .weight_pct != null))
          | .[:6]
          | map("\(.ticker) \(.weight_pct)%")
          | join(", ")
        ) as $top
      | if $n == 0 then "n/a"
        elif $n > 6 then ($top + ", ... (" + ($n|tostring) + " total)")
        else $top
        end
    ' "$output_path")"
    if [[ -z "$holdings_snippet" ]]; then
      holdings_snippet="n/a"
    fi

    perf_json="$(node scripts/performance_since_added.mjs "$fund_id" "$provider" "$run_date" 2>/dev/null || echo '{}')"
    performance_summary="$(jq -r '
      if .fund_return_pct == null then "n/a"
      else
        ((if .fund_return_pct >= 0 then "+" else "" end) + (.fund_return_pct|tostring) + "%")
        + " (coverage " + ((.covered_weight_pct // 0)|tostring) + "%)"
      end
    ' <<<"$perf_json")"

    stock_performance_summary="$(jq -r '
      (.stocks // []) as $s
      | if ($s | length) == 0 then "n/a"
        else
          ($s[:4]
            | map(
              .ticker + " "
              + (if .return_pct >= 0 then "+" else "" end)
              + (.return_pct|tostring)
              + "% (since " + .since_date + ")"
            )
            | join(", ")
          )
        end
    ' <<<"$perf_json")"
  fi

  message+=$'\n\n'
  message+="${fund_label} (${provider})"
  message+=$'\n'
  message+="- Status: ${status_label}"
  message+=$'\n'
  message+="- Today: ${action} (${remove_ticker} -> ${add_ticker})"
  message+=$'\n'
  message+="- Constraints check: ${constraints_label}"
  message+=$'\n'
  message+="- Fund performance since added: ${performance_summary}"
  message+=$'\n'
  message+="- Stock performance since added: ${stock_performance_summary}"
  message+=$'\n'
  message+="- Holdings: ${holdings_snippet}"
  message+=$'\n'
  message+="- Top risks: ${risk_snippet}"
done < <(jq -c '.lanes[]' "$scoreboard_path")

message+=$'\n\n'
message+="Full scoreboard: funds/arena/runs/${run_date}/scoreboard.md"

max_len=2000
if (( ${#message} > max_len )); then
  cutoff=1997
  message="${message:0:cutoff}..."
fi

jq -Rn --arg content "$message" '{content: $content}'
