#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <run_date>" >&2
  exit 64
fi

run_date="$1"
scoreboard_path="funds/arena/runs/${run_date}/scoreboard.json"
scoreboard_repo_path="funds/arena/runs/${run_date}/scoreboard.md"

if [[ ! -f "$scoreboard_path" ]]; then
  echo "Missing scoreboard: $scoreboard_path" >&2
  exit 1
fi

sanitize_one_line() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  printf '%s' "$cleaned"
}

truncate_text() {
  local raw="$1"
  local max_len="$2"
  if (( ${#raw} <= max_len )); then
    printf '%s' "$raw"
  else
    printf '%s...' "${raw:0:max_len-3}"
  fi
}

repo_web_url=""
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  repo_web_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
else
  origin_url="$(git config --get remote.origin.url 2>/dev/null || true)"
  case "$origin_url" in
    git@github.com:*.git)
      repo_path="${origin_url#git@github.com:}"
      repo_path="${repo_path%.git}"
      repo_web_url="https://github.com/${repo_path}"
      ;;
    https://github.com/*.git)
      repo_path="${origin_url#https://github.com/}"
      repo_path="${repo_path%.git}"
      repo_web_url="https://github.com/${repo_path}"
      ;;
    https://github.com/*)
      repo_path="${origin_url#https://github.com/}"
      repo_web_url="https://github.com/${repo_path}"
      ;;
  esac
fi

scoreboard_url=""
if [[ -n "$repo_web_url" ]]; then
  scoreboard_url="${repo_web_url}/blob/main/${scoreboard_repo_path}"
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
  config_path="funds/${fund_id}/fund.config.json"

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
  sector_exposure_summary="n/a"
  fund_type_label="n/a"
  risk_snippet="n/a"
  holdings_block="  • n/a"
  change_reason_block="  • n/a"
  error_message=""
  api_notice_block=""
  model_label="unknown"

  if [[ -f "$config_path" ]]; then
    fund_type_label="$(jq -r '.universe // "n/a"' "$config_path")"
    model_label="$(jq -r '.model // "unknown"' "$config_path")"
  fi

  if [[ -f "$meta_path" ]]; then
    model_label="$(jq -r '.model // "unknown"' "$meta_path")"
    api_notice_block="$(jq -r '
      (.api_errors // [])
      | map(select(type == "string" and length > 0))
      | unique
      | .[:3]
      | map(
          if length > 160 then .[0:157] + "..."
          else .
          end
        )
      | if length == 0 then ""
        else map("  • " + .) | join("\n")
        end
    ' "$meta_path")"
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
          ($p
            | sort_by(-((.weight_pct // 0) | tonumber), (.ticker // ""))
            | map("  • `\(.ticker)` — \(((.weight_pct // 0) | tonumber))% — \(.sector // "UNKNOWN")")
            | join("\n"))
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

    sector_exposure_summary="$(jq -r '
      (.target_portfolio // []) as $p
      | if ($p | length) == 0 then
          "n/a"
        else
          ($p
            | group_by(.sector)
            | map({
                sector: (.[0].sector // "UNKNOWN"),
                weight: ((map(.weight_pct // 0) | add) // 0)
              })
            | sort_by(-.weight, .sector)
            | map(.sector + " " + ((.weight * 100 | round) / 100 | tostring) + "%")
            | .[0:4]
            | join(", "))
        end
    ' "$output_path")"

    runs_root="funds/${fund_id}/runs"
    prev_output_path=""
    if [[ -d "$runs_root" ]]; then
      while IFS= read -r prev_date; do
        [[ "$prev_date" < "$run_date" ]] || continue
        candidate_output="${runs_root}/${prev_date}/${provider}/dexter_output.json"
        candidate_meta="${runs_root}/${prev_date}/${provider}/run_meta.json"
        if [[ ! -f "$candidate_output" ]]; then
          continue
        fi
        if [[ -f "$candidate_meta" ]]; then
          candidate_status="$(jq -r '.status // "failed"' "$candidate_meta")"
          [[ "$candidate_status" == "success" ]] || continue
        fi
        prev_output_path="$candidate_output"
      done < <(find "$runs_root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort)
    fi

    if [[ -z "$prev_output_path" ]]; then
      change_reason_block="  • No prior successful run to compare."
    else
      change_rows="$(jq -c -n \
        --slurpfile prev "$prev_output_path" \
        --slurpfile curr "$output_path" '
          def pmap($x): ($x.target_portfolio // [] | map({key: .ticker, value: (.weight_pct // 0)}) | from_entries);
          (pmap($prev[0])) as $p
          | (pmap($curr[0])) as $c
          | (($p | keys) + ($c | keys) | unique | sort) as $keys
          | [
              $keys[] as $k
              | ($p[$k] // 0) as $pw
              | ($c[$k] // 0) as $cw
              | ($cw - $pw) as $d
              | if ((if $d < 0 then -$d else $d end) >= 0.01) then
                  {ticker: $k, prev: $pw, curr: $cw, delta: $d}
                else
                  empty
                end
            ]
        ')"

      change_count="$(jq -r 'length' <<<"$change_rows")"
      if [[ "$change_count" == "0" ]]; then
        change_reason_block="  • No holding changes vs previous run."
      else
        change_reason_block=""
        while IFS= read -r change; do
          ticker="$(jq -r '.ticker' <<<"$change")"
          prev_w_raw="$(jq -r '.prev' <<<"$change")"
          curr_w_raw="$(jq -r '.curr' <<<"$change")"
          delta_raw="$(jq -r '.delta' <<<"$change")"

          prev_w="$(printf "%.2f" "$prev_w_raw")"
          curr_w="$(printf "%.2f" "$curr_w_raw")"
          abs_delta="$(awk -v d="$delta_raw" 'BEGIN { if (d < 0) d = -d; printf "%.2f", d }')"
          if awk -v d="$delta_raw" 'BEGIN { exit !(d >= 0) }'; then
            delta_icon="↑"
          else
            delta_icon="↓"
          fi

          reason=""
          if [[ "$add_ticker" != "-" && "$ticker" == "$add_ticker" ]] && awk -v d="$delta_raw" 'BEGIN { exit !(d > 0) }'; then
            reason="$(jq -r '(.trade_of_the_day.thesis // [] | map(select(type=="string")) | .[0]) // empty' "$output_path")"
          elif [[ "$remove_ticker" != "-" && "$ticker" == "$remove_ticker" ]] && awk -v d="$delta_raw" 'BEGIN { exit !(d < 0) }'; then
            reason="$(jq -r --arg t "$ticker" '(.thesis_damage_flags // [] | map(select(.ticker == $t) | .why) | .[0]) // empty' "$output_path")"
            if [[ -z "$reason" ]]; then
              reason="$(jq -r '(.trade_of_the_day.risks // [] | map(select(type=="string")) | .[0]) // empty' "$output_path")"
            fi
          elif awk -v d="$delta_raw" 'BEGIN { exit !(d > 0) }'; then
            reason="$(jq -r '(.trade_of_the_day.thesis // [] | map(select(type=="string")) | .[1]) // empty' "$output_path")"
          else
            reason="$(jq -r --arg t "$ticker" '(.thesis_damage_flags // [] | map(select(.ticker == $t) | .why) | .[0]) // empty' "$output_path")"
            if [[ -z "$reason" ]]; then
              reason="$(jq -r '(.trade_of_the_day.risks // [] | map(select(type=="string")) | .[0]) // empty' "$output_path")"
            fi
          fi

          if [[ -z "$reason" ]]; then
            reason="$(jq -r '.trade_of_the_day.why_now // "Rebalance update based on current model thesis."' "$output_path")"
          fi
          reason="$(sanitize_one_line "$reason")"
          reason="$(truncate_text "$reason" 140)"

          change_reason_block+=$'\n'
          change_reason_block+="  • \`${ticker}\` ${prev_w}% → ${curr_w}% (${delta_icon}${abs_delta}%): ${reason}"
        done < <(jq -c '.[]' <<<"$change_rows")
      fi
    fi
  fi

  if [[ "$status" != "success" && -f "$meta_path" ]]; then
    error_message="$(jq -r '.reason // ""' "$meta_path")"
    if [[ -f "$stdout_path" && -z "$error_message" ]]; then
      runner_error="$(
        {
          grep -Eo 'Error: .*' "$stdout_path" | tail -n 1 | sed -E 's/^Error:[[:space:]]*//' || true
          grep -Eo '\\[[^]]+ API\\].*' "$stdout_path" | tail -n 1 || true
        } | sed '/^$/d' | tail -n 1
      )"
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
  lane_sections+="- Fund type: ${fund_type_label}"
  lane_sections+=$'\n'
  lane_sections+="- Sector exposure: ${sector_exposure_summary}"
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
  if [[ -n "$api_notice_block" ]]; then
    lane_sections+=$'\n'
    lane_sections+="- API notices:"
    lane_sections+=$'\n'
    lane_sections+="$api_notice_block"
  fi
  lane_sections+=$'\n'
  lane_sections+="- Holding changes + reasoning:"
  lane_sections+=$'\n'
  lane_sections+="$change_reason_block"

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
message+=$'\n'
if [[ -n "$scoreboard_url" ]]; then
  message+="- Full scoreboard: <${scoreboard_url}>"
else
  message+="- Full scoreboard: ${scoreboard_repo_path}"
fi
message+="$lane_sections"

max_len=2000
if (( ${#message} > max_len )); then
  # Keep holdings + errors; trim lower-priority commentary first.
  compact_message="$message"
  compact_message="$(printf '%s' "$compact_message" | perl -0pe 's/^-\s*Watch-outs:.*\n//mg; s/^-\s*Notes:.*\n//mg')"
  if (( ${#compact_message} > max_len )); then
    compact_message="$(printf '%s' "$compact_message" | perl -0pe 's/\n- Holding changes \+ reasoning:\n(?:  •.*\n)+/\n/g')"
  fi
  if (( ${#compact_message} > max_len )); then
    compact_message="$(printf '%s' "$compact_message" | perl -0pe 's/^-\s*Since added \(stocks\):.*\n//mg')"
  fi
  if (( ${#compact_message} > max_len )); then
    compact_message="$(printf '%s' "$compact_message" | perl -0pe 's/^-\s*Leader since launch:.*\n//mg')"
  fi
  if (( ${#compact_message} > max_len )); then
    compact_message="$(printf '%s' "$compact_message" | perl -0pe 's/^-\s*Sector exposure:.*\n//mg')"
  fi
  if (( ${#compact_message} <= max_len )); then
    message="$compact_message"
  else
    cutoff=$((max_len - 3))
    prefix="${compact_message:0:cutoff}"
    if [[ "$prefix" == *$'\n'* ]]; then
      prefix="${prefix%$'\n'*}"
    fi
    message="${prefix}..."
  fi
fi

jq -Rn --arg content "$message" '{content: $content, flags: 4}'
