import { readFileSync } from 'node:fs';

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

function dayBefore(dateStr) {
  const d = new Date(`${dateStr}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
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
    const res = await fetch(url, { headers: { 'User-Agent': 'hedge-labs-fund-arena/1.0' } });
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

function safeJson(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
}

function emptyResult(startDate, endDate) {
  return {
    start_date: startDate,
    end_date: endDate,
    asof_price_date: null,
    items: []
  };
}

async function main() {
  const [startDateArg, endDateArg, indicesPathArg] = process.argv.slice(2);
  const startDate = String(startDateArg || '').trim();
  const endDate = String(endDateArg || '').trim();
  const indicesPath = String(indicesPathArg || '').trim();

  if (!isDateStr(startDate) || !isDateStr(endDate) || !indicesPath) {
    console.log(JSON.stringify(emptyResult(startDate || null, endDate || null)));
    return;
  }

  const indicesRaw = safeJson(indicesPath);
  const indices = Array.isArray(indicesRaw) ? indicesRaw : [];
  const itemsIn = indices
    .map((x) => ({
      ticker: String(x?.ticker || '').trim(),
      name: String(x?.name || '').trim()
    }))
    .filter((x) => x.ticker);

  if (itemsIn.length === 0) {
    console.log(JSON.stringify(emptyResult(startDate, endDate)));
    return;
  }

  const startMs = dateMs(startDate);
  const endMs = dateMs(endDate);
  if (startMs == null || endMs == null) {
    console.log(JSON.stringify(emptyResult(startDate, endDate)));
    return;
  }

  const nowEpoch = Math.floor(Date.now() / 1000);
  const period1 = Math.floor(startMs / 1000) - (14 * 86400);
  const period2Candidate = Math.floor(endMs / 1000) + (4 * 86400);
  const period2 = Math.min(nowEpoch, period2Candidate);

  const chartCache = new Map();
  await mapWithConcurrency(itemsIn, 6, async ({ ticker }) => {
    const cacheKey = `${ticker}|${period1}|${period2}`;
    if (chartCache.has(cacheKey)) return;

    let chart = null;
    for (const symbol of symbolAliases(ticker)) {
      chart = await fetchYahooChart(symbol, period1, period2);
      if (chart) break;
    }
    chartCache.set(cacheKey, chart);
  });

  const outItems = [];
  // Conservative "as of" date for the whole block: earliest end-date we used among indices.
  let asofMin = null;

  for (const { ticker, name } of itemsIn) {
    const chart = chartCache.get(`${ticker}|${period1}|${period2}`) || null;
    const start = closeOnOrBefore(chart, dayBefore(startDate));
    const end = closeOnOrBefore(chart, endDate);
    if (!start || !end) {
      outItems.push({ ticker, name: name || ticker, return_pct: null, asof_price_date: null });
      continue;
    }

    const ret = ((end.close / start.close) - 1) * 100;
    outItems.push({
      ticker,
      name: name || ticker,
      return_pct: Number.isFinite(ret) ? asPct(ret) : null,
      asof_price_date: end.date
    });
    if (end.date && (!asofMin || end.date < asofMin)) asofMin = end.date;
  }

  console.log(JSON.stringify({
    start_date: startDate,
    end_date: endDate,
    asof_price_date: asofMin,
    items: outItems
  }));
}

await main();
