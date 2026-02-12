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

sanitize_watchouts() {
  local raw="$1"
  local cleaned
  cleaned="$(sanitize_one_line "$raw")"
  cleaned="$(printf '%s' "$cleaned" | perl -pe '
    s{https?://\S+}{}gi;
    s/\((?:[^()]*\bsources?(?:\s+context)?\b[^()]*)\)//gi;
    s/\bsources?(?:\s+context)?\s*:\s*[^;]+//gi;
    s/\s{2,}/ /g;
    s/\s+([,;:.])/$1/g;
    s/^\s+|\s+$//g;
  ')"
  if [[ -z "$cleaned" ]]; then
    cleaned="n/a"
  fi
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

format_holdings_table() {
  local json_path="$1"
  node - "$json_path" <<'NODE'
const fs = require('node:fs');

function fmtWeight(x) {
  const v = Number(x || 0);
  if (!Number.isFinite(v)) return '0%';
  if (v === Math.trunc(v)) return `${v.toFixed(0)}%`;
  if (Math.round(v * 10) === v * 10) return `${v.toFixed(1)}%`;
  return `${v.toFixed(2)}%`;
}

function normSymbol(s) {
  return String(s || '').trim().toUpperCase().replace(/-/g, '.');
}

async function fetchCompanyNames(tickers) {
  const out = {};
  if (!Array.isArray(tickers) || tickers.length === 0) return out;
  const period2 = Math.floor(Date.now() / 1000);
  const period1 = period2 - (14 * 86400);

  async function fetchNameForTicker(ticker) {
    const candidates = [ticker];
    if (ticker.includes('.')) candidates.push(ticker.replace(/\./g, '-'));
    if (ticker.includes('-')) candidates.push(ticker.replace(/-/g, '.'));

    for (const symbol of [...new Set(candidates)]) {
      const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?interval=1d&period1=${period1}&period2=${period2}`;
      try {
        const res = await fetch(url, {
          headers: {
            'User-Agent': 'hedge-labs-fund-arena/1.0'
          }
        });
        if (!res.ok) continue;
        const data = await res.json();
        const meta = data?.chart?.result?.[0]?.meta;
        const name = String(meta?.longName || meta?.shortName || '').trim();
        if (name) return name.replace(/\|/g, '/');
      } catch {
        // Try next symbol alias.
      }
    }
    return '';
  }

  await Promise.all(tickers.map(async (ticker) => {
    const name = await fetchNameForTicker(ticker);
    if (name) out[normSymbol(ticker)] = name;
  }));

  return out;
}

(async () => {
  const path = process.argv[2];
  let doc = {};
  try {
    doc = JSON.parse(fs.readFileSync(path, 'utf8'));
  } catch {
    doc = {};
  }

  const holdings = Array.isArray(doc?.target_portfolio) ? [...doc.target_portfolio] : [];
  holdings.sort((a, b) => {
    const wa = Number(a?.weight_pct || 0);
    const wb = Number(b?.weight_pct || 0);
    if (wb !== wa) return wb - wa;
    const ta = String(a?.ticker || '');
    const tb = String(b?.ticker || '');
    return ta.localeCompare(tb);
  });

  console.log('```text');
  if (holdings.length === 0) {
    console.log('n/a');
    console.log('```');
    return;
  }

  const tickers = [...new Set(holdings.map((h) => String(h?.ticker || '').trim()).filter(Boolean))];
  const companyNames = await fetchCompanyNames(tickers);

  console.log('Ticker | Name | Wt | Sector');
  console.log('--- | --- | --- | ---');
  for (const h of holdings) {
    const ticker = String(h?.ticker || 'UNKNOWN').trim() || 'UNKNOWN';
    const sector = String(h?.sector || 'UNKNOWN').trim() || 'UNKNOWN';
    const name = companyNames[normSymbol(ticker)] || ticker;
    console.log(`${ticker} | ${name} | ${fmtWeight(h?.weight_pct)} | ${sector}`);
  }
  console.log('```');
})().catch(() => {
  console.log('```text');
  console.log('n/a');
  console.log('```');
});
NODE
}

format_sector_exposure_summary() {
  local json_path="$1"
  jq -r '
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
        ) as $rows
        | ($rows[0:4]
          | map(.sector + " " + ((.weight * 100 | round) / 100 | tostring) + "%")
        ) as $top
        | (($rows[4:] | map(.weight) | add) // 0) as $other
        | if $other > 0 then
            ($top + ["Other " + (($other * 100 | round) / 100 | tostring) + "%"] | join(", "))
          else
            ($top | join(", "))
          end
      end
  ' "$json_path"
}

latest_successful_output_before_run() {
  local fund_id="$1"
  local provider="$2"
  local run_date="$3"
  local runs_root="funds/${fund_id}/runs"
  local prev_output=""
  local prev_date=""
  local candidate_output=""
  local candidate_meta=""
  local candidate_status=""

  if [[ -d "$runs_root" ]]; then
    while IFS= read -r d; do
      [[ "$d" < "$run_date" ]] || continue
      candidate_output="${runs_root}/${d}/${provider}/dexter_output.json"
      candidate_meta="${runs_root}/${d}/${provider}/run_meta.json"
      if [[ ! -f "$candidate_output" ]]; then
        continue
      fi
      if [[ -f "$candidate_meta" ]]; then
        candidate_status="$(jq -r '.status // "failed"' "$candidate_meta")"
        [[ "$candidate_status" == "success" ]] || continue
      fi
      prev_output="$candidate_output"
      prev_date="$d"
    done < <(find "$runs_root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort)
  fi

  printf '%s\t%s\n' "$prev_output" "$prev_date"
}

output_has_holdings() {
  local json_path="$1"
  if [[ ! -f "$json_path" ]]; then
    return 1
  fi
  jq -e '(.target_portfolio // []) | type == "array" and length > 0' "$json_path" >/dev/null 2>&1
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
  fund_name_label="n/a"
  benchmark_ticker=""
  benchmark_label=""
  benchmark_display="n/a"
  risk_snippet="n/a"
  holdings_block='```text
n/a
```'
  holdings_heading="Holdings:"
  change_reason_block="  • n/a"
  error_message=""
  api_notice_block=""
  model_label="unknown"
  prev_output_path=""
  prev_output_date=""

  IFS=$'\t' read -r prev_output_path prev_output_date < <(latest_successful_output_before_run "$fund_id" "$provider" "$run_date")

  if [[ -f "$config_path" ]]; then
    fund_name_label="$(jq -r '.name // "n/a"' "$config_path")"
    fund_type_label="$(jq -r '.universe // "n/a"' "$config_path")"
    model_label="$(jq -r '.model // "unknown"' "$config_path")"
    benchmark_ticker="$(jq -r '.benchmark.ticker // .benchmark_ticker // empty' "$config_path")"
    benchmark_label="$(jq -r '.benchmark.name // .benchmark_label // .benchmark.ticker // .benchmark_ticker // empty' "$config_path")"
    if [[ -n "$benchmark_ticker" && -n "$benchmark_label" && "$benchmark_label" != "$benchmark_ticker" ]]; then
      benchmark_display="${benchmark_label} (\`${benchmark_ticker}\`)"
    elif [[ -n "$benchmark_label" ]]; then
      benchmark_display="$benchmark_label"
    elif [[ -n "$benchmark_ticker" ]]; then
      benchmark_display="\`${benchmark_ticker}\`"
    fi
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
    action_add_ticker="$add_ticker"
    action_remove_ticker="$remove_ticker"
    if [[ -z "$action_add_ticker" || "$action_add_ticker" == "-" ]]; then
      action_add_ticker="$(jq -r '.trade_of_the_day.add_ticker // empty' "$output_path")"
    fi
    if [[ -z "$action_remove_ticker" || "$action_remove_ticker" == "-" ]]; then
      action_remove_ticker="$(jq -r '.trade_of_the_day.remove_ticker // empty' "$output_path")"
    fi
    trade_text="$(jq -r '[.trade_of_the_day.thesis[]?, .trade_of_the_day.why_now?, .constraints_check.notes?] | map(select(type=="string")) | join(" ")' "$output_path")"
    if [[ -z "$action_add_ticker" || "$action_add_ticker" == "-" ]]; then
      inferred_add_from_text="$(
        printf '%s' "$trade_text" | perl -ne '
          if (/\breplace(?:d|ing)?\s+[A-Z][A-Z0-9.\-]{0,9}\s+(?:with|for)\s+([A-Z][A-Z0-9.\-]{0,9})\b/i) { print uc($1); exit }
          if (/\badd(?:ed|ing)?\s+([A-Z][A-Z0-9.\-]{0,9})\b/i) { print uc($1); exit }
          if (/\bincrease(?:d|ing)?\s+([A-Z][A-Z0-9.\-]{0,9})\b/i) { print uc($1); exit }
        '
      )"
      if [[ -n "$inferred_add_from_text" ]]; then
        action_add_ticker="$inferred_add_from_text"
      fi
    fi
    if [[ -z "$action_remove_ticker" || "$action_remove_ticker" == "-" ]]; then
      inferred_remove_from_text="$(
        printf '%s' "$trade_text" | perl -ne '
          if (/\breplace(?:d|ing)?\s+([A-Z][A-Z0-9.\-]{0,9})\s+(?:with|for)\s+[A-Z][A-Z0-9.\-]{0,9}\b/i) { print uc($1); exit }
          if (/\btrim(?:med|ming)?\s+([A-Z][A-Z0-9.\-]{0,9})\b/i) { print uc($1); exit }
          if (/\breduce(?:d|ing)?\s+([A-Z][A-Z0-9.\-]{0,9})\b/i) { print uc($1); exit }
        '
      )"
      if [[ -n "$inferred_remove_from_text" ]]; then
        action_remove_ticker="$inferred_remove_from_text"
      fi
    fi
    if [[ -z "$action_add_ticker" ]]; then action_add_ticker="-"; fi
    if [[ -z "$action_remove_ticker" ]]; then action_remove_ticker="-"; fi
    case "$action" in
      "Do nothing")
        action_summary="No portfolio change today."
        ;;
      "Add")
        action_summary="Added ${action_add_ticker} (${size_change}% target weight change)."
        ;;
      "Trim")
        if [[ -n "$action_remove_ticker" && "$action_remove_ticker" != "-" && -n "$action_add_ticker" && "$action_add_ticker" != "-" ]]; then
          action_summary="Trimmed ${action_remove_ticker}, reallocated to ${action_add_ticker} (${size_change}% target weight change)."
        else
          action_summary="Trimmed ${action_remove_ticker} (${size_change}% target weight change)."
        fi
        ;;
      "Replace")
        action_summary="Replaced ${action_remove_ticker} with ${action_add_ticker} (${size_change}% target weight change)."
        ;;
      *)
        action_summary="Model action: ${action}."
        ;;
    esac

    holdings_block="$(format_holdings_table "$output_path")"

    risk_snippet="$(jq -r '(.trade_of_the_day.risks // [] | map(select(type == "string")) | .[:2] | join("; ")) // "n/a"' "$output_path")"
    risk_snippet="$(sanitize_watchouts "$risk_snippet")"
    if [[ -z "$risk_snippet" ]]; then
      risk_snippet="n/a"
    fi

    perf_json="$(node scripts/performance_since_added.mjs "$fund_id" "$provider" "$run_date" "$benchmark_ticker" "$benchmark_label" 2>/dev/null || echo '{}')"

    fund_return_pct="$(jq -r '.fund_return_pct // empty' <<<"$perf_json")"
    coverage_pct="$(jq -r '.covered_weight_pct // empty' <<<"$perf_json")"
    benchmark_name="$(jq -r '.benchmark_name // empty' <<<"$perf_json")"
    benchmark_return_pct="$(jq -r '.benchmark_return_pct // empty' <<<"$perf_json")"
    benchmark_coverage_pct="$(jq -r '.benchmark_covered_weight_pct // empty' <<<"$perf_json")"
    excess_return_pct="$(jq -r '.excess_return_pct // empty' <<<"$perf_json")"

    if [[ -z "$benchmark_name" && -n "$benchmark_label" ]]; then
      benchmark_name="$benchmark_label"
    fi
    if [[ -z "$benchmark_name" && -n "$benchmark_ticker" ]]; then
      benchmark_name="$benchmark_ticker"
    fi

    if [[ -n "$fund_return_pct" ]]; then
      fund_perf="$(printf "%+.2f%%" "$fund_return_pct")"
      performance_summary="Fund ${fund_perf}"
      if [[ -n "$coverage_pct" ]]; then
        performance_summary+=" (cov ${coverage_pct}%)"
      fi

      if [[ -n "$benchmark_return_pct" && -n "$benchmark_name" ]]; then
        benchmark_perf="$(printf "%+.2f%%" "$benchmark_return_pct")"
        performance_summary+=" vs ${benchmark_name} ${benchmark_perf}"
        if [[ -n "$excess_return_pct" ]]; then
          performance_summary+=" (Δ $(printf "%+.2fpp" "$excess_return_pct"))"
        fi
        if [[ -n "$benchmark_coverage_pct" && "$benchmark_coverage_pct" != "$coverage_pct" ]]; then
          performance_summary+=" [idx cov ${benchmark_coverage_pct}%]"
        fi
      fi

      perf_rows="$(jq -cn --argjson rows "$perf_rows" --arg fund "$fund_label" --argjson ret "$fund_return_pct" '$rows + [{fund: $fund, ret: $ret}]')"
    elif [[ -n "$benchmark_return_pct" && -n "$benchmark_name" ]]; then
      benchmark_perf="$(printf "%+.2f%%" "$benchmark_return_pct")"
      performance_summary="Fund n/a vs ${benchmark_name} ${benchmark_perf}"
    fi

    sector_exposure_summary="$(format_sector_exposure_summary "$output_path")"

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
      if [[ "$change_count" != "0" ]]; then
        if [[ -z "$action_add_ticker" || "$action_add_ticker" == "-" ]]; then
          inferred_add_ticker="$(jq -r '[.[] | select(.delta > 0)] | sort_by(-.delta, .ticker) | .[0].ticker // empty' <<<"$change_rows")"
          if [[ -n "$inferred_add_ticker" ]]; then
            action_add_ticker="$inferred_add_ticker"
          fi
        fi
        if [[ -z "$action_remove_ticker" || "$action_remove_ticker" == "-" ]]; then
          inferred_remove_ticker="$(jq -r '[.[] | select(.delta < 0)] | sort_by(.delta, .ticker) | .[0].ticker // empty' <<<"$change_rows")"
          if [[ -n "$inferred_remove_ticker" ]]; then
            action_remove_ticker="$inferred_remove_ticker"
          fi
        fi
      fi

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

    case "$action" in
      "Add")
        if [[ -n "$action_add_ticker" && "$action_add_ticker" != "-" ]]; then
          action_summary="Added ${action_add_ticker} (${size_change}% target weight change)."
        fi
        ;;
      "Trim")
        if [[ -n "$action_remove_ticker" && "$action_remove_ticker" != "-" && -n "$action_add_ticker" && "$action_add_ticker" != "-" ]]; then
          action_summary="Trimmed ${action_remove_ticker}, reallocated to ${action_add_ticker} (${size_change}% target weight change)."
        elif [[ -n "$action_remove_ticker" && "$action_remove_ticker" != "-" ]]; then
          action_summary="Trimmed ${action_remove_ticker} (${size_change}% target weight change)."
        fi
        ;;
      "Replace")
        if [[ -n "$action_remove_ticker" && "$action_remove_ticker" != "-" && -n "$action_add_ticker" && "$action_add_ticker" != "-" ]]; then
          action_summary="Replaced ${action_remove_ticker} with ${action_add_ticker} (${size_change}% target weight change)."
        elif [[ -n "$action_remove_ticker" && "$action_remove_ticker" != "-" ]]; then
          action_summary="Replaced ${action_remove_ticker} (add target not specified) (${size_change}% target weight change)."
        elif [[ -n "$action_add_ticker" && "$action_add_ticker" != "-" ]]; then
          action_summary="Replaced holding with ${action_add_ticker} (${size_change}% target weight change)."
        fi
        ;;
    esac
  fi

  if [[ "$status" != "success" ]]; then
    if output_has_holdings "$output_path"; then
      holdings_block="$(format_holdings_table "$output_path")"
      sector_exposure_summary="$(format_sector_exposure_summary "$output_path")"
      holdings_heading="Holdings (latest run output):"
    elif [[ -n "$prev_output_path" && -f "$prev_output_path" ]]; then
      holdings_block="$(format_holdings_table "$prev_output_path")"
      sector_exposure_summary="$(format_sector_exposure_summary "$prev_output_path")"
      if [[ -n "$prev_output_date" ]]; then
        holdings_heading="Holdings (last successful run ${prev_output_date}):"
      else
        holdings_heading="Holdings (last successful run):"
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
  lane_sections+="- Fund name: ${fund_name_label}"
  lane_sections+=$'\n'
  lane_sections+="- Fund type: ${fund_type_label}"
  lane_sections+=$'\n'
  lane_sections+="- Benchmark: ${benchmark_display}"
  lane_sections+=$'\n'
  lane_sections+="- Sector exposure: ${sector_exposure_summary}"
  lane_sections+=$'\n'
  lane_sections+="- Model: \`${model_label}\`"
  lane_sections+=$'\n'
  lane_sections+="- Status: ${status_emoji} **${status_label}**"
  lane_sections+=$'\n'
  lane_sections+="- Today: ${action_summary}"
  if [[ "$constraints_ok" != "true" ]]; then
    lane_sections+=$'\n'
    lane_sections+="- Risk limits: ${constraints_label}"
  fi
  lane_sections+=$'\n'
  lane_sections+="- Since added: **${performance_summary}**"
  if [[ -n "$api_notice_block" ]]; then
    lane_sections+=$'\n'
    lane_sections+="- API notices:"
    lane_sections+=$'\n'
    lane_sections+="$api_notice_block"
  fi

  if [[ -n "$error_message" ]]; then
    lane_sections+=$'\n'
    lane_sections+="- ❗ Error: **${error_message}**"
  fi

  lane_sections+=$'\n'
  lane_sections+="- ${holdings_heading}"
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
    compact_message="$(printf '%s' "$compact_message" | perl -0pe 's/^-\s*Since added(?: \(fund\))?:.*\n//mg')"
  fi
  if (( ${#compact_message} > max_len )); then
    compact_message="$(printf '%s' "$compact_message" | perl -0pe 's/^-\s*Risk limits:.*\n//mg')"
  fi
  if (( ${#compact_message} > max_len )); then
    compact_message="$(printf '%s' "$compact_message" | perl -0pe 's/^-\s*Sector exposure:.*\n//mg')"
  fi
  if (( ${#compact_message} <= max_len )); then
    message="$compact_message"
  else
    while (( ${#compact_message} > max_len )) && [[ "$compact_message" == *$'\n'* ]]; do
      compact_message="${compact_message%$'\n'*}"
    done
    if (( ${#compact_message} > max_len )); then
      compact_message="${compact_message:0:max_len}"
    fi
    message="$compact_message"
  fi
fi

jq -Rn --arg content "$message" '{content: $content, flags: 4}'
