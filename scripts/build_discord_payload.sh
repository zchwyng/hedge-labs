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
lane_count="$(jq -r '.lanes | length' "$scoreboard_path")"
overlap_pct="$(jq -r '.comparison.portfolio_overlap_pct // 0' "$scoreboard_path")"
turnover_pct="$(jq -r '.comparison.turnover_estimate_pct // 0' "$scoreboard_path")"
comparison_notes="$(jq -r '.comparison.notes // ""' "$scoreboard_path")"

if [[ "$all_success" == "true" ]]; then
  overall_line="All paper funds ran successfully today."
else
  overall_line="${failed_count} of ${lane_count} fund lane(s) had issues, but the daily summary is complete."
fi

lane_sections=""
perf_rows='[]'

while IFS= read -r lane; do
  fund_id="$(jq -r '.fund_id' <<<"$lane")"
  provider="$(jq -r '.provider' <<<"$lane")"
  status="$(jq -r '.status' <<<"$lane")"
  action="$(jq -r '.action' <<<"$lane")"
  add_ticker="$(jq -r '.add_ticker // "-"' <<<"$lane")"
  remove_ticker="$(jq -r '.remove_ticker // "-"' <<<"$lane")"
  constraints_ok="$(jq -r '.constraints_ok' <<<"$lane")"
  run_path="$(jq -r '.run_path' <<<"$lane")"
  case "$provider" in
    openai) provider_label="OpenAI" ;;
    anthropic) provider_label="Anthropic" ;;
    *) provider_label="$(printf '%s' "$provider" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')" ;;
  esac

  if [[ "$status" == "success" ]]; then
    status_label="On track"
  else
    status_label="Issue"
  fi

  if [[ "$constraints_ok" == "true" ]]; then
    constraints_label="Within limits"
  else
    constraints_label="Limit check failed"
  fi

  fund_label="$(printf '%s' "$fund_id" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) tolower(substr($i,2))} print}')"
  risk_snippet="n/a"
  holdings_snippet="n/a"
  performance_summary="n/a"
  stock_performance_summary="n/a"
  action_summary="No update available."
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
    fund_return_pct="$(jq -r '.fund_return_pct // empty' <<<"$perf_json")"
    coverage_pct="$(jq -r '.covered_weight_pct // empty' <<<"$perf_json")"
    if [[ -n "$fund_return_pct" ]]; then
      performance_summary="$(printf "%+.2f%%" "$fund_return_pct")"
      if [[ -n "$coverage_pct" ]]; then
        performance_summary+=" (coverage ${coverage_pct}%)"
      fi
      perf_rows="$(jq -cn \
        --argjson rows "$perf_rows" \
        --arg fund "$fund_label" \
        --argjson ret "$fund_return_pct" \
        '$rows + [{fund: $fund, ret: $ret}]')"
    fi

    stock_performance_summary="$(jq -r '
      (.stocks // []) as $s
      | if ($s | length) == 0 then "n/a"
        else
          ($s[:4]
            | map(
              .ticker + " "
              + (if .return_pct >= 0 then "+" else "" end)
              + (.return_pct|tostring)
              + "% since " + .since_date
            )
            | join(", ")
          )
        end
    ' <<<"$perf_json")"

    size_change="$(jq -r '.trade_of_the_day.size_change_pct // 0' "$output_path")"
    case "$action" in
      "Do nothing")
        action_summary="No portfolio change today."
        ;;
      "Add")
        action_summary="Added ${add_ticker} (${size_change}% target weight change)."
        ;;
      "Trim")
        action_summary="Trimmed ${remove_ticker} (${size_change}% target weight change)."
        ;;
      "Replace")
        action_summary="Replaced ${remove_ticker} with ${add_ticker} (${size_change}% target weight change)."
        ;;
      *)
        action_summary="Model action: ${action}."
        ;;
    esac
  else
    if [[ "$status" != "success" ]]; then
      action_summary="Run failed before a valid portfolio update was produced."
    fi
  fi

  lane_sections+=$'\n\n'
  lane_sections+="${fund_label} (${provider_label})"
  lane_sections+=$'\n'
  lane_sections+="- Status: ${status_label}"
  lane_sections+=$'\n'
  lane_sections+="- Today: ${action_summary}"
  lane_sections+=$'\n'
  lane_sections+="- Risk limits: ${constraints_label}"
  lane_sections+=$'\n'
  lane_sections+="- Fund since added: ${performance_summary}"
  lane_sections+=$'\n'
  lane_sections+="- Since added (sample stocks): ${stock_performance_summary}"
  lane_sections+=$'\n'
  lane_sections+="- Current holdings: ${holdings_snippet}"
  lane_sections+=$'\n'
  lane_sections+="- Watch-outs: ${risk_snippet}"
done < <(jq -c '.lanes[]' "$scoreboard_path")

leader_line="$(jq -r '
  map(select(.ret != null)) as $r
  | if ($r | length) == 0 then
      "Leader since launch: n/a"
    elif ($r | length) == 1 then
      "Leader since launch: \($r[0].fund) (\($r[0].ret)%)"
    else
      ($r | sort_by(-.ret)) as $s
      | if ($s[0].ret == $s[1].ret) then
          "Leader since launch: tied"
        else
          "Leader since launch: \($s[0].fund) (\($s[0].ret)%)"
        end
    end
' <<<"$perf_rows")"

message="**Daily Paper Fund Update - ${run_date}**"
message+=$'\n'
message+="$overall_line"
message+=$'\n\n'
message+="Scoreboard Snapshot"
message+=$'\n'
message+="- Portfolio overlap: ${overlap_pct}%"
message+=$'\n'
message+="- Estimated turnover today: ${turnover_pct}%"
message+=$'\n'
message+="- ${leader_line}"
if [[ -n "$comparison_notes" && "$comparison_notes" != "null" ]]; then
  if [[ "$comparison_notes" == Computed\ from\ first\ two\ successful\ lanes:* ]]; then
    comparison_notes="Based on today's two completed fund runs."
  fi
  message+=$'\n'
  message+="- Notes: ${comparison_notes}"
fi
message+="$lane_sections"
message+=$'\n\n'
message+="Full scoreboard: funds/arena/runs/${run_date}/scoreboard.md"

max_len=2000
if (( ${#message} > max_len )); then
  cutoff=1997
  message="${message:0:cutoff}..."
fi

jq -Rn --arg content "$message" '{content: $content}'
