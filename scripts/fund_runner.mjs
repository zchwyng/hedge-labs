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

function round2(value) {
  return Number(value.toFixed(2));
}

function getSectorSums(portfolio) {
  const sums = new Map();
  for (const item of portfolio) {
    sums.set(item.sector, (sums.get(item.sector) || 0) + item.weight_pct);
  }
  return sums;
}

function normalizeWeightsTo100(portfolio) {
  const total = portfolio.reduce((sum, item) => sum + item.weight_pct, 0);
  if (total <= 0) {
    return false;
  }
  for (const item of portfolio) {
    item.weight_pct = (item.weight_pct * 100) / total;
  }
  return true;
}

function computeFeasibleCapacity(portfolio, maxPositionPct, maxSectorPct) {
  const sectorCounts = new Map();
  for (const item of portfolio) {
    sectorCounts.set(item.sector, (sectorCounts.get(item.sector) || 0) + 1);
  }

  let capacity = 0;
  for (const count of sectorCounts.values()) {
    capacity += Math.min(count * maxPositionPct, maxSectorPct);
  }
  return capacity;
}

function redistributeWithinCaps(portfolio, amount, maxPositionPct, maxSectorPct) {
  let remaining = amount;

  for (let iter = 0; iter < 80 && remaining > 1e-6; iter += 1) {
    const sectorSums = getSectorSums(portfolio);
    const capacities = portfolio.map((item) => {
      const byPosition = Math.max(0, maxPositionPct - item.weight_pct);
      const bySector = Math.max(0, maxSectorPct - (sectorSums.get(item.sector) || 0));
      return Math.min(byPosition, bySector);
    });

    const totalCapacity = capacities.reduce((sum, value) => sum + value, 0);
    if (totalCapacity <= 1e-9) {
      break;
    }

    const delta = Math.min(remaining, totalCapacity);
    for (let i = 0; i < portfolio.length; i += 1) {
      const cap = capacities[i];
      if (cap <= 0) continue;
      portfolio[i].weight_pct += (delta * cap) / totalCapacity;
    }
    remaining -= delta;
  }

  return remaining;
}

function finalizeRoundedWeights(portfolio, maxPositionPct, maxSectorPct) {
  for (const item of portfolio) {
    item.weight_pct = round2(Math.max(0, item.weight_pct));
  }

  let residual = round2(100 - portfolio.reduce((sum, item) => sum + item.weight_pct, 0));
  if (Math.abs(residual) < 0.01) {
    return;
  }

  for (let iter = 0; iter < 500 && Math.abs(residual) >= 0.01; iter += 1) {
    const sectorSums = getSectorSums(portfolio);
    if (residual > 0) {
      const candidate = [...portfolio]
        .sort((a, b) => (a.weight_pct - b.weight_pct) || a.ticker.localeCompare(b.ticker))
        .find((item) => item.weight_pct + 0.01 <= maxPositionPct && (sectorSums.get(item.sector) || 0) + 0.01 <= maxSectorPct);
      if (!candidate) break;
      candidate.weight_pct = round2(candidate.weight_pct + 0.01);
      residual = round2(residual - 0.01);
    } else {
      const candidate = [...portfolio]
        .sort((a, b) => (b.weight_pct - a.weight_pct) || a.ticker.localeCompare(b.ticker))
        .find((item) => item.weight_pct >= 0.01);
      if (!candidate) break;
      candidate.weight_pct = round2(candidate.weight_pct - 0.01);
      residual = round2(residual + 0.01);
    }
  }
}

