#!/usr/bin/env bash
# build_pages_data.sh — Aggregate all arena scoreboards + latest holdings into docs/data.json
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS_DIR="${REPO_ROOT}/docs"
DATA_PATH="${DOCS_DIR}/data.json"

mkdir -p "$DOCS_DIR"

# ---------------------------------------------------------------------------
# 1. Fund metadata from fund.config.json files
# ---------------------------------------------------------------------------
funds_json="$(jq -n '{}')"
fund_colors='{"fund-a":"#3b82f6","fund-b":"#a855f7","fund-c":"#f97316"}'

for config_path in "${REPO_ROOT}"/funds/fund-*/fund.config.json; do
  [ -f "$config_path" ] || continue
  fund_dir="$(dirname "$config_path")"
  fund_id="$(basename "$fund_dir")"
  color="$(jq -r --arg id "$fund_id" '.[$id] // "#6b7280"' <<< "$fund_colors")"

  fund_meta="$(jq --arg color "$color" '{
    provider: .provider,
    model:    .model,
    name:     .name,
    benchmark: .benchmark,
    positions: .positions,
    color:    $color
  }' "$config_path")"

  funds_json="$(jq --arg id "$fund_id" --argjson meta "$fund_meta" \
    '.[$id] = $meta' <<< "$funds_json")"
done

# ---------------------------------------------------------------------------
# 2. Collect every scoreboard.json, sorted by date
# ---------------------------------------------------------------------------
days_json="$(jq -n '[]')"

for scoreboard_path in "${REPO_ROOT}"/funds/arena/runs/*/scoreboard.json; do
  [ -f "$scoreboard_path" ] || continue

  day_entry="$(jq '{
    date: .run_date,
    lanes: [.lanes[] | {
      fund_id, provider, status, action,
      fund_return_pct, benchmark_return_pct, excess_return_pct,
      rank, inception_date, asof_price_date,
      add_ticker, remove_ticker, rebalance_actions_preview
    }],
    indices: {
      asof_price_date: .indices.asof_price_date,
      items: [(.indices.items // [])[] | {ticker, name, return_pct}]
    },
    comparison: {
      portfolio_overlap_pct: .comparison.portfolio_overlap_pct,
      turnover_estimate_pct: .comparison.turnover_estimate_pct
    }
  }' "$scoreboard_path")"

  days_json="$(jq --argjson entry "$day_entry" '. + [$entry]' <<< "$days_json")"
done

days_json="$(jq 'sort_by(.date)' <<< "$days_json")"

# ---------------------------------------------------------------------------
# 2.5 Overlay fresh daily performance (re-fetches prices for accurate daily NAV)
# ---------------------------------------------------------------------------
daily_nav="$(node "${REPO_ROOT}/scripts/compute_daily_nav.mjs" 2>/dev/null || echo '{}')"

if [ "$(jq -r 'has("funds")' <<< "$daily_nav")" = "true" ]; then
  days_json="$(jq --argjson nav "$daily_nav" '
    [.[] | . as $day |
      ($nav.funds[$day.date] // null) as $fp |
      ($nav.indices[$day.date] // null) as $ip |
      # Overlay fresh fund performance onto lanes
      (if $fp then
        .lanes = [.lanes[] |
          ($fp[.fund_id] // null) as $perf |
          if $perf and .status == "success" then
            .fund_return_pct = $perf.fund_return_pct |
            .benchmark_return_pct = $perf.benchmark_return_pct |
            .excess_return_pct = $perf.excess_return_pct |
            .asof_price_date = $perf.asof_price_date
          else . end
        ]
      else . end) |
      # Overlay fresh index performance
      (if $ip then
        .indices = $ip
      else . end)
    ]
  ' <<< "$days_json")"
  echo "Overlaid fresh daily performance data."
fi

# ---------------------------------------------------------------------------
# 3. Latest holdings from the most recent successful dexter_output.json per fund
# ---------------------------------------------------------------------------
holdings_json="$(jq -n '{}')"

for fund_dir in "${REPO_ROOT}"/funds/fund-*; do
  [ -d "$fund_dir" ] || continue
  fund_id="$(basename "$fund_dir")"
  config_path="${fund_dir}/fund.config.json"
  [ -f "$config_path" ] || continue
  provider="$(jq -r '.provider // empty' "$config_path")"
  [ -n "$provider" ] || continue

  latest_output=""
  for date_dir in $(find "${fund_dir}/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r); do
    candidate="${date_dir}/${provider}/dexter_output.json"
    meta="${date_dir}/${provider}/run_meta.json"
    if [ -f "$candidate" ] && [ -f "$meta" ]; then
      status="$(jq -r '.status // "failed"' "$meta")"
      if [ "$status" = "success" ]; then
        latest_output="$candidate"
        break
      fi
    fi
  done

  if [ -n "$latest_output" ] && [ -f "$latest_output" ]; then
    portfolio="$(jq '[(.target_portfolio // [])[] | {ticker, weight_pct, sector}]' "$latest_output")"
    holdings_json="$(jq --arg id "$fund_id" --argjson p "$portfolio" \
      '.[$id] = $p' <<< "$holdings_json")"
  fi
done

# ---------------------------------------------------------------------------
# 4. Assemble final data.json
# ---------------------------------------------------------------------------
generated_at="$(date -u +%FT%TZ)"

jq -n \
  --arg generated_at "$generated_at" \
  --argjson funds "$funds_json" \
  --argjson days "$days_json" \
  --argjson latest_holdings "$holdings_json" \
  '{
    generated_at: $generated_at,
    funds: $funds,
    days: $days,
    latest_holdings: $latest_holdings
  }' > "$DATA_PATH"

echo "Wrote ${DATA_PATH}"
