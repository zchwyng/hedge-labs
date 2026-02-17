#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <run_date>" >&2
  exit 64
fi

run_date="$1"
arena_dir="funds/arena/runs/${run_date}"
mkdir -p "$arena_dir"

lanes_tmp="$(mktemp)"
trap 'rm -f "$lanes_tmp"' EXIT

fund_dirs=()
while IFS= read -r fund_dir; do
  fund_dirs+=("$fund_dir")
done < <(find funds -mindepth 1 -maxdepth 1 -type d -name 'fund-*' | sort)
if [[ "${#fund_dirs[@]}" -eq 0 ]]; then
  echo "No fund-* directories found under funds/" >&2
  exit 1
fi

for fund_dir in "${fund_dirs[@]}"; do
  config_path="${fund_dir}/fund.config.json"
  [[ -f "$config_path" ]] || continue

  fund_id="$(basename "$fund_dir")"
  provider="$(jq -r '.provider // "unknown"' "$config_path")"
  run_path="funds/${fund_id}/runs/${run_date}/${provider}"
  meta_path="${run_path}/run_meta.json"
  output_path="${run_path}/dexter_output.json"

  status="failed"
  action="UNKNOWN"
  add_ticker=""
  remove_ticker=""
  size_change_pct=0
  constraints_ok=false
  rebalance_actions_count=0
  rebalance_actions_preview=""
  fund_return_pct='null'
  benchmark_return_pct='null'
  excess_return_pct='null'
  performance_coverage_pct=0
  benchmark_coverage_pct=0
  performance_method=""
  inception_date=""
  asof_portfolio_date=""
  asof_price_date=""
  benchmark_ticker=""
  benchmark_name=""

  benchmark_ticker="$(jq -r '.benchmark.ticker // .benchmark_ticker // empty' "$config_path")"
  benchmark_name="$(jq -r '.benchmark.name // .benchmark_label // .benchmark.ticker // .benchmark_ticker // empty' "$config_path")"

  if [[ -f "$meta_path" ]]; then
    status="$(jq -r '.status // "failed"' "$meta_path")"
  fi

  if [[ "$status" == "success" && -f "$output_path" ]]; then
    action="$(jq -r '.trade_of_the_day.action // "UNKNOWN"' "$output_path")"
    add_ticker="$(jq -r '.trade_of_the_day.add_ticker // empty' "$output_path")"
    remove_ticker="$(jq -r '.trade_of_the_day.remove_ticker // empty' "$output_path")"
    size_change_pct="$(jq -r '.trade_of_the_day.size_change_pct // 0' "$output_path")"
    constraints_ok="$(jq -r '((.constraints_check.max_position_ok // false) and (.constraints_check.max_sector_ok // false) and (.constraints_check.max_crypto_ok // true))' "$output_path")"
    rebalance_actions_count="$(jq -r '(.rebalance_actions // []) | length' "$output_path")"
    rebalance_actions_preview="$(jq -r '
      (.rebalance_actions // [])
      | map(
          .action as $a
          | .remove_ticker as $r
          | .add_ticker as $ad
          | if $a == "Do nothing" then
              "Do nothing"
            elif $a == "Add" then
              ("Add " + ($ad // "?"))
            elif $a == "Trim" then
              ("Trim " + ($r // "?") + "->" + ($ad // "?"))
            elif $a == "Replace" then
              ("Replace " + ($r // "?") + "->" + ($ad // "?"))
            else
              ($a // "UNKNOWN")
            end
        )
      | .[:4]
      | join(", ")
    ' "$output_path")"
  fi

  perf_json="$(node scripts/performance_since_added.mjs "$fund_id" "$provider" "$run_date" "$benchmark_ticker" "$benchmark_name" 2>/dev/null || echo '{}')"
  performance_method="$(jq -r '.performance_method // empty' <<<"$perf_json")"
  inception_date="$(jq -r '.inception_date // empty' <<<"$perf_json")"
  asof_portfolio_date="$(jq -r '.asof_portfolio_date // empty' <<<"$perf_json")"
  asof_price_date="$(jq -r '.asof_price_date // empty' <<<"$perf_json")"
  fund_return_pct="$(jq -c '.fund_return_pct // null' <<<"$perf_json")"
  benchmark_return_pct="$(jq -c '.benchmark_return_pct // null' <<<"$perf_json")"
  excess_return_pct="$(jq -c '.excess_return_pct // null' <<<"$perf_json")"
  performance_coverage_pct="$(jq -r '.covered_weight_pct // 0' <<<"$perf_json")"
  benchmark_coverage_pct="$(jq -r '.benchmark_covered_weight_pct // 0' <<<"$perf_json")"

  jq -n \
    --arg fund_id "$fund_id" \
    --arg provider "$provider" \
    --arg status "$status" \
    --arg action "$action" \
    --arg add_ticker "$add_ticker" \
    --arg remove_ticker "$remove_ticker" \
    --arg benchmark_ticker "$benchmark_ticker" \
    --arg benchmark_name "$benchmark_name" \
    --arg performance_method "$performance_method" \
    --arg inception_date "$inception_date" \
    --arg asof_portfolio_date "$asof_portfolio_date" \
    --arg asof_price_date "$asof_price_date" \
    --arg rebalance_actions_preview "$rebalance_actions_preview" \
    --arg run_path "$run_path" \
    --argjson size_change_pct "$size_change_pct" \
    --argjson constraints_ok "$constraints_ok" \
    --argjson rebalance_actions_count "$rebalance_actions_count" \
    --argjson fund_return_pct "$fund_return_pct" \
    --argjson benchmark_return_pct "$benchmark_return_pct" \
    --argjson excess_return_pct "$excess_return_pct" \
    --argjson performance_coverage_pct "$performance_coverage_pct" \
    --argjson benchmark_coverage_pct "$benchmark_coverage_pct" \
    '{
      fund_id: $fund_id,
      provider: $provider,
      status: $status,
      action: $action,
      add_ticker: (if $add_ticker == "" then null else $add_ticker end),
      remove_ticker: (if $remove_ticker == "" then null else $remove_ticker end),
      size_change_pct: $size_change_pct,
      constraints_ok: $constraints_ok,
      rebalance_actions_count: $rebalance_actions_count,
      rebalance_actions_preview: (if $rebalance_actions_preview == "" then null else $rebalance_actions_preview end),
      benchmark_ticker: (if $benchmark_ticker == "" then null else $benchmark_ticker end),
      benchmark_name: (if $benchmark_name == "" then null else $benchmark_name end),
      performance_method: (if $performance_method == "" then null else $performance_method end),
      inception_date: (if $inception_date == "" then null else $inception_date end),
      asof_portfolio_date: (if $asof_portfolio_date == "" then null else $asof_portfolio_date end),
      asof_price_date: (if $asof_price_date == "" then null else $asof_price_date end),
      fund_return_pct: $fund_return_pct,
      benchmark_return_pct: $benchmark_return_pct,
      excess_return_pct: $excess_return_pct,
      performance_coverage_pct: $performance_coverage_pct,
      benchmark_coverage_pct: $benchmark_coverage_pct,
      run_path: $run_path
    }' >> "$lanes_tmp"
done

lanes_json="$(jq -s '.' "$lanes_tmp")"
lanes_json="$(printf '%s' "$lanes_json" | jq '
  def perf_score: (.excess_return_pct // .fund_return_pct // -1000000);
  sort_by(
    (if .status == "success" then 0 else 1 end),
    -(perf_score),
    -(.performance_coverage_pct // 0),
    .fund_id,
    .provider
  )
  | to_entries
  | map(
      .value + {
        rank: (.key + 1),
        ranking_score: (
          if .value.status == "success"
          then (.value.excess_return_pct // .value.fund_return_pct)
          else null
          end
        )
      }
    )
')"
ranking_notes="$(printf '%s' "$lanes_json" | jq -r '
  if ([.[] | select(.status == "success")] | length) == 0 then
    "No successful lanes to rank."
  else
    "Ranked independently by excess return vs benchmark (fallback to fund return), with coverage as tie-breaker. Returns are NAV-style since inception."
  end
')"

success_paths=()
while IFS= read -r success_path; do
  success_paths+=("$success_path")
done < <(printf '%s' "$lanes_json" | jq -r '.[] | select(.status == "success") | .run_path + "/dexter_output.json"')
overlap_pct=0
turnover_pct=0
comparison_notes="Need at least two successful lanes to compute overlap/turnover metrics."

if [[ "${#success_paths[@]}" -ge 2 ]]; then
  a_path="${success_paths[0]}"
  b_path="${success_paths[1]}"

  if [[ -f "$a_path" && -f "$b_path" ]]; then
    overlap_pct="$(jq -n --slurpfile a "$a_path" --slurpfile b "$b_path" '
      def tickers($p): ($p.target_portfolio // [] | map(.ticker) | map(select(type == "string")) | unique);
      (tickers($a[0])) as $ta
      | (tickers($b[0])) as $tb
      | (($ta + $tb) | unique) as $u
      | if ($u | length) == 0 then 0
        else (
          (([
            $u[] as $ticker
            | select(($ta | index($ticker)) != null and ($tb | index($ticker)) != null)
          ] | length) * 10000 / ($u | length) | round) / 100
        )
        end
    ')"

    turnover_pct="$(jq -n --slurpfile a "$a_path" --slurpfile b "$b_path" '
      def weight($p; $t): (($p.target_portfolio // [] | map(select(.ticker == $t) | (.weight_pct // 0)) | first) // 0);
      def tickers($p): ($p.target_portfolio // [] | map(.ticker) | map(select(type == "string")) | unique);
      (tickers($a[0])) as $ta
      | (tickers($b[0])) as $tb
      | (($ta + $tb) | unique) as $u
      | if ($u | length) == 0 then 0
        else (([$u[] | ((weight($a[0]; .) - weight($b[0]; .)) | if . < 0 then -. else . end)] | add) / 2 | (. * 100 | round) / 100)
        end
    ')"

    comparison_notes="Computed from first two successful lanes: ${a_path} vs ${b_path}."
  fi
fi

scoreboard_json_path="${arena_dir}/scoreboard.json"
scoreboard_md_path="${arena_dir}/scoreboard.md"
scoreboard_txt_path="${arena_dir}/scoreboard.txt"

indices_config_path="funds/arena/indices.json"
arena_inception_date="$(printf '%s' "$lanes_json" | jq -r '
  ([.[] | select(.inception_date != null and .inception_date != "") | .inception_date] | min) // empty
')"
if [[ -z "$arena_inception_date" ]]; then
  arena_inception_date="$run_date"
fi

indices_json="$(jq -n '{start_date:null,end_date:null,asof_price_date:null,items:[]}')"
if [[ -f "$indices_config_path" ]]; then
  indices_json="$(node scripts/index_performance.mjs "$arena_inception_date" "$run_date" "$indices_config_path" 2>/dev/null || printf '%s' "$indices_json")"
fi

jq -n \
  --arg run_date "$run_date" \
  --argjson lanes "$lanes_json" \
  --argjson overlap "$overlap_pct" \
  --argjson turnover "$turnover_pct" \
  --argjson indices "$indices_json" \
  --arg ranking_notes "$ranking_notes" \
  --arg notes "$comparison_notes" \
  '{
    run_date: $run_date,
    lanes: $lanes,
    indices: $indices,
    ranking: {
      method: "independent_performance",
      notes: $ranking_notes
    },
    comparison: {
      portfolio_overlap_pct: $overlap,
      turnover_estimate_pct: $turnover,
      notes: $notes
    }
  }' > "$scoreboard_json_path"

{
  echo "# Fund Arena Scoreboard (${run_date})"
  echo
  echo "## Board"
  echo "- Overlap: $(jq -r '.comparison.portfolio_overlap_pct' "$scoreboard_json_path")%"
  echo "- Est. turnover: $(jq -r '.comparison.turnover_estimate_pct' "$scoreboard_json_path")%"
  echo
  if [[ "$(jq -r '(.indices.items // []) | length' "$scoreboard_json_path")" -gt 0 ]]; then
    echo "## Indices"
    idx_asof="$(jq -r '.indices.asof_price_date // empty' "$scoreboard_json_path")"
    if [[ -n "$idx_asof" ]]; then
      echo "- As of: ${idx_asof} close"
    fi
	    jq -r '.indices.items[] |
	      def fmt_pct($v):
	        if $v == null then "-" else ((if ($v | tonumber) >= 0 then "+" else "" end) + (((($v | tonumber) * 100 | round) / 100) | tostring) + "%") end;
	      "- " + (.name // .ticker) + ": " + fmt_pct(.return_pct)
	    ' "$scoreboard_json_path"
    echo
  fi
  echo "## Lanes"
	  jq -r '.lanes[] |
	    def fmt_pct($v):
	      if $v == null then "-" else ((if ($v | tonumber) >= 0 then "+" else "" end) + (((($v | tonumber) * 100 | round) / 100) | tostring) + "%") end;
	    (.benchmark_name // .benchmark_ticker // "Benchmark") as $bm |
	    (.asof_price_date // "n/a") as $asof |
	    (.inception_date // "n/a") as $start |
    "- " + (.fund_id + "/" + .provider)
    + ": "
    + (if .status == "success" then "On track" else "Issue" end)
    + (if .status == "success" and .fund_return_pct != null
        then (" - since " + $start + ": " + fmt_pct(.fund_return_pct)
          + (if .benchmark_return_pct != null then (" vs " + $bm + " " + fmt_pct(.benchmark_return_pct)) else "" end)
          + (if .excess_return_pct != null then (" (excess " + fmt_pct(.excess_return_pct) + ")") else "" end)
          + (" as of " + $asof)
        )
        else ""
      end)
  ' "$scoreboard_json_path"
  echo
  echo "## Actions"
  jq -r '.lanes[] |
    "- " + (.fund_id + "/" + .provider) + ": "
    + (if .status == "success"
        then (
          if (.action == "Do nothing") then "No changes"
          elif (.action == "Add") then ("Added " + (.add_ticker // "?"))
          elif (.action == "Trim") then ("Trimmed " + (.remove_ticker // "?") + " -> " + (.add_ticker // "?"))
          elif (.action == "Replace") then ("Replaced " + (.remove_ticker // "?") + " -> " + (.add_ticker // "?"))
          else (.action // "Unknown")
          end
        )
        else "No run"
      end)
  ' "$scoreboard_json_path"
  echo
  echo "## Notes"
  echo "- Ranking: $(jq -r '.ranking.notes' "$scoreboard_json_path")"
  echo "- Data: $(jq -r '.comparison.notes' "$scoreboard_json_path")"
} > "$scoreboard_md_path"

{
  echo "Fund Arena Scoreboard (${run_date})"
  echo

  asof_common="$(jq -r '[.lanes[] | select(.status == "success") | .asof_price_date] | map(select(. != null)) | sort | first // empty' "$scoreboard_json_path")"
  if [[ -n "$asof_common" ]]; then
    echo "As of: ${asof_common} close"
    echo
  fi

	  jq -r '.lanes[] |
	    def fmt_pct($v):
	      if $v == null then "-" else ((if ($v | tonumber) >= 0 then "+" else "" end) + (((($v | tonumber) * 100 | round) / 100) | tostring) + "%") end;
	    def fund_label($id):
      if ($id | test("^fund-[a-zA-Z]$")) then
        "Fund " + (($id | split("-") | .[1]) | ascii_upcase)
      else
        ($id | gsub("-"; " ") | split(" ") | map(.[:1] | ascii_upcase + .[1:]) | join(" "))
      end;
    def provider_label($p):
      if $p == "openai" then "OpenAI"
      elif $p == "anthropic" then "Anthropic"
      elif $p == "xai" then "xAI"
      else ($p | .[:1] | ascii_upcase) + ($p | .[1:] | ascii_downcase)
      end;
    (.benchmark_name // .benchmark_ticker // "Benchmark") as $bm |
    (fund_label(.fund_id) + " (" + provider_label(.provider) + ")") as $lane |
    (if .status == "success" then "On track" else "Issue" end) as $status |
    (if .status == "success"
      then (
        if (.action == "Do nothing") then "No changes"
        elif (.action == "Add") then ("Added " + (.add_ticker // "?"))
        elif (.action == "Trim") then ("Trimmed " + (.remove_ticker // "?") + " -> " + (.add_ticker // "?"))
        elif (.action == "Replace") then ("Replaced " + (.remove_ticker // "?") + " -> " + (.add_ticker // "?"))
        else (.action // "Unknown")
        end
      )
      else "No run"
    end) as $action |
	    (if .status == "success" and .fund_return_pct != null then fmt_pct(.fund_return_pct) else "-" end) as $fund |
	    (if .status == "success" and .benchmark_return_pct != null then fmt_pct(.benchmark_return_pct) else "-" end) as $bmret |
	    (if .status == "success" and .excess_return_pct != null then fmt_pct(.excess_return_pct) else "-" end) as $excess |
	    ((.rank | tostring) + ". " + $lane + " - " + $status + " | " + $action + " | Perf " + $fund
	      + (if $bmret != "-" then (" vs " + $bm + " " + $bmret) else "" end)
	      + (if $excess != "-" then (" (excess " + $excess + ")") else "" end)
	    )
	  ' "$scoreboard_json_path"
} > "$scoreboard_txt_path"

echo "Wrote ${scoreboard_json_path}"
echo "Wrote ${scoreboard_md_path}"
echo "Wrote ${scoreboard_txt_path}"