function enforcePortfolioConstraints(initialPortfolio, context) {
  const notes = [];
  let portfolio = initialPortfolio.map((item) => ({ ...item }));

  // Merge duplicate tickers deterministically.
  const byTicker = new Map();
  for (const item of portfolio) {
    const existing = byTicker.get(item.ticker);
    if (!existing) {
      byTicker.set(item.ticker, { ...item });
      continue;
    }
    existing.weight_pct += item.weight_pct;
    if (existing.sector === "UNKNOWN" && item.sector !== "UNKNOWN") {
      existing.sector = item.sector;
    }
  }
  portfolio = Array.from(byTicker.values());

  if (portfolio.length > context.positions) {
    portfolio.sort((a, b) => (b.weight_pct - a.weight_pct) || a.ticker.localeCompare(b.ticker));
    portfolio = portfolio.slice(0, context.positions);
    notes.push(`trimmed_to_top_${context.positions}_positions=true`);
  }

  if (portfolio.length === 0 || !normalizeWeightsTo100(portfolio)) {
    return {
      portfolio: buildPortfolio(context.positions, context.maxPositionPct),
      repaired: true,
      repairNotes: ["repair_fallback=empty_or_invalid_portfolio"]
    };
  }

  const feasibleCapacity = computeFeasibleCapacity(portfolio, context.maxPositionPct, context.maxSectorPct);
  if (feasibleCapacity + 1e-6 < 100) {
    return {
      portfolio: buildPortfolio(context.positions, context.maxPositionPct),
      repaired: true,
      repairNotes: [`repair_fallback=infeasible_sector_capacity_${round2(feasibleCapacity)}pct`]
    };
  }

  let excess = 0;
  for (const item of portfolio) {
    if (item.weight_pct > context.maxPositionPct) {
      excess += item.weight_pct - context.maxPositionPct;
      item.weight_pct = context.maxPositionPct;
    }
  }

  const sectorSums = getSectorSums(portfolio);
  for (const [sector, sum] of sectorSums.entries()) {
    if (sum <= context.maxSectorPct + 1e-9) continue;
    const ratio = context.maxSectorPct / sum;
    for (const item of portfolio) {
      if (item.sector !== sector) continue;
      const newWeight = item.weight_pct * ratio;
      excess += item.weight_pct - newWeight;
      item.weight_pct = newWeight;
    }
  }

  const remainingAfterRedistribution = redistributeWithinCaps(
    portfolio,
    excess,
    context.maxPositionPct,
    context.maxSectorPct
  );
  if (remainingAfterRedistribution > 0.05) {
    notes.push(`unallocated_after_caps=${round2(remainingAfterRedistribution)}%`);
  }

  const currentTotal = portfolio.reduce((sum, item) => sum + item.weight_pct, 0);
  if (currentTotal < 100 - 1e-6) {
    const rem = redistributeWithinCaps(
      portfolio,
      100 - currentTotal,
      context.maxPositionPct,
      context.maxSectorPct
    );
    if (rem > 0.05) {
      notes.push(`final_unallocated=${round2(rem)}%`);
    }
  } else if (currentTotal > 100 + 1e-6) {
    let toTrim = currentTotal - 100;
    for (const item of [...portfolio].sort((a, b) => (b.weight_pct - a.weight_pct) || a.ticker.localeCompare(b.ticker))) {
      if (toTrim <= 1e-6) break;
      const cut = Math.min(item.weight_pct, toTrim);
      item.weight_pct -= cut;
      toTrim -= cut;
    }
  }

  finalizeRoundedWeights(portfolio, context.maxPositionPct, context.maxSectorPct);

  const maxPositionObserved = round2(Math.max(...portfolio.map((item) => item.weight_pct)));
  const maxSectorObserved = sectorMaxWeight(portfolio);
  const maxPositionOk = maxPositionObserved <= context.maxPositionPct + 0.01;
  const maxSectorOk = maxSectorObserved <= context.maxSectorPct + 0.01;

  if (!maxPositionOk || !maxSectorOk) {
    return {
      portfolio: buildPortfolio(context.positions, context.maxPositionPct),
      repaired: true,
      repairNotes: [
        ...notes,
        `repair_fallback=post_repair_constraints_failed(max_position=${maxPositionObserved},max_sector=${maxSectorObserved})`
      ]
    };
  }

  return {
    portfolio,
    repaired: notes.length > 0,
    repairNotes: notes
  };
}

