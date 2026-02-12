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

function emptyResult(benchmarkTicker = '', benchmarkName = '') {
  return {
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

async function fetchSinceReturn(ticker, sinceDate) {
  const sinceMs = Date.parse(`${sinceDate}T00:00:00Z`);
  if (!Number.isFinite(sinceMs)) {
    return null;
  }

  const period1 = Math.floor(sinceMs / 1000) - (3 * 86400);
  const period2 = Math.floor(Date.now() / 1000);
  const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(ticker)}?interval=1d&period1=${period1}&period2=${period2}`;

  try {
    const res = await fetch(url, {
      headers: {
        'User-Agent': 'hedge-labs-fund-arena/1.0'
      }
    });
    if (!res.ok) {
      return null;
    }

    const data = await res.json();
    const result = data?.chart?.result?.[0];
    if (!result) {
      return null;
    }

    const timestamps = result.timestamp || [];
    const closes =
      result?.indicators?.adjclose?.[0]?.adjclose ||
      result?.indicators?.quote?.[0]?.close ||
      [];

    if (!timestamps.length || !closes.length) {
      return null;
    }

    let entryClose = null;
    let entryDateUsed = sinceDate;
    let latestClose = null;

    for (let i = 0; i < timestamps.length; i += 1) {
      const close = closes[i];
      if (close == null) continue;

      const d = dateFromTs(timestamps[i]);
      if (entryClose == null && d >= sinceDate) {
        entryClose = Number(close);
        entryDateUsed = d;
      }
      latestClose = Number(close);
    }

    if (entryClose == null || latestClose == null || entryClose <= 0) {
      return null;
    }

    return {
      since_date: entryDateUsed,
      return_pct: asPct(((latestClose / entryClose) - 1) * 100)
    };
  } catch {
    return null;
  }
}

async function main() {
  const [fundId, provider, runDate, benchmarkTickerArg = '', benchmarkNameArg = ''] = process.argv.slice(2);
  const benchmarkTicker = benchmarkTickerArg.trim();
  const benchmarkName = benchmarkNameArg.trim() || benchmarkTicker;
  if (!fundId || !provider || !runDate) {
    console.log(JSON.stringify(emptyResult(benchmarkTicker, benchmarkName)));
    return;
  }

  const latestPath = join('funds', fundId, 'runs', runDate, provider, 'dexter_output.json');
  if (!existsSync(latestPath)) {
    console.log(JSON.stringify(emptyResult(benchmarkTicker, benchmarkName)));
    return;
  }

  const latest = parseJson(latestPath);
  const holdings = latest?.target_portfolio || [];
  if (!Array.isArray(holdings) || holdings.length === 0) {
    console.log(JSON.stringify(emptyResult(benchmarkTicker, benchmarkName)));
    return;
  }

  const tickerWeight = new Map();
  for (const h of holdings) {
    if (!h || typeof h.ticker !== 'string') continue;
    const w = Number(h.weight_pct || 0);
    tickerWeight.set(h.ticker, Number.isFinite(w) ? w : 0);
  }

  const tickerSince = new Map();
  const runsRoot = join('funds', fundId, 'runs');
  const runDates = existsSync(runsRoot)
    ? readdirSync(runsRoot)
        .filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d))
        .sort()
    : [];

  for (const d of runDates) {
    const p = join(runsRoot, d, provider, 'dexter_output.json');
    if (!existsSync(p)) continue;

    const run = parseJson(p);
    const runTickers = new Set((run?.target_portfolio || []).map((x) => x?.ticker).filter(Boolean));

    for (const ticker of tickerWeight.keys()) {
      if (!tickerSince.has(ticker) && runTickers.has(ticker)) {
        tickerSince.set(ticker, d);
      }
    }
  }

  const stocks = [];
  for (const [ticker, weight] of tickerWeight.entries()) {
    const sinceDate = tickerSince.get(ticker) || runDate;
    const perf = await fetchSinceReturn(ticker, sinceDate);
    if (!perf) continue;

    stocks.push({
      ticker,
      since_date: perf.since_date,
      return_pct: perf.return_pct,
      weight_pct: asPct(weight)
    });
  }

  stocks.sort((a, b) => b.return_pct - a.return_pct);

  const coveredWeight = stocks.reduce((sum, s) => sum + s.weight_pct, 0);
  let fundReturn = null;
  if (coveredWeight > 0) {
    const weighted = stocks.reduce((sum, s) => sum + (s.weight_pct * s.return_pct), 0);
    fundReturn = asPct(weighted / coveredWeight);
  }

  let benchmarkReturn = null;
  let benchmarkCoveredWeight = 0;
  const benchmarkSinceCache = new Map();
  if (benchmarkTicker && coveredWeight > 0) {
    for (const stock of stocks) {
      if (!benchmarkSinceCache.has(stock.since_date)) {
        const benchmarkPerf = await fetchSinceReturn(benchmarkTicker, stock.since_date);
        benchmarkSinceCache.set(stock.since_date, benchmarkPerf);
      }

      const benchmarkPerf = benchmarkSinceCache.get(stock.since_date);
      if (!benchmarkPerf) continue;

      benchmarkCoveredWeight += stock.weight_pct;
      benchmarkReturn = (benchmarkReturn ?? 0) + (stock.weight_pct * benchmarkPerf.return_pct);
    }

    if (benchmarkReturn != null && benchmarkCoveredWeight > 0) {
      benchmarkReturn = asPct(benchmarkReturn / benchmarkCoveredWeight);
      benchmarkCoveredWeight = asPct(benchmarkCoveredWeight);
    } else {
      benchmarkReturn = null;
      benchmarkCoveredWeight = 0;
    }
  }

  console.log(JSON.stringify({
    fund_return_pct: fundReturn,
    covered_weight_pct: asPct(coveredWeight),
    benchmark_ticker: benchmarkTicker || null,
    benchmark_name: benchmarkName || null,
    benchmark_return_pct: benchmarkReturn,
    benchmark_covered_weight_pct: benchmarkCoveredWeight,
    excess_return_pct: (fundReturn != null && benchmarkReturn != null) ? asPct(fundReturn - benchmarkReturn) : null,
    stocks
  }));
}

await main();
