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

  const payload = {
    model,
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

  const data = await fetchJsonWithTimeout("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`
    },
    body: JSON.stringify(payload)
  });

  const content = data?.choices?.[0]?.message?.content;
  if (typeof content !== "string" || !content.trim()) {
    throw new Error("OpenAI response missing text content");
  }

  return extractJsonObject(content);
}

async function runAnthropic({ model, prompt }) {
  const apiKey = requireEnv("ANTHROPIC_API_KEY");

  const payload = {
    model,
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

  const data = await fetchJsonWithTimeout("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01"
    },
    body: JSON.stringify(payload)
  });

  const contentBlocks = Array.isArray(data?.content) ? data.content : [];
  const content = contentBlocks
    .filter((block) => block?.type === "text" && typeof block?.text === "string")
    .map((block) => block.text)
    .join("\n")
    .trim();

  if (!content) {
    throw new Error("Anthropic response missing text content");
  }

  return extractJsonObject(content);
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

  let portfolio = Array.isArray(raw?.target_portfolio)
    ? raw.target_portfolio
        .map((item) => ({
          ticker: asString(item?.ticker, "").trim().toUpperCase(),
          weight_pct: Number(asNumber(item?.weight_pct, NaN).toFixed(2)),
          sector: asString(item?.sector, "UNKNOWN").trim() || "UNKNOWN"
        }))
        .filter((item) => item.ticker && Number.isFinite(item.weight_pct) && item.weight_pct >= 0)
    : [];

  if (portfolio.length === 0) {
    portfolio = buildPortfolio(context.positions, context.maxPositionPct);
  }

  const maxPositionObserved = Number(Math.max(...portfolio.map((p) => p.weight_pct)).toFixed(2));
  const maxSectorObserved = sectorMaxWeight(portfolio);

  const existingNotes = asString(raw?.constraints_check?.notes, "").trim();
  const computedNotes = `max_position_observed=${maxPositionObserved}%, max_sector_observed=${maxSectorObserved}%`;

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
      max_position_ok: maxPositionObserved <= context.maxPositionPct,
      max_sector_ok: maxSectorObserved <= context.maxSectorPct,
      notes: existingNotes ? `${existingNotes}; ${computedNotes}` : computedNotes
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
    if (context.provider === "openai") {
      rawOutput = await runOpenAI({ model: context.model, prompt });
    } else if (context.provider === "anthropic") {
      rawOutput = await runAnthropic({ model: context.model, prompt });
    } else {
      throw new Error(`unsupported provider: ${context.provider}`);
    }

    const normalized = normalizeOutput(rawOutput, context);
    writeScratchpad(normalized, {
      provider: context.provider,
      model: context.model,
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