function writeScratchpad(event, metadata = {}) {
  const dir = ".dexter/scratchpad";
  mkdirSync(dir, { recursive: true });
  const filename = `${new Date().toISOString().replace(/[:.]/g, "-")}.jsonl`;
  const path = join(dir, filename);

  const lines = [
    JSON.stringify({
      ts: nowIso(),
      type: "run_started",
      data: {
        fund_name: event.fund_name,
        run_date: event.run_date,
        provider: metadata.provider || "unknown",
        model: metadata.model || "unknown",
        mode: metadata.mode || "unknown"
      }
    }),
    JSON.stringify({
      ts: nowIso(),
      type: "run_completed",
      data: {
        action: event.trade_of_the_day?.action || "UNKNOWN",
        paper_only: true,
        mode: metadata.mode || "unknown"
      }
    })
  ];

  writeFileSync(path, `${lines.join("\n")}\n`, "utf8");
}

function stripCodeFences(text) {
  return text
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/\s*```$/i, "")
    .trim();
}

function parseBalancedJsonObject(text) {
  let inString = false;
  let escaped = false;
  let depth = 0;
  let start = -1;

  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];

    if (escaped) {
      escaped = false;
      continue;
    }

    if (ch === "\\") {
      if (inString) {
        escaped = true;
      }
      continue;
    }

    if (ch === '"') {
      inString = !inString;
      continue;
    }

    if (inString) {
      continue;
    }

    if (ch === "{") {
      if (depth === 0) {
        start = i;
      }
      depth += 1;
      continue;
    }

    if (ch === "}") {
      if (depth > 0) {
        depth -= 1;
        if (depth === 0 && start >= 0) {
          const candidate = text.slice(start, i + 1);
          try {
            return JSON.parse(candidate);
          } catch {
            // Keep searching for the next candidate.
          }
        }
      }
    }
  }

  return null;
}

function extractJsonObject(text) {
  const trimmed = stripCodeFences((text || "").trim());
  if (!trimmed) {
    throw new Error("model output was empty");
  }

  try {
    return JSON.parse(trimmed);
  } catch {
    const balanced = parseBalancedJsonObject(trimmed);
    if (balanced) {
      return balanced;
    }
  }

  throw new Error("model output did not contain valid JSON object");
}

async function fetchJsonWithTimeout(url, init, timeoutMs = 120000) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { ...init, signal: controller.signal });
    const bodyText = await response.text();
    let body;
    try {
      body = JSON.parse(bodyText);
    } catch {
      body = { raw: bodyText };
    }

    if (!response.ok) {
      const errorMessage = body?.error?.message || body?.message || `${response.status} ${response.statusText}`;
      throw new Error(`HTTP ${response.status}: ${errorMessage}`);
    }

    return body;
  } finally {
    clearTimeout(timeout);
  }
}

function requireEnv(name) {
  const value = (process.env[name] || "").trim();
  if (!value) {
    throw new Error(`missing required environment variable: ${name}`);
  }
  return value;
}

async function runOpenAI({ model, prompt }) {
  const apiKey = requireEnv("OPENAI_API_KEY");

  const baseHeaders = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${apiKey}`
  };

  async function callChatCompletions(requestModel) {
    const payload = {
      model: requestModel,
      temperature: 0,
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content:
            "You are a paper-only investment research assistant. Return exactly one JSON object and no extra text."
        },
        {
          role: "user",
          content: prompt
        }
      ]
    };

    return fetchJsonWithTimeout("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: baseHeaders,
      body: JSON.stringify(payload)
    });
  }

  async function listAvailableModelIds() {
    const data = await fetchJsonWithTimeout("https://api.openai.com/v1/models", {
      method: "GET",
      headers: baseHeaders
    });
    if (!Array.isArray(data?.data)) {
      return [];
    }
    return data.data
      .map((item) => item?.id)
      .filter((id) => typeof id === "string" && id.length > 0);
  }

  let data;
  let modelUsed = model;
  try {
    data = await callChatCompletions(model);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const lower = message.toLowerCase();
    const isModelError =
      lower.includes("model") &&
      (lower.includes("http 404") ||
        lower.includes("does not exist") ||
        lower.includes("not found") ||
        lower.includes("not available") ||
        lower.includes("unsupported"));
    if (!isModelError) {
      throw error;
    }

    const available = await listAvailableModelIds();
    const availableSet = new Set(available);
    const preferredOrder = [
      "gpt-5.2",
      "gpt-5.2-pro",
      "gpt-5.1",
      "gpt-5",
      "gpt-4.1",
      "gpt-4o"
    ];

    let fallbackModel = preferredOrder.find((candidate) => availableSet.has(candidate) && candidate !== model);
    if (!fallbackModel) {
      fallbackModel = available.find((candidate) => candidate !== model);
    }
    if (!fallbackModel) {
      throw error;
    }

    data = await callChatCompletions(fallbackModel);
    modelUsed = fallbackModel;
  }

  const content = data?.choices?.[0]?.message?.content;
  if (typeof content !== "string" || !content.trim()) {
    throw new Error("OpenAI response missing text content");
  }

  return {
    output: extractJsonObject(content),
    modelUsed
  };
}

