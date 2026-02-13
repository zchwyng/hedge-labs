import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

function parseJson(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
}

function asPct(value) {
  return Number(value.toFixed(2));
}

function dateFromTs(ts) {
  return new Date(ts * 1000).toISOString().slice(0, 10);
}

function isDateStr(s) {
  return typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s);
}

function dateMs(dateStr) {
  const ms = Date.parse(`${dateStr}T00:00:00Z`);
  return Number.isFinite(ms) ? ms : null;
}

function emptyResult({
  benchmarkTicker = '',
  benchmarkName = '',
  inceptionDate = null,
  asofPortfolioDate = null,
  asofPriceDate = null
} = {}) {
  return {
    performance_method: 'nav_since_start',
    inception_date: inceptionDate,
    asof_portfolio_date: asofPortfolioDate,
    asof_price_date: asofPriceDate,
    fund_return_pct: null,
    covered_weight_pct: 0,
    benchmark_ticker: benchmarkTicker || null,
    benchmark_name: benchmarkName || null,
    benchmark_return_pct: null,
    benchmark_covered_weight_pct: 0,
    excess_return_pct: null,
    stocks: []
  };
}

function upperBound(arr, target) {
  let lo = 0;
  let hi = arr.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (arr[mid] <= target) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

function closeOnOrBefore(chart, targetDate) {
  if (!chart || !Array.isArray(chart.dates) || !Array.isArray(chart.closes) || chart.dates.length === 0) return null;
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
    const res = await fetch(url, {
      headers: {
        'User-Agent': 'hedge-labs-fund-arena/1.0'
      }
    });
    if (!res.ok) return null;
    const data = await res.json();
    const result = data?.chart?.result?.[0];
    if (!result) return null;

    const timestamps = result.timestamp || [];
    const closes =
      result?.indicators?.adjclose?.[0]?.adjclose ||
      result?.indicators?.quote?.[0]?.close ||
      [];

    if (!Array.isArray(timestamps) || !Array.isArray(closes) || timestamps.length === 0 || closes.length === 0) {
      return null;
    }

    const dates = [];
    const cleanCloses = [];
    for (let i = 0; i < Math.min(timestamps.length, closes.length); i += 1) {
      const ts = timestamps[i];
      const close = closes[i];
      if (close == null) continue;
      const n = Number(close);
      if (!Number.isFinite(n) || n <= 0) continue;
      const d = dateFromTs(ts);
      if (!isDateStr(d)) continue;
      dates.push(d);
      cleanCloses.push(n);
    }
    if (dates.length === 0) return null;

    return { symbol, dates, closes: cleanCloses };
  } catch {
    return null;
  }
}

