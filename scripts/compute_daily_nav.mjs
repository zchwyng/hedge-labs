// compute_daily_nav.mjs — Compute daily NAV for all funds and indices using fresh prices.
// Fetches price data once per ticker, then calculates cumulative performance for each date.
// Output: JSON to stdout with per-date fund performance and index returns.
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..');

function parseJson(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; }
}

function asPct(value) { return Number(value.toFixed(2)); }

function dateFromTs(ts) { return new Date(ts * 1000).toISOString().slice(0, 10); }

function isDateStr(s) { return typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s); }

function dateMs(dateStr) {
  const ms = Date.parse(`${dateStr}T00:00:00Z`);
  return Number.isFinite(ms) ? ms : null;
}

function dayBefore(dateStr) {
  const d = new Date(`${dateStr}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

function upperBound(arr, target) {
  let lo = 0, hi = arr.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (arr[mid] <= target) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

function closeOnOrBefore(chart, targetDate) {
  if (!chart || !Array.isArray(chart.dates) || chart.dates.length === 0) return null;
  const idx = upperBound(chart.dates, targetDate) - 1;
  if (idx < 0) return null;
  const close = chart.closes[idx];
  if (!Number.isFinite(close) || close <= 0) return null;
  return { date: chart.dates[idx], close };
}

function symbolAliases(raw) {
  const t = String(raw || '').trim();
  if (!t) return [];
  const out = [t];
  if (t.includes('.')) out.push(t.replace(/\./g, '-'));
  if (t.includes('-')) out.push(t.replace(/-/g, '.'));
  return [...new Set(out)];
}

async function fetchYahooChart(symbol, period1, period2) {
  const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?interval=1d&period1=${period1}&period2=${period2}`;
  try {
    const res = await fetch(url, { headers: { 'User-Agent': 'hedge-labs-fund-arena/1.0' } });
    if (!res.ok) return null;
    const data = await res.json();
    const result = data?.chart?.result?.[0];
    if (!result) return null;

    const timestamps = result.timestamp || [];
    const closes =
      result?.indicators?.adjclose?.[0]?.adjclose ||
      result?.indicators?.quote?.[0]?.close || [];

    if (!Array.isArray(timestamps) || !Array.isArray(closes) || timestamps.length === 0 || closes.length === 0) return null;

    const dates = [], cleanCloses = [];
    for (let i = 0; i < Math.min(timestamps.length, closes.length); i++) {
      const close = closes[i];
      if (close == null) continue;
      const n = Number(close);
      if (!Number.isFinite(n) || n <= 0) continue;
      const d = dateFromTs(timestamps[i]);
      if (!isDateStr(d)) continue;
      dates.push(d);
      cleanCloses.push(n);
    }
    if (dates.length === 0) return null;
    return { symbol, dates, closes: cleanCloses };
  } catch { return null; }
}

async function mapWithConcurrency(items, limit, mapper) {
  const results = new Array(items.length);
  let index = 0;
  async function worker() {
    while (true) {
      const i = index++;
      if (i >= items.length) return;
      results[i] = await mapper(items[i], i);
    }
  }
  const n = Math.max(1, Math.min(limit, items.length));
  await Promise.all(Array.from({ length: n }, () => worker()));
  return results;
}

function extractPortfolio(doc) {
  const holdings = Array.isArray(doc?.target_portfolio) ? doc.target_portfolio : [];
  const byTicker = new Map();
  for (const h of holdings) {
    const ticker = String(h?.ticker || '').trim();
    if (!ticker) continue;
    const w = Number(h?.weight_pct ?? 0);
    if (!Number.isFinite(w) || w <= 0) continue;
    const key = ticker.toUpperCase();
    byTicker.set(key, { ticker, weight_pct: (byTicker.get(key)?.weight_pct || 0) + w });
  }
  return [...byTicker.values()].map(h => ({ ticker: h.ticker, weight_pct: asPct(h.weight_pct) }));
}

function loadSuccessfulRuns(fundId, provider) {
  const runsRoot = join(REPO_ROOT, 'funds', fundId, 'runs');
  if (!existsSync(runsRoot)) return [];
  const dates = readdirSync(runsRoot).filter(isDateStr).sort();
  const out = [];
  for (const d of dates) {
    const outputPath = join(runsRoot, d, provider, 'dexter_output.json');
    const metaPath = join(runsRoot, d, provider, 'run_meta.json');
    if (!existsSync(outputPath)) continue;
    if (existsSync(metaPath)) {
      const meta = parseJson(metaPath);
      if (meta && typeof meta.status === 'string' && meta.status !== 'success') continue;
    }
    const doc = parseJson(outputPath);
    const holdings = extractPortfolio(doc);
    if (holdings.length === 0) continue;
    out.push({ date: d, holdings });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Compute daily NAV for a single fund across all target dates.
// Uses the same segment-based approach as performance_since_added.mjs
// but iterates over each date instead of computing a single final value.
// ---------------------------------------------------------------------------
function computeFundDaily(successfulRuns, chartFor, benchmarkTicker, targetDates) {
  if (successfulRuns.length === 0) return {};

  const inceptionDate = successfulRuns[0].date;
  const results = {};

  for (const runDate of targetDates) {
    if (runDate < inceptionDate) continue;

    // Build segments: same logic as performance_since_added.mjs
    const runsUpToDate = successfulRuns.filter(r => r.date <= runDate);
    if (runsUpToDate.length === 0) continue;
    const asofPortfolioDate = runsUpToDate[runsUpToDate.length - 1].date;

    const segments = [];
    for (let i = 0; i < runsUpToDate.length - 1; i++) {
      segments.push({ start: runsUpToDate[i], endDate: runsUpToDate[i + 1].date });
    }
    if (runDate > asofPortfolioDate) {
      segments.push({ start: runsUpToDate[runsUpToDate.length - 1], endDate: runDate });
    } else if (segments.length === 0) {
      segments.push({ start: runsUpToDate[0], endDate: runDate });
    }

    // Calculate NAV through segments
    let nav = 100;
    let benchNav = 100;
    let benchOk = Boolean(benchmarkTicker);
    let minCoverage = null;
    let alignedAsOfDate = null;
    const benchChart = benchmarkTicker ? chartFor(benchmarkTicker) : null;

    let isFirstSegment = true;
    let failed = false;
    for (const seg of segments) {
      const startDate = isFirstSegment ? dayBefore(seg.start.date) : seg.start.date;
      isFirstSegment = false;

      const leg = [];
      for (const h of seg.start.holdings) {
        const chart = chartFor(h.ticker);
        const startCandidate = closeOnOrBefore(chart, startDate);
        const endCandidate = closeOnOrBefore(chart, seg.endDate);
        if (!startCandidate || !endCandidate) continue;
        leg.push({ ticker: h.ticker, weight: h.weight_pct, chart, startCandidate, endCandidate });
      }

      const benchStartCandidate = benchChart ? closeOnOrBefore(benchChart, startDate) : null;
      const benchEndCandidate = benchChart ? closeOnOrBefore(benchChart, seg.endDate) : null;

      if (leg.length === 0) { failed = true; break; }

      // Align on earliest boundary dates
      let alignedStartDate = leg.map(x => x.startCandidate.date).sort()[0];
      let alignedEndDate = leg.map(x => x.endCandidate.date).sort()[0];
      if (benchOk && benchStartCandidate && benchEndCandidate) {
        if (benchStartCandidate.date < alignedStartDate) alignedStartDate = benchStartCandidate.date;
        if (benchEndCandidate.date < alignedEndDate) alignedEndDate = benchEndCandidate.date;
      }
      if (alignedEndDate < alignedStartDate) alignedStartDate = alignedEndDate;

      let covered = 0, weightedSum = 0;
      for (const item of leg) {
        const start = closeOnOrBefore(item.chart, alignedStartDate);
        const end = closeOnOrBefore(item.chart, alignedEndDate);
        if (!start || !end) continue;
        const ret = ((end.close / start.close) - 1) * 100;
        if (!Number.isFinite(ret)) continue;
        covered += item.weight;
        weightedSum += item.weight * ret;
      }

      if (benchOk) {
        const start = closeOnOrBefore(benchChart, alignedStartDate);
        const end = closeOnOrBefore(benchChart, alignedEndDate);
        if (!start || !end) { benchOk = false; }
        else {
          const ret = ((end.close / start.close) - 1) * 100;
          if (!Number.isFinite(ret)) benchOk = false;
          else benchNav *= (1 + ret / 100);
        }
      }

      if (covered <= 0) { failed = true; break; }

      const segReturn = weightedSum / covered;
      nav *= (1 + segReturn / 100);
      minCoverage = minCoverage == null ? covered : Math.min(minCoverage, covered);
      alignedAsOfDate = alignedEndDate;
    }

    if (failed) continue;

    const fundReturn = asPct(((nav / 100) - 1) * 100);
    const benchmarkReturn = benchOk ? asPct(((benchNav / 100) - 1) * 100) : null;

    results[runDate] = {
      fund_return_pct: fundReturn,
      benchmark_return_pct: benchmarkReturn,
      excess_return_pct: benchmarkReturn != null ? asPct(fundReturn - benchmarkReturn) : null,
      asof_price_date: alignedAsOfDate || null,
      covered_weight_pct: asPct(minCoverage ?? 0),
    };
  }

  return results;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
async function main() {
  // 1. Discover funds
  const fundsDir = join(REPO_ROOT, 'funds');
  const fundEntries = [];
  for (const entry of readdirSync(fundsDir)) {
    if (!entry.startsWith('fund-')) continue;
    const configPath = join(fundsDir, entry, 'fund.config.json');
    if (!existsSync(configPath)) continue;
    const config = parseJson(configPath);
    if (!config) continue;
    const provider = config.provider || 'unknown';
    const benchmarkTicker = config.benchmark?.ticker || config.benchmark_ticker || '';
    const benchmarkName = config.benchmark?.name || config.benchmark_label || benchmarkTicker;
    fundEntries.push({ fundId: entry, provider, benchmarkTicker, benchmarkName });
  }

  // 2. Load successful runs for each fund
  const fundRuns = {};
  for (const { fundId, provider } of fundEntries) {
    fundRuns[fundId] = loadSuccessfulRuns(fundId, provider);
  }

  // 3. Discover arena dates
  const arenaRunsDir = join(REPO_ROOT, 'funds', 'arena', 'runs');
  const targetDates = existsSync(arenaRunsDir)
    ? readdirSync(arenaRunsDir).filter(isDateStr).sort()
    : [];
  if (targetDates.length === 0) { console.log('{}'); return; }

  // 4. Determine earliest inception date and price range
  let earliestInception = null;
  for (const runs of Object.values(fundRuns)) {
    if (runs.length > 0) {
      const d = runs[0].date;
      if (!earliestInception || d < earliestInception) earliestInception = d;
    }
  }
  if (!earliestInception) { console.log('{}'); return; }

  const latestDate = targetDates[targetDates.length - 1];
  const period1 = Math.floor(dateMs(earliestInception) / 1000) - (14 * 86400);
  const nowEpoch = Math.floor(Date.now() / 1000);
  const period2 = Math.min(nowEpoch, Math.floor(dateMs(latestDate) / 1000) + (4 * 86400));

  // 5. Collect all unique tickers
  const allTickers = new Set();
  for (const runs of Object.values(fundRuns)) {
    for (const run of runs) {
      for (const h of run.holdings) allTickers.add(h.ticker);
    }
  }
  for (const { benchmarkTicker } of fundEntries) {
    if (benchmarkTicker) allTickers.add(benchmarkTicker);
  }

  // Load indices config
  const indicesPath = join(REPO_ROOT, 'funds', 'arena', 'indices.json');
  const indicesConfig = existsSync(indicesPath) ? parseJson(indicesPath) || [] : [];
  for (const idx of indicesConfig) {
    if (idx.ticker) allTickers.add(idx.ticker);
  }

  // 6. Fetch all price data once
  const chartCache = new Map();
  const tickerList = [...allTickers];
  process.stderr.write(`Fetching prices for ${tickerList.length} tickers...\n`);
  await mapWithConcurrency(tickerList, 8, async (ticker) => {
    let chart = null;
    for (const symbol of symbolAliases(ticker)) {
      chart = await fetchYahooChart(symbol, period1, period2);
      if (chart) break;
    }
    chartCache.set(ticker, chart);
  });
  process.stderr.write(`Fetched ${chartCache.size} tickers.\n`);

  const chartFor = (ticker) => chartCache.get(ticker) || null;

  // 7. Compute daily fund performance
  const fundsOutput = {};
  for (const { fundId, benchmarkTicker } of fundEntries) {
    const runs = fundRuns[fundId];
    const daily = computeFundDaily(runs, chartFor, benchmarkTicker, targetDates);
    for (const [date, perf] of Object.entries(daily)) {
      if (!fundsOutput[date]) fundsOutput[date] = {};
      fundsOutput[date][fundId] = perf;
    }
  }

  // 8. Compute daily index performance
  // Index returns are measured from dayBefore(earliestInception) to each target date
  const indicesOutput = {};
  const indexBaseDate = dayBefore(earliestInception);

  for (const date of targetDates) {
    const items = [];
    let asofMin = null;

    for (const idx of indicesConfig) {
      const chart = chartFor(idx.ticker);
      const start = closeOnOrBefore(chart, indexBaseDate);
      const end = closeOnOrBefore(chart, date);
      if (!start || !end) {
        items.push({ ticker: idx.ticker, name: idx.name || idx.ticker, return_pct: null });
        continue;
      }
      const ret = ((end.close / start.close) - 1) * 100;
      items.push({
        ticker: idx.ticker,
        name: idx.name || idx.ticker,
        return_pct: Number.isFinite(ret) ? asPct(ret) : null,
      });
      if (end.date && (!asofMin || end.date < asofMin)) asofMin = end.date;
    }

    indicesOutput[date] = { asof_price_date: asofMin, items };
  }

  // 9. Output
  console.log(JSON.stringify({ funds: fundsOutput, indices: indicesOutput }));
}

await main();
