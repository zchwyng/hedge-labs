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

  if [[ -f "$meta_path" ]]; then
    status="$(jq -r '.status // "failed"' "$meta_path")"
  fi

  if [[ "$status" == "success" && -f "$output_path" ]]; then
    action="$(jq -r '.trade_of_the_day.action // "UNKNOWN"' "$output_path")"
    add_ticker="$(jq -r '.trade_of_the_day.add_ticker // empty' "$output_path")"
    remove_ticker="$(jq -r '.trade_of_the_day.remove_ticker // empty' "$output_path")"
    size_change_pct="$(jq -r '.trade_of_the_day.size_change_pct // 0' "$output_path")"
    constraints_ok="$(jq -r '((.constraints_check.max_position_ok // false) and (.constraints_check.max_sector_ok // false))' "$output_path")"
  fi

  jq -n \
    --arg fund_id "$fund_id" \
    --arg provider "$provider" \
    --arg status "$status" \
    --arg action "$action" \
    --arg add_ticker "$add_ticker" \
    --arg remove_ticker "$remove_ticker" \
    --arg run_path "$run_path" \
    --argjson size_change_pct "$size_change_pct" \
    --argjson constraints_ok "$constraints_ok" \
    '{
      fund_id: $fund_id,
      provider: $provider,
      status: $status,
      action: $action,
      add_ticker: (if $add_ticker == "" then null else $add_ticker end),
      remove_ticker: (if $remove_ticker == "" then null else $remove_ticker end),
      size_change_pct: $size_change_pct,
      constraints_ok: $constraints_ok,
      run_path: $run_path
    }' >> "$lanes_tmp"
done

lanes_json="$(jq -s '.' "$lanes_tmp")"

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

jq -n \
  --arg run_date "$run_date" \
  --argjson lanes "$lanes_json" \
  --argjson overlap "$overlap_pct" \
  --argjson turnover "$turnover_pct" \
  --arg notes "$comparison_notes" \
  '{
    run_date: $run_date,
    lanes: $lanes,
    comparison: {
      portfolio_overlap_pct: $overlap,
      turnover_estimate_pct: $turnover,
      notes: $notes
    }
  }' > "$scoreboard_json_path"

{
  echo "# Fund Arena Scoreboard (${run_date})"
  echo
  echo "| Lane | Status | Action | Change | Constraints |"
  echo "|---|---|---|---|---|"
  jq -r '.lanes[] |
    . as $lane |
    ($lane.fund_id + "/" + $lane.provider) as $lane_name |
    (if $lane.add_ticker != null or $lane.remove_ticker != null
      then ((if $lane.remove_ticker != null then $lane.remove_ticker else "-" end) + " -> " + (if $lane.add_ticker != null then $lane.add_ticker else "-" end))
      else "-"
    end) as $change |
    [
      $lane_name,
      $lane.status,
      $lane.action,
      $change,
      (if $lane.constraints_ok then "OK" else "FAIL" end)
    ] | "| " + join(" | ") + " |"' "$scoreboard_json_path"
  echo
  echo "- Portfolio overlap: $(jq -r '.comparison.portfolio_overlap_pct' "$scoreboard_json_path")%"
  echo "- Turnover estimate: $(jq -r '.comparison.turnover_estimate_pct' "$scoreboard_json_path")%"
  echo "- Notes: $(jq -r '.comparison.notes' "$scoreboard_json_path")"
} > "$scoreboard_md_path"

echo "Wrote ${scoreboard_json_path}"
echo "Wrote ${scoreboard_md_path}"