async function mapWithConcurrency(items, limit, mapper) {
  const results = new Array(items.length);
  let index = 0;

  async function worker() {
    while (true) {
      const i = index;
      index += 1;
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
  return [...byTicker.values()].map((h) => ({ ticker: h.ticker, weight_pct: asPct(h.weight_pct) }));
}

function listRunDates(runsRoot) {
  if (!existsSync(runsRoot)) return [];
  return readdirSync(runsRoot)
    .filter((d) => isDateStr(d))
    .sort();
}

function isSuccessfulOutput(metaPath, outputPath) {
  if (!existsSync(outputPath)) return false;
  const meta = existsSync(metaPath) ? parseJson(metaPath) : null;
  if (meta && typeof meta.status === 'string' && meta.status !== 'success') return false;
  const doc = parseJson(outputPath);
  const holdings = extractPortfolio(doc);
  return holdings.length > 0;
}

function loadSuccessfulRuns(fundId, provider, runDate) {
  const runsRoot = join('funds', fundId, 'runs');
  const dates = listRunDates(runsRoot).filter((d) => d <= runDate);
  const out = [];
  for (const d of dates) {
    const outputPath = join(runsRoot, d, provider, 'dexter_output.json');
    const metaPath = join(runsRoot, d, provider, 'run_meta.json');
    if (!isSuccessfulOutput(metaPath, outputPath)) continue;
    const doc = parseJson(outputPath);
    const holdings = extractPortfolio(doc);
    if (holdings.length === 0) continue;
    out.push({ date: d, holdings });
  }
  return out;
}

async function main() {
  const [fundId, provider, runDateArg, benchmarkTickerArg = '', benchmarkNameArg = ''] = process.argv.slice(2);
  const runDate = String(runDateArg || '').trim();
  const benchmarkTicker = String(benchmarkTickerArg || '').trim();
  const benchmarkName = String(benchmarkNameArg || '').trim() || benchmarkTicker;

  if (!fundId || !provider || !isDateStr(runDate)) {
    console.log(JSON.stringify(emptyResult({ benchmarkTicker, benchmarkName })));
    return;
  }

  const successfulRuns = loadSuccessfulRuns(fundId, provider, runDate);
  if (successfulRuns.length === 0) {
    console.log(JSON.stringify(emptyResult({ benchmarkTicker, benchmarkName })));
    return;
  }

  const inceptionDate = successfulRuns[0].date;
  const asofPortfolioDate = successfulRuns[successfulRuns.length - 1].date;

  const inceptionMs = dateMs(inceptionDate);
  const runMs = dateMs(runDate);
  if (inceptionMs == null || runMs == null) {
    console.log(JSON.stringify(emptyResult({ benchmarkTicker, benchmarkName })));
    return;
  }

  const nowEpoch = Math.floor(Date.now() / 1000);
  const period1 = Math.floor(inceptionMs / 1000) - (14 * 86400);
  const period2Candidate = Math.floor(runMs / 1000) + (4 * 86400);
  const period2 = Math.min(nowEpoch, period2Candidate);

  const segments = [];
  for (let i = 0; i < successfulRuns.length - 1; i += 1) {
    segments.push({ start: successfulRuns[i], endDate: successfulRuns[i + 1].date });
  }
  if (runDate > asofPortfolioDate) {
    segments.push({ start: successfulRuns[successfulRuns.length - 1], endDate: runDate });
  } else if (segments.length === 0) {
    // Single successful run and we're evaluating that same run date.
    segments.push({ start: successfulRuns[0], endDate: runDate });
  }

  const tickers = new Set();
  for (const seg of segments) {
    for (const h of seg.start.holdings) tickers.add(h.ticker);
  }
  if (benchmarkTicker) tickers.add(benchmarkTicker);

  const chartCache = new Map();
  const tickerList = [...tickers.values()];
  await mapWithConcurrency(tickerList, 8, async (ticker) => {
    const cacheKey = `${ticker}|${period1}|${period2}`;
    if (chartCache.has(cacheKey)) return;

    let chart = null;
    for (const symbol of symbolAliases(ticker)) {
      chart = await fetchYahooChart(symbol, period1, period2);
      if (chart) break;
    }
    chartCache.set(cacheKey, chart);
  });

  const chartFor = (ticker) => chartCache.get(`${ticker}|${period1}|${period2}`) || null;

  let nav = 100;
  let minCoverage = null;
  let alignedAsOfDate = null;

  const benchChart = benchmarkTicker ? chartFor(benchmarkTicker) : null;
  let benchNav = 100;
  let benchOk = Boolean(benchmarkTicker && benchChart);

  for (const seg of segments) {
    // Determine a single aligned price window for this segment so 24/7 assets (e.g. crypto)
    // can't advance the segment's as-of date beyond what equities/benchmark support.
    const leg = [];
    for (const h of seg.start.holdings) {
      const ticker = h.ticker;
      const weight = Number(h.weight_pct || 0);
      if (!Number.isFinite(weight) || weight <= 0) continue;
      const chart = chartFor(ticker);
      const startCandidate = closeOnOrBefore(chart, seg.start.date);
      const endCandidate = closeOnOrBefore(chart, seg.endDate);
      if (!startCandidate || !endCandidate) continue;
      leg.push({ ticker, weight, chart, startCandidate, endCandidate });
    }

    const benchStartCandidate = benchChart ? closeOnOrBefore(benchChart, seg.start.date) : null;
    const benchEndCandidate = benchChart ? closeOnOrBefore(benchChart, seg.endDate) : null;

    if (leg.length === 0) {
      console.log(JSON.stringify(emptyResult({
        benchmarkTicker,
        benchmarkName,
        inceptionDate,
        asofPortfolioDate
      })));
      return;
    }

    // Align on the earliest available boundary dates across included holdings (and benchmark when available).
    // ISO date strings compare lexicographically.
    let alignedStartDate = leg.map((x) => x.startCandidate.date).sort()[0];
    let alignedEndDate = leg.map((x) => x.endCandidate.date).sort()[0];
    if (benchOk && benchStartCandidate && benchEndCandidate) {
      if (benchStartCandidate.date < alignedStartDate) alignedStartDate = benchStartCandidate.date;
      if (benchEndCandidate.date < alignedEndDate) alignedEndDate = benchEndCandidate.date;
    }
    // Avoid a negative/ill-defined window if any symbol's data is extremely stale.
    if (alignedEndDate < alignedStartDate) alignedStartDate = alignedEndDate;

    let covered = 0;
    let weightedSum = 0;
    for (const item of leg) {
      const start = closeOnOrBefore(item.chart, alignedStartDate);
      const end = closeOnOrBefore(item.chart, alignedEndDate);
      if (!start || !end) continue;
      const ret = ((end.close / start.close) - 1) * 100;
      if (!Number.isFinite(ret)) continue;
      covered += item.weight;
      weightedSum += (item.weight * ret);
    }

    if (benchOk) {
      const start = closeOnOrBefore(benchChart, alignedStartDate);
      const end = closeOnOrBefore(benchChart, alignedEndDate);
      if (!start || !end) {
        benchOk = false;
      } else {
        const ret = ((end.close / start.close) - 1) * 100;
        if (!Number.isFinite(ret)) {
          benchOk = false;
        } else {
          benchNav *= (1 + (ret / 100));
        }
      }
    }

    if (covered <= 0) {
      console.log(JSON.stringify(emptyResult({
        benchmarkTicker,
        benchmarkName,
        inceptionDate,
        asofPortfolioDate
      })));
      return;
    }

    const segReturn = weightedSum / covered;
    nav *= (1 + (segReturn / 100));
    minCoverage = minCoverage == null ? covered : Math.min(minCoverage, covered);
    alignedAsOfDate = alignedEndDate;
  }

  const coveredWeightPct = asPct(minCoverage ?? 0);
  const fundReturn = asPct(((nav / 100) - 1) * 100);

  let benchmarkReturn = null;
  if (benchOk) benchmarkReturn = asPct(((benchNav / 100) - 1) * 100);

  // Report the common aligned as-of date used for the latest segment.
  const asofPriceDate = alignedAsOfDate || null;

  console.log(JSON.stringify({
    performance_method: 'nav_since_start',
    inception_date: inceptionDate,
    asof_portfolio_date: asofPortfolioDate,
    asof_price_date: asofPriceDate,
    fund_return_pct: fundReturn,
    covered_weight_pct: coveredWeightPct,
    benchmark_ticker: benchmarkTicker || null,
    benchmark_name: benchmarkName || null,
    benchmark_return_pct: benchmarkReturn,
    benchmark_covered_weight_pct: benchmarkReturn != null ? 100 : 0,
    excess_return_pct: (benchmarkReturn != null) ? asPct(fundReturn - benchmarkReturn) : null,
    stocks: []
  }));
}

await main();
