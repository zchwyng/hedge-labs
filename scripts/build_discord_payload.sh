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
  overall_emoji="🟢"
  overall_line="All paper funds completed successfully."
else
  overall_emoji="🟠"
  overall_line="${failed_count} of ${lane_count} lanes had issues. Summary still posted."
fi

lane_sections=""
perf_rows='[]'

while IFS= read -r lane; do
  fund_id="$(jq -r '.fund_id' <<<"$lane")"
  provider="$(jq -r '.provider' <<<"$lane")"
  status="$(jq -r '.status' <<<"$lane")"
  action="$(jq -r '.action // "UNKNOWN"' <<<"$lane")"
  add_ticker="$(jq -r '.add_ticker // "-"' <<<"$lane")"
  remove_ticker="$(jq -r '.remove_ticker // "-"' <<<"$lane")"
  constraints_ok="$(jq -r '.constraints_ok' <<<"$lane")"
  run_path="$(jq -r '.run_path' <<<"$lane")"

  case "$provider" in
    openai) provider_label="OpenAI" ;;
    anthropic) provider_label="Anthropic" ;;
    *) provider_label="$(printf '%s' "$provider" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')" ;;
  esac

  fund_label="$(printf '%s' "$fund_id" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) tolower(substr($i,2))} print}')"
  case "$fund_id" in
    fund-a) fund_emoji="🟦" ;;
    fund-b) fund_emoji="🟪" ;;
    *) fund_emoji="⬜" ;;
  esac

  if [[ "$status" == "success" ]]; then
    status_emoji="🟢"
    status_label="On track"
  else
    status_emoji="🔴"
    status_label="Issue"
  fi

  if [[ "$constraints_ok" == "true" ]]; then
    constraints_label="✅ Within limits"
  else
    constraints_label="⚠️ Limit check failed"
  fi

  output_path="${run_path}/dexter_output.json"
  meta_path="${run_path}/run_meta.json"
  stdout_path="${run_path}/dexter_stdout.txt"

  action_summary="No update available."
  performance_summary="n/a"
  stock_moves_summary="n/a"
  risk_snippet="n/a"
  holdings_block="  • n/a"
  error_message=""
  model_label="unknown"

  if [[ -f "$meta_path" ]]; then
    model_label="$(jq -r '.model // "unknown"' "$meta_path")"
  fi

  if [[ "$status" == "success" && -f "$output_path" ]]; then
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

    holdings_block="$(jq -r '
      (.target_portfolio // []) as $p
      | if ($p | length) == 0 then
          "  • n/a"
        else
          ($p | map("  • `\(.ticker)` — \(.weight_pct)% (\(.sector))") | join("\n"))
        end
    ' "$output_path")"

    risk_snippet="$(jq -r '(.trade_of_the_day.risks // [] | map(select(type == "string")) | .[:2] | join("; ")) // "n/a"' "$output_path")"
    if [[ -z "$risk_snippet" ]]; then
      risk_snippet="n/a"
    fi

    perf_json="$(node scripts/performance_since_added.mjs "$fund_id" "$provider" "$run_date" 2>/dev/null || echo '{}')"

    fund_return_pct="$(jq -r '.fund_return_pct // empty' <<<"$perf_json")"
    coverage_pct="$(jq -r '.covered_weight_pct // empty' <<<"$perf_json")"
    if [[ -n "$fund_return_pct" ]]; then
      performance_summary="$(printf "%+.2f%%" "$fund_return_pct")"
      if [[ -n "$coverage_pct" ]]; then
        performance_summary+=" (coverage ${coverage_pct}%)"
      fi
      perf_rows="$(jq -cn --argjson rows "$perf_rows" --arg fund "$fund_label" --argjson ret "$fund_return_pct" '$rows + [{fund: $fund, ret: $ret}]')"
    fi

    stock_moves_summary="$(jq -r '
      (.stocks // []) as $s
      | if ($s | length) == 0 then
          "n/a"
        else
          ($s | sort_by(-.return_pct) | .[0:2]) as $winners
          | ($s | sort_by(.return_pct) | .[0:1]) as $laggards
          | (($winners + $laggards)
            | unique_by(.ticker)
            | map(
                .ticker + " "
                + (if .return_pct >= 0 then "+" else "" end)
                + (.return_pct|tostring)
                + "%"
              )
            | join(", "))
        end
    ' <<<"$perf_json")"
  fi

  if [[ "$status" != "success" && -f "$meta_path" ]]; then
    error_message="$(jq -r '.reason // ""' "$meta_path")"
    if [[ -f "$stdout_path" && ( -z "$error_message" || "$error_message" == bun\ start\ exited\ with\ code* ) ]]; then
      runner_error="$(grep -Eo 'fund_runner_error: .*' "$stdout_path" | tail -n 1 | sed -E 's/^fund_runner_error:[[:space:]]*//' || true)"
      if [[ -n "$runner_error" ]]; then
        error_message="$runner_error"
      fi
    fi
    error_message="$(printf '%s' "$error_message" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    if [[ ${#error_message} -gt 220 ]]; then
      error_message="${error_message:0:217}..."
    fi
  fi

  lane_sections+=$'\n\n'
  lane_sections+="**${fund_emoji} ${fund_label} (${provider_label})**"
  lane_sections+=$'\n'
  lane_sections+="- Model: \`${model_label}\`"
  lane_sections+=$'\n'
  lane_sections+="- Status: ${status_emoji} **${status_label}**"
  lane_sections+=$'\n'
  lane_sections+="- Today: ${action_summary}"
  lane_sections+=$'\n'
  lane_sections+="- Risk limits: ${constraints_label}"
  lane_sections+=$'\n'
  lane_sections+="- Since added (fund): **${performance_summary}**"
  lane_sections+=$'\n'
  lane_sections+="- Since added (stocks): ${stock_moves_summary}"

  if [[ -n "$error_message" ]]; then
    lane_sections+=$'\n'
    lane_sections+="- ❗ Error: **${error_message}**"
  fi

  lane_sections+=$'\n'
  lane_sections+="- Holdings:"
  lane_sections+=$'\n'
  lane_sections+="$holdings_block"

  if [[ "$status" == "success" ]]; then
    lane_sections+=$'\n'
    lane_sections+="- Watch-outs: ${risk_snippet}"
  fi
done < <(jq -c '.lanes[]' "$scoreboard_path")

leader_line="$(jq -r '
  map(select(.ret != null)) as $r
  | if ($r | length) == 0 then
      "n/a"
    elif ($r | length) == 1 then
      "\($r[0].fund) (\($r[0].ret)%)"
    else
      ($r | sort_by(-.ret)) as $s
      | if ($s[0].ret == $s[1].ret) then
          "tied"
        else
          "\($s[0].fund) (\($s[0].ret)%)"
        end
    end
' <<<"$perf_rows")"

if [[ -n "$comparison_notes" && "$comparison_notes" == Computed\ from\ first\ two\ successful\ lanes:* ]]; then
  comparison_notes="Based on today's completed fund runs."
fi

message="**📈 Daily Paper Fund Update — ${run_date}**"
message+=$'\n'
message+="${overall_emoji} ${overall_line}"
message+=$'\n\n'
message+="**🏁 Scoreboard**"
message+=$'\n'
message+="- Portfolio overlap: **${overlap_pct}%**"
message+=$'\n'
message+="- Estimated turnover: **${turnover_pct}%**"
message+=$'\n'
message+="- Leader since launch: **${leader_line}**"
if [[ -n "$comparison_notes" && "$comparison_notes" != "null" ]]; then
  message+=$'\n'
  message+="- Notes: _${comparison_notes}_"
fi
message+="$lane_sections"
message+=$'\n\n'
message+="**📄 Full scoreboard:** funds/arena/runs/${run_date}/scoreboard.md"

max_len=2000
if (( ${#message} > max_len )); then
  # Keep holdings + errors; trim lower-priority commentary first.
  compact_message="$message"
  compact_message="$(printf '%s' "$compact_message" | sed -E 's/\n- Watch-outs:.*//g')"
  compact_message="$(printf '%s' "$compact_message" | sed -E 's/\n- Notes:.*//g')"
  if (( ${#compact_message} <= max_len )); then
    message="$compact_message"
  else
    cutoff=1997
    message="${compact_message:0:cutoff}..."
  fi
fi

jq -Rn --arg content "$message" '{content: $content}'
