#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 <run_date> [fund_id_filter] [no-header|overall-only]" >&2
  exit 64
fi

run_date="$1"
arg2="${2:-}"
arg3="${3:-}"
fund_filter=""
mode=""

is_mode() {
  case "${1:-}" in
    no-header|overall-only) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ -n "$arg2" && -n "$arg3" ]]; then
  fund_filter="$arg2"
  mode="$arg3"
elif [[ -n "$arg2" ]]; then
  if is_mode "$arg2"; then
    mode="$arg2"
  else
    fund_filter="$arg2"
  fi
fi

include_header="true"
if [[ "$mode" == "no-header" ]]; then
  include_header="false"
fi
scoreboard_path="funds/arena/runs/${run_date}/scoreboard.json"
scoreboard_repo_path="funds/arena/runs/${run_date}/scoreboard.txt"
scoreboard_repo_path_fallback="funds/arena/runs/${run_date}/scoreboard.md"

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
  const maxRows = Number(process.env.DISCORD_HOLDINGS_MAX_ROWS || '25');
  const safeMaxRows = Number.isFinite(maxRows) && maxRows >= 5 ? Math.floor(maxRows) : 25;

  console.log('% | Ticker | Name');
  console.log('--- | --- | ---');
  const shown = holdings.slice(0, safeMaxRows);
  for (const h of shown) {
    const ticker = String(h?.ticker || 'UNKNOWN').trim() || 'UNKNOWN';
    // Do not truncate company names; instead limit rows to stay within Discord message limits.
    const name = String(companyNames[normSymbol(ticker)] || ticker).trim() || ticker;
    console.log(`${fmtWeight(h?.weight_pct)} | ${ticker} | ${name}`);
  }
  if (holdings.length > shown.length) {
    console.log('');
    console.log(`(+${holdings.length - shown.length} more holdings not shown)`);
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

format_market_summary_block() {
  local json_path="$1"
  jq -r '
    (.market_summary // [])
    | map(select(type == "string" and length > 0))
    | map(
        # Avoid GitHub links in Discord output.
        gsub("https?://github\\.com/[^\\s)]+\\)?"; "")
        | gsub("github\\.com/[^\\s)]+\\)?"; "")
        | gsub("\\s{2,}"; " ")
        | sub("^\\s+"; "")
        | sub("\\s+$"; "")
      )
    | map(select(length > 0))
    | if length == 0 then
        ""
      else
        map("  • " + .) | join("\n")
      end
  ' "$json_path" 2>/dev/null || true
}

format_thesis_damage_block() {
  local json_path="$1"
  jq -r '
    (.thesis_damage_flags // [])
    | map(select(type == "object"))
    | map(
        (.ticker // "UNKNOWN") as $t
        | (.why // "")
        | if (type == "string" and length > 0) then
            "  • " + $t + ": " + .
          else
            empty
          end
      )
    | if length == 0 then
        ""
      else
        join("\n")
      end
  ' "$json_path" 2>/dev/null || true
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
scoreboard_url=""

all_success="$(jq -r '[.lanes[].status == "success"] | all' "$scoreboard_path")"
failed_count="$(jq -r '[.lanes[] | select(.status != "success")] | length' "$scoreboard_path")"
lane_count="$(jq -r '.lanes | length' "$scoreboard_path")"
overlap_pct="$(jq -r '.comparison.portfolio_overlap_pct // 0' "$scoreboard_path")"
turnover_pct="$(jq -r '.comparison.turnover_estimate_pct // 0' "$scoreboard_path")"
comparison_notes="$(jq -r '.comparison.notes // ""' "$scoreboard_path")"

if [[ "$all_success" == "true" ]]; then
  overall_emoji=""
  overall_line=""
else
  overall_emoji="🟠"
  overall_line="${failed_count}/${lane_count} lanes had issues; summary posted."
fi

lane_sections=""
fund_order=""
tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t hedge_labs_discord)"
trap 'rm -rf "$tmpdir"' EXIT

if [[ "$mode" != "overall-only" ]]; then

while IFS= read -r lane; do
  fund_id="$(jq -r '.fund_id' <<<"$lane")"
  if [[ -n "$fund_filter" && "$fund_id" != "$fund_filter" ]]; then
    continue
  fi
  provider="$(jq -r '.provider' <<<"$lane")"
  status="$(jq -r '.status' <<<"$lane")"
  action="$(jq -r '.action // "UNKNOWN"' <<<"$lane")"
  add_ticker="$(jq -r '.add_ticker // "-"' <<<"$lane")"
  remove_ticker="$(jq -r '.remove_ticker // "-"' <<<"$lane")"
  constraints_ok="$(jq -r '.constraints_ok' <<<"$lane")"
  run_path="$(jq -r '.run_path' <<<"$lane")"
  inception_date="$(jq -r '.inception_date // empty' <<<"$lane")"
  asof_portfolio_date="$(jq -r '.asof_portfolio_date // empty' <<<"$lane")"
  lane_benchmark_name="$(jq -r '.benchmark_name // empty' <<<"$lane")"
  lane_fund_return_pct="$(jq -r '.fund_return_pct // empty' <<<"$lane")"
  lane_benchmark_return_pct="$(jq -r '.benchmark_return_pct // empty' <<<"$lane")"
  lane_excess_return_pct="$(jq -r '.excess_return_pct // empty' <<<"$lane")"
  lane_coverage_pct="$(jq -r '.performance_coverage_pct // empty' <<<"$lane")"
  config_path="funds/${fund_id}/fund.config.json"

	  case "$provider" in
	    openai) provider_label="OpenAI" ;;
	    anthropic) provider_label="Anthropic" ;;
	    xai) provider_label="xAI" ;;
	    *) provider_label="$(printf '%s' "$provider" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')" ;;
	  esac

  fund_label="$(printf '%s' "$fund_id" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) tolower(substr($i,2))} print}')"
	  case "$fund_id" in
	    fund-a) fund_emoji="🟦" ;;
	    fund-b) fund_emoji="🟪" ;;
	    fund-c) fund_emoji="🟧" ;;
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
  stock_moves_summary="n/a"
  sector_exposure_summary="n/a"
  fund_type_label="n/a"
  fund_name_label="n/a"
  benchmark_ticker=""
  benchmark_label=""
  benchmark_display="n/a"
  since_start_line=""
  trade_reasoning_summary="n/a"
  risk_snippet="n/a"
  market_news_block=""
  thesis_damage_block=""
  rebalance_actions_summary="n/a"
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

  if [[ -z "$benchmark_label" && -n "$lane_benchmark_name" ]]; then
    benchmark_label="$lane_benchmark_name"
  fi

  if [[ -n "$lane_fund_return_pct" && -n "$inception_date" ]]; then
    fund_perf="$(printf "%+.2f%%" "$lane_fund_return_pct")"
    since_start_line="- Since start: Fund ${fund_perf}"
    if [[ -n "$lane_coverage_pct" && "$lane_coverage_pct" != "100" ]]; then
      since_start_line+=" (cov ${lane_coverage_pct}%)"
    fi

    if [[ -n "$lane_benchmark_return_pct" && -n "$benchmark_label" ]]; then
      benchmark_perf="$(printf "%+.2f%%" "$lane_benchmark_return_pct")"
      since_start_line+=" vs ${benchmark_label} ${benchmark_perf}"
      if [[ -n "$lane_excess_return_pct" ]]; then
        since_start_line+=" (Δ $(printf "%+.2fpp" "$lane_excess_return_pct"))"
      fi
    else
      since_start_line+=" (benchmark n/a)"
    fi

    since_start_line+=" since ${inception_date}"
    if [[ "$status" != "success" && -n "$asof_portfolio_date" && "$asof_portfolio_date" != "$run_date" ]]; then
      since_start_line+=" (stale since ${asof_portfolio_date})"
    fi
  fi

  if [[ -f "$meta_path" ]]; then
    model_label="$(jq -r '.model // "unknown"' "$meta_path")"
    api_notice_block="$(jq -r '
      def norm:
        gsub("[\r\n]+"; " ")
        | gsub("\\s+"; " ")
        | sub("^\\s+"; "")
        | sub("\\s+$"; "")
        | sub("^\"+"; "")
        | sub("\"+$"; "");
      def fd_rate_limited:
        test("financial[_ ]datasets|financial_search|financial_metrics|data unavailable \\(rate limited\\)|tool-?limited|due to tool rate limits|hit api rate limits|placeholder|financial data|company fundamentals|price data for"; "i");
      def classify_source:
        if fd_rate_limited then
          "Financial Datasets API"
        elif test("^\\[[^\\]]+ API\\]"; "i") then
          (capture("^\\[(?<src>[^\\]]+ API)\\]").src)
        elif test("openai|anthropic"; "i") and test("rate limit|quota|billing|insufficient_(quota|credits|balance)|unauthorized|forbidden|invalid api key"; "i") then
          "Model provider API"
        else
          "Unknown source"
        end;
      (.api_errors // [])
      | map(select(type == "string" and length > 0) | norm)
      | map(select(length > 0))
      | map(
          if fd_rate_limited then
            "Financial Datasets API: rate limited (model reported partial/placeholder data)."
          else
            (classify_source + ": " + .)
          end
        )
      | unique
      | .[:3]
      | if length == 0 then ""
        else map("  • " + .) | join("\n")
        end
    ' "$meta_path")"
  fi

  if [[ -f "$output_path" ]]; then
    market_news_block="$(format_market_summary_block "$output_path")"
    thesis_damage_block="$(format_thesis_damage_block "$output_path")"
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

    trade_reasoning_summary="$(jq -r '
      [
        (.trade_of_the_day.thesis // [] | map(select(type == "string")) | .[0]),
        (.trade_of_the_day.why_now // empty)
      ]
      | map(select(type == "string" and length > 0))
      | join(" ")
    ' "$output_path")"
    trade_reasoning_summary="$(sanitize_watchouts "$trade_reasoning_summary")"
    if [[ -z "$trade_reasoning_summary" || "$trade_reasoning_summary" == "n/a" ]]; then
      trade_reasoning_summary="n/a"
    fi

    risk_snippet="$(jq -r '(.trade_of_the_day.risks // [] | map(select(type == "string")) | .[:2] | join("; ")) // "n/a"' "$output_path")"
    risk_snippet="$(sanitize_watchouts "$risk_snippet")"
    if [[ -z "$risk_snippet" ]]; then
      risk_snippet="n/a"
    fi
    rebalance_actions_summary="$(jq -r '
      (.rebalance_actions // [])
      | map(
          .action as $a
          | .size_change_pct as $s
          | .remove_ticker as $r
          | .add_ticker as $ad
          | if $a == "Do nothing" then
              "Do nothing"
            elif $a == "Add" then
              ("Add " + ($ad // "?") + " (" + (($s // 0) | tostring) + "%)")
            elif $a == "Trim" then
              ("Trim " + ($r // "?") + "→" + ($ad // "?") + " (" + (($s // 0) | tostring) + "%)")
            elif $a == "Replace" then
              ("Replace " + ($r // "?") + "→" + ($ad // "?") + " (" + (($s // 0) | tostring) + "%)")
            else
              (($a // "UNKNOWN") + " (" + (($s // 0) | tostring) + "%)")
            end
        )
      | if length == 0 then "n/a" else join("; ") end
    ' "$output_path")"

    if [[ "$rebalance_actions_summary" == "n/a" ]]; then
      if [[ "$action" == "Do nothing" ]]; then
        rebalance_actions_summary="none"
      elif [[ "$action" == "Add" && -n "$action_add_ticker" && "$action_add_ticker" != "-" ]]; then
        rebalance_actions_summary="Inferred: Add ${action_add_ticker} (${size_change}%)"
      elif [[ "$action" == "Trim" && -n "$action_remove_ticker" && "$action_remove_ticker" != "-" && -n "$action_add_ticker" && "$action_add_ticker" != "-" ]]; then
        rebalance_actions_summary="Inferred: Trim ${action_remove_ticker}→${action_add_ticker} (${size_change}%)"
      elif [[ "$action" == "Replace" && -n "$action_remove_ticker" && "$action_remove_ticker" != "-" && -n "$action_add_ticker" && "$action_add_ticker" != "-" ]]; then
        rebalance_actions_summary="Inferred: Replace ${action_remove_ticker}→${action_add_ticker} (${size_change}%)"
      fi
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

  lane_block=""
  lane_block+=$'\n\n'
  lane_block+="**${fund_emoji} ${fund_label} (${provider_label})**"
  lane_block+=$'\n'
  lane_block+="- Name: ${fund_name_label}"
  lane_block+=$'\n'
  lane_block+="- Type: ${fund_type_label}"
  lane_block+=$'\n'
  lane_block+="- BM: ${benchmark_display}"
  if [[ -n "$since_start_line" ]]; then
    lane_block+=$'\n'
    lane_block+="${since_start_line}"
  fi
  lane_block+=$'\n'
  lane_block+="- Sectors: ${sector_exposure_summary}"
  lane_block+=$'\n'
  lane_block+="- Model: \`${model_label}\`"
  if [[ "$status" != "success" ]]; then
    lane_block+=$'\n'
    lane_block+="- Status: ${status_emoji} **${status_label}**"
  fi
  lane_block+=$'\n'
  lane_block+="- Today: ${action_summary}"
  if [[ "$rebalance_actions_summary" != "n/a" ]]; then
    lane_block+=$'\n'
    lane_block+="- Rebalance actions: ${rebalance_actions_summary}"
  fi

  if [[ -n "$error_message" ]]; then
    lane_block+=$'\n'
    lane_block+="- ❗ Error: **${error_message}**"
  fi

  lane_block+=$'\n'
  lane_block+="- ${holdings_heading}"
  lane_block+=$'\n'
  lane_block+="$holdings_block"

  # Keep holdings above lower-priority commentary so it doesn't get pushed out by Discord length trimming.
  if [[ -n "$market_news_block" ]]; then
    lane_block+=$'\n'
    lane_block+="- Market News:"
    lane_block+=$'\n'
    lane_block+="$market_news_block"
  fi
  if [[ -n "$thesis_damage_block" ]]; then
    lane_block+=$'\n'
    lane_block+="- Thesis Damage Flags:"
    lane_block+=$'\n'
    lane_block+="$thesis_damage_block"
  fi
  if [[ "$trade_reasoning_summary" != "n/a" ]]; then
    lane_block+=$'\n'
    lane_block+="- ${trade_reasoning_summary}"
  fi
  if [[ "$status" == "success" && "$constraints_ok" != "true" ]]; then
    lane_block+=$'\n'
    lane_block+="- Limits: ${constraints_label}"
  fi
  if [[ -n "$api_notice_block" ]]; then
    lane_block+=$'\n'
    lane_block+="- Data Notes:"
    lane_block+=$'\n'
    lane_block+="$api_notice_block"
  fi

  if [[ "$status" == "success" ]]; then
    lane_block+=$'\n'
    lane_block+="- Watch-outs: ${risk_snippet}"
  fi

  lane_sections+="$lane_block"

  if ! printf '%s' "$fund_order" | grep -Fxq "$fund_id"; then
    fund_order+="${fund_id}"$'\n'
  fi
  printf '%s' "$lane_block" >> "$tmpdir/${fund_id}.txt"
done < <(jq -c '.lanes[]' "$scoreboard_path")

fi

if [[ -n "$comparison_notes" && "$comparison_notes" == Computed\ from\ first\ two\ successful\ lanes:* ]]; then
  comparison_notes="Based on today's completed fund runs."
fi

message=""
trim_discord_message() {
  local raw="$1"
  local remove_codeblocks="${2:-true}"
  local max_len=2000

  if (( ${#raw} <= max_len )); then
    printf '%s' "$raw"
    return 0
  fi

  # Prefer removing entire lower-priority lines over truncating arbitrary substrings (e.g., company names).
  local compact="$raw"
  compact="$(printf '%s' "$compact" | perl -0pe 's/^-\s*Watch-outs:.*\n//mg; s/^-\s*Notes:.*\n//mg')"
  if (( ${#compact} > max_len )); then
    compact="$(printf '%s' "$compact" | perl -0pe 's/^-\\s*Market News:\\n(?:\\s*•.*\\n)+//mg')"
  fi
  if (( ${#compact} > max_len )); then
    compact="$(printf '%s' "$compact" | perl -0pe 's/^-\\s*Thesis Damage Flags:\\n(?:\\s*•.*\\n)+//mg')"
  fi
  if [[ "$remove_codeblocks" == "true" ]] && (( ${#compact} > max_len )); then
    compact="$(printf '%s' "$compact" | perl -0pe 's/^```text\\n(?:.*\\n)*?```\\n?//mg')"
  fi

  while (( ${#compact} > max_len )) && [[ "$compact" == *$'\n'* ]]; do
    compact="${compact%$'\n'*}"
  done

  if (( ${#compact} > max_len )); then
    printf '%s' "**(Digest omitted: exceeds Discord message limit.)**"
    return 0
  fi

  printf '%s' "$compact"
}

build_lanes_overview_block() {
  local out=""
  out+="**🧩 Lanes**"
  out+=$'\n'
  while IFS= read -r lane; do
    fund_id="$(jq -r '.fund_id' <<<"$lane")"
    provider="$(jq -r '.provider' <<<"$lane")"
    status="$(jq -r '.status' <<<"$lane")"
    run_path="$(jq -r '.run_path' <<<"$lane")"
    meta_path="${run_path}/run_meta.json"
    error_message=""

	    case "$provider" in
	      openai) provider_label="OpenAI" ;;
	      anthropic) provider_label="Anthropic" ;;
	      xai) provider_label="xAI" ;;
	      *) provider_label="$(printf '%s' "$provider" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')" ;;
	    esac

	    case "$fund_id" in
	      fund-a) fund_emoji="🟦" ;;
	      fund-b) fund_emoji="🟪" ;;
	      fund-c) fund_emoji="🟧" ;;
	      *) fund_emoji="⬜" ;;
	    esac
    fund_label="$(printf '%s' "$fund_id" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) tolower(substr($i,2))} print}')"

    if [[ "$status" == "success" ]]; then
      status_emoji="🟢"
      status_label="On track"
    else
      status_emoji="🔴"
      status_label="Issue"
    fi

    if [[ "$status" != "success" && -f "$meta_path" ]]; then
      error_message="$(jq -r '.reason // ""' "$meta_path")"
      error_message="$(printf '%s' "$error_message" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
      if [[ ${#error_message} -gt 180 ]]; then
        error_message="${error_message:0:177}..."
      fi
    fi

    fund_return_pct="$(jq -r '.fund_return_pct // empty' <<<"$lane")"
    benchmark_return_pct="$(jq -r '.benchmark_return_pct // empty' <<<"$lane")"
    excess_return_pct="$(jq -r '.excess_return_pct // empty' <<<"$lane")"
    benchmark_name="$(jq -r '.benchmark_name // .benchmark_ticker // empty' <<<"$lane")"
    inception_date="$(jq -r '.inception_date // empty' <<<"$lane")"
    asof_price_date="$(jq -r '.asof_price_date // empty' <<<"$lane")"

    perf_suffix=""
    if [[ "$status" == "success" && -n "$fund_return_pct" ]]; then
      fund_perf="$(printf "%+.2f%%" "$fund_return_pct" 2>/dev/null || true)"
      bm_perf=""
      if [[ -n "$benchmark_return_pct" && -n "$benchmark_name" ]]; then
        bm_perf="$(printf "%+.2f%%" "$benchmark_return_pct" 2>/dev/null || true)"
      fi
      excess_perf=""
      if [[ -n "$excess_return_pct" ]]; then
        excess_perf="$(printf "%+.2f%%" "$excess_return_pct" 2>/dev/null || true)"
      fi

      perf_suffix=" - **${fund_perf}** since ${inception_date}"
      if [[ -n "$bm_perf" ]]; then
        perf_suffix+=" vs ${benchmark_name} ${bm_perf}"
      fi
      if [[ -n "$excess_perf" ]]; then
        perf_suffix+=" (${excess_perf} excess)"
      fi
      if [[ -n "$asof_price_date" ]]; then
        perf_suffix+=" as of ${asof_price_date}"
      fi
    fi

    out+="- ${fund_emoji} ${fund_label} (${provider_label}): ${status_emoji} **${status_label}**${perf_suffix}"
    if [[ -n "$error_message" ]]; then
      out+=" - ${error_message}"
    fi
    out+=$'\n'
  done < <(jq -c '.lanes[]' "$scoreboard_path")
  printf '%s' "$out"
}

build_indices_overview_block() {
  local count
  count="$(jq -r '(.indices.items // []) | length' "$scoreboard_path")"
  if [[ -z "$count" || "$count" == "0" ]]; then
    printf '%s' ""
    return 0
  fi

  local out=""
  out+="**📊 Indices**"
  local idx_asof
  idx_asof="$(jq -r '.indices.asof_price_date // empty' "$scoreboard_path")"
  if [[ -n "$idx_asof" ]]; then
    out+=" (as of ${idx_asof} close)"
  fi
  out+=$'\n'

  while IFS= read -r item; do
    name="$(jq -r '.name // .ticker // "Index"' <<<"$item")"
    ret="$(jq -r '.return_pct // empty' <<<"$item")"
    if [[ -z "$ret" ]]; then
      out+="- ${name}: n/a"
    else
      out+="- ${name}: **$(printf "%+.2f%%" "$ret" 2>/dev/null || printf '%s' "$ret")**"
    fi
    out+=$'\n'
  done < <(jq -c '.indices.items[]' "$scoreboard_path")

  printf '%s' "$out"
}

format_scoreboard_snippet() {
  local md="$1"
  local max_lines="${2:-40}"

  if [[ -z "$md" ]]; then
    printf '%s' ""
    return 0
  fi

  local total_lines
  total_lines="$(printf '%s\n' "$md" | wc -l | tr -d ' ')"
  if [[ -z "$total_lines" ]]; then total_lines=0; fi

  if (( total_lines <= max_lines )); then
    printf '%s' "$md"
    return 0
  fi

  local head_block
  head_block="$(printf '%s\n' "$md" | head -n "$max_lines")"
  printf '%s\n\n... (%d more lines)\n' "$head_block" "$(( total_lines - max_lines ))"
}

scoreboard_md=""
if [[ -f "$scoreboard_repo_path" ]]; then
  scoreboard_md="$(cat "$scoreboard_repo_path")"
elif [[ -f "$scoreboard_repo_path_fallback" ]]; then
  scoreboard_md="$(cat "$scoreboard_repo_path_fallback")"
fi

overview_msg=""
scoreboard_snip=""

if [[ "$include_header" == "true" ]]; then
  overview_msg="**📈 Daily Paper Update — ${run_date}**"
  if [[ -n "$overall_line" ]]; then
    overview_msg+=$'\n'
    overview_msg+="${overall_emoji} ${overall_line}"
  fi
  overview_msg+=$'\n'
  overview_msg+=$'\n'
  overview_msg+="**🏁 Board**"
  overview_msg+=$'\n'
  overview_msg+="- Ovlp: **${overlap_pct}%**"
  overview_msg+=$'\n'
  overview_msg+="- Est. turnover: **${turnover_pct}%**"
  overview_msg+=$'\n'
  overview_msg+=$'\n'
  overview_msg+="$(build_lanes_overview_block)"
  indices_block="$(build_indices_overview_block)"
  if [[ -n "$indices_block" ]]; then
    overview_msg+=$'\n'
    overview_msg+=$'\n'
    overview_msg+="$indices_block"
  fi

  scoreboard_snip="$(format_scoreboard_snippet "$scoreboard_md" 35)"
  if [[ -n "$scoreboard_snip" ]]; then
    overview_msg+=$'\n'
    overview_msg+=$'\n'
    overview_msg+="**🏁 Scoreboard**"
    overview_msg+=$'\n'
    overview_msg+=$'```text\n'
    overview_msg+="$scoreboard_snip"
    overview_msg+=$'\n```'
  fi

  overview_msg+=$'\n'
  overview_msg+=$'\n'
  overview_msg+="**📊 Dashboard:** <https://zchwyng.github.io/hedge-labs/>"
fi

if [[ "$mode" == "overall-only" ]]; then
  overview_msg="$(trim_discord_message "$overview_msg" "false")"
  jq -Rn --argjson messages "$(jq -n --arg content "$overview_msg" '[{content:$content, flags:4}]')" '$messages'
  exit 0
fi

if [[ "$mode" == "no-header" ]]; then
  # Back-compat: only post the selected fund (or all lane blocks if no filter is provided).
  if [[ -n "$fund_filter" ]]; then
    fund_msg="$(cat "$tmpdir/${fund_filter}.txt" 2>/dev/null || true)"
    fund_msg="$(printf '%s' "$fund_msg" | perl -0pe 's/^\n+//')"
    fund_msg="$(trim_discord_message "$fund_msg")"
    jq -Rn --argjson messages "$(jq -n --arg content "$fund_msg" '[{content:$content, flags:4}]')" '$messages'
    exit 0
  fi

  all_lanes_msg="$(printf '%s' "$lane_sections" | perl -0pe 's/^\n+//')"
  all_lanes_msg="$(trim_discord_message "$all_lanes_msg")"
  jq -Rn --argjson messages "$(jq -n --arg content "$all_lanes_msg" '[{content:$content, flags:4}]')" '$messages'
  exit 0
fi

messages_json="$(jq -n '[]')"

if [[ -n "$overview_msg" ]]; then
  overview_msg="$(trim_discord_message "$overview_msg" "false")"
  messages_json="$(printf '%s' "$messages_json" | jq --arg content "$overview_msg" '. + [{content:$content, flags:4}]')"
fi

if [[ -n "$fund_filter" ]]; then
  fund_msg="$(cat "$tmpdir/${fund_filter}.txt" 2>/dev/null || true)"
  fund_msg="$(printf '%s' "$fund_msg" | perl -0pe 's/^\n+//')"
  fund_msg="$(trim_discord_message "$fund_msg")"
  messages_json="$(printf '%s' "$messages_json" | jq --arg content "$fund_msg" '. + [{content:$content, flags:4}]')"
else
  while IFS= read -r fid; do
    [[ -n "$fid" ]] || continue
    fund_msg="$(cat "$tmpdir/${fid}.txt" 2>/dev/null || true)"
    fund_msg="$(printf '%s' "$fund_msg" | perl -0pe 's/^\n+//')"
    fund_msg="$(trim_discord_message "$fund_msg")"
    messages_json="$(printf '%s' "$messages_json" | jq --arg content "$fund_msg" '. + [{content:$content, flags:4}]')"
  done <<<"$(printf '%s' "$fund_order")"
fi

printf '%s\n' "$messages_json"
