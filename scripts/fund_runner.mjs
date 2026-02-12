import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      data += chunk;
    });
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", reject);
  });
}

function pick(prompt, regex, fallback = "UNKNOWN") {
  const match = prompt.match(regex);
  return match?.[1]?.trim() || fallback;
}

function pickNumber(prompt, regex, fallback) {
  const raw = pick(prompt, regex, "");
  const value = Number(raw);
  if (Number.isFinite(value)) {
    return value;
  }
  return fallback;
}

function nowIso() {
  return new Date().toISOString();
}

function buildPortfolio(positions, maxPositionPct) {
  const universe = [
    { ticker: "MSFT", sector: "Technology" },
    { ticker: "JNJ", sector: "Healthcare" },
    { ticker: "XOM", sector: "Energy" },
    { ticker: "JPM", sector: "Financials" },
    { ticker: "COST", sector: "Consumer Staples" },
    { ticker: "GE", sector: "Industrials" },
    { ticker: "NEE", sector: "Utilities" },
    { ticker: "AMT", sector: "Real Estate" },
    { ticker: "LIN", sector: "Materials" },
    { ticker: "GOOGL", sector: "Communication Services" },
    { ticker: "AMZN", sector: "Consumer Discretionary" },
    { ticker: "TSM", sector: "Technology" },
    { ticker: "PG", sector: "Consumer Staples" },
    { ticker: "UNH", sector: "Healthcare" },
    { ticker: "V", sector: "Financials" },
    { ticker: "AAPL", sector: "Technology" }
  ];

  const n = Math.max(1, Math.floor(positions));
  const selected = Array.from({ length: n }, (_, i) => universe[i % universe.length]);

  const equalWeight = Number((100 / n).toFixed(2));
  const cappedWeight = Math.min(equalWeight, maxPositionPct);

  const portfolio = selected.map((item) => ({
    ticker: item.ticker,
    weight_pct: Number(cappedWeight.toFixed(2)),
    sector: item.sector
  }));

  const total = portfolio.reduce((sum, p) => sum + p.weight_pct, 0);
  const remainder = Number((100 - total).toFixed(2));
  if (portfolio.length > 0 && remainder > 0) {
    portfolio[0].weight_pct = Number((portfolio[0].weight_pct + remainder).toFixed(2));
  }

  return portfolio;
}

function sectorMaxWeight(portfolio) {
  const bySector = new Map();
  for (const p of portfolio) {
    bySector.set(p.sector, (bySector.get(p.sector) || 0) + p.weight_pct);
  }
  let max = 0;
  for (const weight of bySector.values()) {
    if (weight > max) max = weight;
  }
  return Number(max.toFixed(2));
}

function writeScratchpad(event) {
  const dir = ".dexter/scratchpad";
  mkdirSync(dir, { recursive: true });
  const filename = `${new Date().toISOString().replace(/[:.]/g, "-")}.jsonl`;
  const path = join(dir, filename);

  const lines = [
    JSON.stringify({ ts: nowIso(), type: "run_started", data: { fund_name: event.fund_name, run_date: event.run_date } }),
    JSON.stringify({ ts: nowIso(), type: "run_completed", data: { action: event.trade_of_the_day.action, paper_only: true } })
  ];

  writeFileSync(path, `${lines.join("\n")}\n`, "utf8");
}

const prompt = await readStdin();

const runDate = pick(prompt, /-\s*Run date:\s*([^\n]+)/i, new Date().toISOString().slice(0, 10));
const fundName = pick(prompt, /-\s*Fund name:\s*([^\n]+)/i, "UNKNOWN");
const universe = pick(prompt, /-\s*Universe:\s*([^\n\.]+)/i, "UNKNOWN");
const positions = pickNumber(prompt, /Target positions:\s*([0-9]+)/i, 12);
const maxPositionPct = pickNumber(prompt, /Max position:\s*([0-9.]+)%/i, 12);
const maxSectorPct = pickNumber(prompt, /Max sector:\s*([0-9.]+)%/i, 25);

const targetPortfolio = buildPortfolio(positions, maxPositionPct);
const maxPositionObserved = Number(Math.max(...targetPortfolio.map((p) => p.weight_pct)).toFixed(2));
const maxSectorObserved = sectorMaxWeight(targetPortfolio);

const maxPositionOk = maxPositionObserved <= maxPositionPct;
const maxSectorOk = maxSectorObserved <= maxSectorPct;

const response = {
  run_date: runDate,
  fund_name: fundName,
  paper_only: true,
  market_summary: [
    "No live market scan was executed in this fallback runner.",
    `Universe scoped to ${universe}.`,
    "Output is deterministic and paper-only."
  ],
  thesis_damage_flags: [],
  trade_of_the_day: {
    action: "Do nothing",
    remove_ticker: null,
    add_ticker: null,
    size_change_pct: 0,
    thesis: [
      "Preserve current paper allocation until live research pipeline is wired.",
      "Avoid introducing unsupported assumptions without verified tool data.",
      "Keep comparisons stable across providers while infrastructure matures."
    ],
    risks: [
      "No real-time catalyst ingestion in fallback mode.",
      "Static portfolio can drift from changing market regimes.",
      "Deterministic policy may under-react to abrupt thesis changes."
    ],
    falsifiable_checks: [
      "Replace fallback once non-interactive Dexter execution is available.",
      "Require successful JSON output from both providers for 3 consecutive days."
    ],
    why_now: "Maintain a stable paper baseline while validating workflow reliability."
  },
  target_portfolio: targetPortfolio,
  constraints_check: {
    max_position_ok: maxPositionOk,
    max_sector_ok: maxSectorOk,
    notes: `max_position_observed=${maxPositionObserved}%, max_sector_observed=${maxSectorObserved}%`
  }
};

writeScratchpad(response);
process.stdout.write(`${JSON.stringify(response)}\n`);