async function runAnthropic({ model, prompt }) {
  const apiKey = requireEnv("ANTHROPIC_API_KEY");

  const baseHeaders = {
    "Content-Type": "application/json",
    "x-api-key": apiKey,
    "anthropic-version": "2023-06-01"
  };

  async function callMessages(requestModel) {
    const payload = {
      model: requestModel,
      max_tokens: 2500,
      temperature: 0,
      system: "You are a paper-only investment research assistant. Return exactly one JSON object and no extra text.",
      messages: [
        {
          role: "user",
          content: prompt
        }
      ]
    };

    return fetchJsonWithTimeout("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: baseHeaders,
      body: JSON.stringify(payload)
    });
  }

  async function listAvailableModelIds() {
    const data = await fetchJsonWithTimeout("https://api.anthropic.com/v1/models", {
      method: "GET",
      headers: baseHeaders
    });
    if (!Array.isArray(data?.data)) {
      return [];
    }
    return data.data
      .map((item) => item?.id)
      .filter((id) => typeof id === "string" && id.length > 0);
  }

  let data;
  let modelUsed = model;
  try {
    data = await callMessages(model);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const isModel404 = message.includes("HTTP 404") && message.toLowerCase().includes("model");
    if (!isModel404) {
      throw error;
    }

    const available = await listAvailableModelIds();
    const availableSet = new Set(available);
    const preferredOrder = [
      "claude-opus-4-5",
      "claude-opus-4-5-20251101",
      "claude-opus-4-1",
      "claude-opus-4-1-20250805",
      "claude-sonnet-4-5",
      "claude-sonnet-4-5-20250929",
      "claude-sonnet-4-0",
      "claude-3-5-sonnet-latest",
      "claude-3-5-sonnet-20241022",
      "claude-3-5-haiku-latest",
      "claude-3-5-haiku-20241022",
      "claude-3-haiku-20240307"
    ];

    const fallbackModel = preferredOrder.find((candidate) => availableSet.has(candidate)) || available[0];
    if (!fallbackModel) {
      throw error;
    }

    data = await callMessages(fallbackModel);
    modelUsed = fallbackModel;
  }

  const contentBlocks = Array.isArray(data?.content) ? data.content : [];
  const content = contentBlocks
    .filter((block) => block?.type === "text" && typeof block?.text === "string")
    .map((block) => block.text)
    .join("\n")
    .trim();

  if (!content) {
    throw new Error("Anthropic response missing text content");
  }

  return {
    output: extractJsonObject(content),
    modelUsed
  };
}

function asString(value, fallback = "") {
  if (typeof value === "string") {
    return value;
  }
  if (value === null || value === undefined) {
    return fallback;
  }
  return String(value);
}

