#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <fund_id> <run_date> <out_prompt_path>" >&2
  exit 64
fi

fund_id="$1"
run_date="$2"
out_prompt_path="$3"

config_path="funds/${fund_id}/fund.config.json"
template_path="funds/${fund_id}/prompt.template.txt"

if [[ ! -f "$config_path" ]]; then
  echo "Missing fund config: $config_path" >&2
  exit 1
fi

if [[ ! -f "$template_path" ]]; then
  echo "Missing prompt template: $template_path" >&2
  exit 1
fi

IFS=$'\t' read -r fund_name provider model universe hold_horizon positions max_position max_sector rebalance paper_only < <(
  jq -r '[
    .name,
    .provider,
    .model,
    .universe,
    .hold_horizon_days,
    .positions,
    .max_position_pct,
    .max_sector_pct,
    .rebalance,
    .paper_only
  ] | @tsv' "$config_path"
)

if [[ "$paper_only" != "true" ]]; then
  echo "fund.config.json must set paper_only=true for ${fund_id}" >&2
  exit 1
fi

required_placeholders=(
  "{RUN_DATE}"
  "{FUND_NAME}"
  "{PROVIDER}"
  "{MODEL}"
  "{UNIVERSE}"
  "{HOLD_HORIZON_DAYS}"
  "{POSITIONS}"
  "{MAX_POSITION_PCT}"
  "{MAX_SECTOR_PCT}"
  "{REBALANCE}"
)

for placeholder in "${required_placeholders[@]}"; do
  if ! grep -qF "$placeholder" "$template_path"; then
    echo "Template ${template_path} is missing placeholder ${placeholder}" >&2
    exit 1
  fi
done

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\\/&]/\\&/g'
}

mkdir -p "$(dirname "$out_prompt_path")"

sed \
  -e "s/{RUN_DATE}/$(escape_sed "$run_date")/g" \
  -e "s/{FUND_NAME}/$(escape_sed "$fund_name")/g" \
  -e "s/{PROVIDER}/$(escape_sed "$provider")/g" \
  -e "s/{MODEL}/$(escape_sed "$model")/g" \
  -e "s/{UNIVERSE}/$(escape_sed "$universe")/g" \
  -e "s/{HOLD_HORIZON_DAYS}/$(escape_sed "$hold_horizon")/g" \
  -e "s/{POSITIONS}/$(escape_sed "$positions")/g" \
  -e "s/{MAX_POSITION_PCT}/$(escape_sed "$max_position")/g" \
  -e "s/{MAX_SECTOR_PCT}/$(escape_sed "$max_sector")/g" \
  -e "s/{REBALANCE}/$(escape_sed "$rebalance")/g" \
  "$template_path" > "$out_prompt_path"

if grep -Eq '\{[A-Z_]+\}' "$out_prompt_path"; then
  echo "Unresolved placeholders remain in ${out_prompt_path}" >&2
  exit 1
fi

echo "Rendered prompt: ${out_prompt_path}"