function asNumber(value, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function normalizeOutput(raw, context) {
  const marketSummaryRaw = Array.isArray(raw?.market_summary) ? raw.market_summary : [];
  const marketSummary = marketSummaryRaw
    .map((item) => asString(item, "").trim())
    .filter(Boolean)
    .slice(0, 3);
  while (marketSummary.length < 3) {
    marketSummary.push("UNKNOWN");
  }

  const flags = Array.isArray(raw?.thesis_damage_flags) ? raw.thesis_damage_flags : [];
  const thesisDamageFlags = flags
    .map((item) => ({
      ticker: asString(item?.ticker, "UNKNOWN").toUpperCase(),
      why: asString(item?.why, "UNKNOWN")
    }))
    .slice(0, 25);

  const validActions = new Set(["Add", "Trim", "Replace", "Do nothing"]);
  const trade = raw?.trade_of_the_day || {};
  const action = validActions.has(trade?.action) ? trade.action : "Do nothing";

  const thesis = (Array.isArray(trade?.thesis) ? trade.thesis : [])
    .map((item) => asString(item, "").trim())
    .filter(Boolean)
    .slice(0, 3);
  while (thesis.length < 3) {
    thesis.push("UNKNOWN");
  }

  const risks = (Array.isArray(trade?.risks) ? trade.risks : [])
    .map((item) => asString(item, "").trim())
    .filter(Boolean)
    .slice(0, 3);
  while (risks.length < 3) {
    risks.push("UNKNOWN");
  }

  const checks = (Array.isArray(trade?.falsifiable_checks) ? trade.falsifiable_checks : [])
    .map((item) => asString(item, "").trim())
    .filter(Boolean)
    .slice(0, 2);
  while (checks.length < 2) {
    checks.push("UNKNOWN");
  }

  const rawPortfolio = Array.isArray(raw?.target_portfolio)
    ? raw.target_portfolio
        .map((item) => ({
          ticker: asString(item?.ticker, "").trim().toUpperCase(),
          weight_pct: Number(asNumber(item?.weight_pct, NaN).toFixed(2)),
          sector: asString(item?.sector, "UNKNOWN").trim() || "UNKNOWN"
        }))
        .filter((item) => item.ticker && Number.isFinite(item.weight_pct) && item.weight_pct >= 0)
    : [];

  const repairedPortfolioResult = enforcePortfolioConstraints(rawPortfolio, context);
  const portfolio = repairedPortfolioResult.portfolio;

  const maxPositionObserved = Number(Math.max(...portfolio.map((p) => p.weight_pct)).toFixed(2));
  const maxSectorObserved = sectorMaxWeight(portfolio);

  const existingNotes = asString(raw?.constraints_check?.notes, "").trim();
  const computedNotes = `max_position_observed=${maxPositionObserved}%, max_sector_observed=${maxSectorObserved}%`;
  const repairNotes = repairedPortfolioResult.repairNotes.join("; ");

  const noteParts = [];
  if (existingNotes) {
    noteParts.push(existingNotes);
  }
  if (repairNotes) {
    noteParts.push(repairNotes);
  }
  noteParts.push(computedNotes);

  return {
    run_date: context.runDate,
    fund_name: context.fundName,
    paper_only: true,
    market_summary: marketSummary,
    thesis_damage_flags: thesisDamageFlags,
    trade_of_the_day: {
      action,
      remove_ticker: trade?.remove_ticker == null ? null : asString(trade.remove_ticker, "").trim().toUpperCase() || null,
      add_ticker: trade?.add_ticker == null ? null : asString(trade.add_ticker, "").trim().toUpperCase() || null,
      size_change_pct: Number(asNumber(trade?.size_change_pct, 0).toFixed(2)),
      thesis,
      risks,
      falsifiable_checks: checks,
      why_now: asString(trade?.why_now, "UNKNOWN")
    },
    target_portfolio: portfolio,
    constraints_check: {
      max_position_ok: maxPositionObserved <= context.maxPositionPct + 0.01,
      max_sector_ok: maxSectorObserved <= context.maxSectorPct + 0.01,
      notes: noteParts.join("; ")
    }
  };
}

function buildFallbackResponse(context, reason) {
  const targetPortfolio = buildPortfolio(context.positions, context.maxPositionPct);
  const maxPositionObserved = Number(Math.max(...targetPortfolio.map((p) => p.weight_pct)).toFixed(2));
  const maxSectorObserved = sectorMaxWeight(targetPortfolio);

  const maxPositionOk = maxPositionObserved <= context.maxPositionPct;
  const maxSectorOk = maxSectorObserved <= context.maxSectorPct;

  return {
    run_date: context.runDate,
    fund_name: context.fundName,
    paper_only: true,
    market_summary: [
      "Live model execution was unavailable.",
      `Fallback mode used for provider=${context.provider}, model=${context.model}.`,
      "Output is deterministic and paper-only."
    ],
    thesis_damage_flags: [],
    trade_of_the_day: {
      action: "Do nothing",
      remove_ticker: null,
      add_ticker: null,
      size_change_pct: 0,
      thesis: [
        "Preserve current paper allocation while model connectivity is restored.",
        "Avoid introducing unverified assumptions in fallback mode.",
        "Keep comparisons stable across providers during recovery."
      ],
      risks: [
        "No real-time catalyst ingestion in fallback mode.",
        "Static portfolio can drift from changing market regimes.",
        `Fallback reason: ${reason}`
      ],
      falsifiable_checks: [
        "Restore provider API connectivity and rerun lane.",
        "Require successful JSON output from both providers for 3 consecutive days."
      ],
      why_now: "Maintain a stable paper baseline while execution reliability is recovered."
    },
    target_portfolio: targetPortfolio,
    constraints_check: {
      max_position_ok: maxPositionOk,
      max_sector_ok: maxSectorOk,
      notes: `max_position_observed=${maxPositionObserved}%, max_sector_observed=${maxSectorObserved}%`
    }
  };
}

async function main() {
  const prompt = await readStdin();
  if (!prompt.trim()) {
    throw new Error("prompt was empty on stdin");
  }

  const context = {
    runDate: pick(prompt, /-\s*Run date:\s*([^\n]+)/i, new Date().toISOString().slice(0, 10)),
    fundName: pick(prompt, /-\s*Fund name:\s*([^\n]+)/i, "UNKNOWN"),
    provider: pick(prompt, /-\s*Provider:\s*([^\n]+)/i, "unknown").toLowerCase(),
    model: pick(prompt, /-\s*Model:\s*([^\n]+)/i, "unknown"),
    universe: pick(prompt, /-\s*Universe:\s*([^\n\.]+)/i, "UNKNOWN"),
    positions: pickNumber(prompt, /Target positions:\s*([0-9]+)/i, 12),
    maxPositionPct: pickNumber(prompt, /Max position:\s*([0-9.]+)%/i, 12),
    maxSectorPct: pickNumber(prompt, /Max sector:\s*([0-9.]+)%/i, 25)
  };

  const allowFallback = ["1", "true", "yes"].includes((process.env.FUND_RUNNER_ALLOW_FALLBACK || "").toLowerCase());

  try {
    let rawOutput;
    let modelUsed = context.model;
    if (context.provider === "openai") {
      const result = await runOpenAI({ model: context.model, prompt });
      rawOutput = result.output;
      modelUsed = result.modelUsed;
    } else if (context.provider === "anthropic") {
      const result = await runAnthropic({ model: context.model, prompt });
      rawOutput = result.output;
      modelUsed = result.modelUsed;
    } else {
      throw new Error(`unsupported provider: ${context.provider}`);
    }

    const normalized = normalizeOutput(rawOutput, context);
    normalized.model_used = modelUsed;
    normalized.model_requested = context.model;
    writeScratchpad(normalized, {
      provider: context.provider,
      model: modelUsed,
      mode: "live"
    });
    process.stdout.write(`${JSON.stringify(normalized)}\n`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);

    if (!allowFallback) {
      console.error(`fund_runner_error: ${message}`);
      process.exit(1);
    }

    const fallback = buildFallbackResponse(context, message);
    writeScratchpad(fallback, {
      provider: context.provider,
      model: context.model,
      mode: "fallback"
    });
    process.stdout.write(`${JSON.stringify(fallback)}\n`);
  }
}

await main();
