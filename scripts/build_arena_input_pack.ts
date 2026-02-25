#!/usr/bin/env bun
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

type CandidateConfig = {
  fund_id?: string;
  candidate_symbols?: string[];
  benchmark_symbols?: string[];
  required_symbols?: string[];
  symbol_aliases?: Record<string, string>;
};

type PortfolioItem = { ticker?: string };

type Bar = {
  date: string;
  timestamp: number;
  close: number;
  volume: number | null;
};

type SymbolMarketRecord = {
  ticker: string;
  yahoo_symbol: string;
  name: string | null;
  currency: string | null;
  exchange: string | null;
  instrument_type: string | null;
  bars_available: number;
  latest_bar_date: string | null;
  last_close: number | null;
  features: Record<string, number | boolean | null>;
  fetch_status: 'success' | 'error';
  error?: string;
};

const USAGE = 'Usage: bun run scripts/build_arena_input_pack.ts <fund_id> <run_date> <output_json_path> [prev_output_json_path]';

function die(message: string, code = 1): never {
  console.error(message);
  process.exit(code);
}

function readJsonSafe<T>(filePath: string, fallback: T): T {
  try {
    return JSON.parse(readFileSync(filePath, 'utf8')) as T;
  } catch {
    return fallback;
  }
}

function uniqTickers(values: Array<string | null | undefined>, aliases: Record<string, string>): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of values) {
    if (!raw) continue;
    const trimmed = String(raw).trim().toUpperCase();
    if (!trimmed) continue;
    const mapped = aliases[trimmed] || trimmed;
    if (seen.has(mapped)) continue;
    seen.add(mapped);
    out.push(mapped);
  }
  return out;
}

function toUtcDateString(tsMs: number): string {
  const d = new Date(tsMs);
  const yyyy = d.getUTCFullYear();
  const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(d.getUTCDate()).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}`;
}

function parseRunDate(dateStr: string): number {
  const ms = Date.parse(`${dateStr}T00:00:00Z`);
  if (!Number.isFinite(ms)) die(`Invalid run_date: ${dateStr}`);
  return ms;
}

function periodWindow(runDate: string) {
  const runMs = parseRunDate(runDate);
  const period2 = Math.floor((runMs + 86400000) / 1000); // exclusive end; include run_date daily bar
  const period1 = Math.floor((runMs - (450 * 86400000)) / 1000);
  return { period1, period2 };
}

function yahooSymbolCandidates(symbol: string): string[] {
  const s = symbol.trim();
  const candidates = [s];
  if (s.includes('.')) candidates.push(s.replace(/\./g, '-'));
  if (s.includes('-') && !s.endsWith('-USD')) candidates.push(s.replace(/-/g, '.'));
  return [...new Set(candidates)];
}

function cachePath(repoRoot: string, runDate: string, symbol: string): string {
  return join(repoRoot, '.cache', 'arena_market_data', 'yahoo_chart_1d', runDate, `${symbol.replace(/[^\w.-]+/g, '_')}.json`);
}

async function fetchWithRetry(url: string, init: RequestInit, retries: number): Promise<Response> {
  let lastErr: unknown;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      const controller = new AbortController();
      const timeoutMs = Number(process.env.YAHOO_CHART_TIMEOUT_MS || '15000');
      const timeout = setTimeout(() => controller.abort(), Number.isFinite(timeoutMs) ? timeoutMs : 15000);
      try {
        const res = await fetch(url, { ...init, signal: controller.signal });
        return res;
      } finally {
        clearTimeout(timeout);
      }
    } catch (err) {
      lastErr = err;
      if (attempt < retries) {
        const backoffMs = 250 * (attempt + 1);
        await new Promise((r) => setTimeout(r, backoffMs));
      }
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
}

function readCacheFresh(filePath: string): any | null {
  if (!existsSync(filePath)) return null;
  try {
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }
}

async function fetchYahooChart(repoRoot: string, symbol: string, runDate: string): Promise<{ resolvedSymbol: string; raw: any }> {
  const cached = readCacheFresh(cachePath(repoRoot, runDate, symbol));
  if (cached) {
    return { resolvedSymbol: String(cached._resolvedSymbol || symbol), raw: cached };
  }

  const { period1, period2 } = periodWindow(runDate);
  const retries = Number(process.env.YAHOO_MAX_RETRIES || '2');
  let lastError = 'unknown error';

  for (const candidate of yahooSymbolCandidates(symbol)) {
    const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(candidate)}?interval=1d&period1=${period1}&period2=${period2}&includeAdjustedClose=true&events=div,splits`;
    try {
      const res = await fetchWithRetry(url, {
        headers: {
          'User-Agent': 'hedge-labs-fund-arena/1.0',
          'Accept': 'application/json',
        },
      }, Number.isFinite(retries) ? retries : 2);

      if (!res.ok) {
        lastError = `HTTP ${res.status}`;
        continue;
      }
      const raw = await res.json();
      const result = raw?.chart?.result?.[0];
      if (!result?.timestamp || !result?.indicators?.quote?.[0]) {
        lastError = 'missing chart result';
        continue;
      }

      const cacheFile = cachePath(repoRoot, runDate, symbol);
      mkdirSync(dirname(cacheFile), { recursive: true });
      writeFileSync(cacheFile, `${JSON.stringify({ ...raw, _resolvedSymbol: candidate })}\n`);
      return { resolvedSymbol: candidate, raw };
    } catch (err) {
      lastError = err instanceof Error ? err.message : String(err);
    }
  }

  throw new Error(`Yahoo chart fetch failed for ${symbol}: ${lastError}`);
}

function parseYahooBars(raw: any, runDate: string): { meta: any; bars: Bar[] } {
  const result = raw?.chart?.result?.[0];
  const timestamps: number[] = Array.isArray(result?.timestamp) ? result.timestamp : [];
  const quote = result?.indicators?.quote?.[0] || {};
  const adj = result?.indicators?.adjclose?.[0]?.adjclose || [];
  const closes: any[] = Array.isArray(quote.close) ? quote.close : [];
  const volumes: any[] = Array.isArray(quote.volume) ? quote.volume : [];
  const runDateMs = parseRunDate(runDate);

  const bars: Bar[] = [];
  for (let i = 0; i < timestamps.length; i += 1) {
    const tsSec = Number(timestamps[i]);
    if (!Number.isFinite(tsSec)) continue;
    const tsMs = tsSec * 1000;
    if (tsMs > (runDateMs + 86400000 - 1)) continue;

    const closeRaw = (Array.isArray(adj) && Number.isFinite(Number(adj[i]))) ? Number(adj[i]) : Number(closes[i]);
    if (!Number.isFinite(closeRaw) || closeRaw <= 0) continue;

    const volumeRaw = Number(volumes[i]);
    bars.push({
      date: toUtcDateString(tsMs),
      timestamp: tsSec,
      close: closeRaw,
      volume: Number.isFinite(volumeRaw) ? volumeRaw : null,
    });
  }

  return { meta: result?.meta || {}, bars };
}

function round(value: number | null | undefined, decimals = 4): number | null {
  if (!Number.isFinite(Number(value))) return null;
  const v = Number(value);
  const factor = 10 ** decimals;
  return Math.round(v * factor) / factor;
}

function percentReturn(bars: Bar[], lookbackBars: number): number | null {
  if (bars.length <= lookbackBars) return null;
  const last = bars[bars.length - 1]?.close;
  const prev = bars[bars.length - 1 - lookbackBars]?.close;
  if (!Number.isFinite(last) || !Number.isFinite(prev) || prev === 0) return null;
  return round(((last / prev) - 1) * 100, 3);
}

function movingAverage(bars: Bar[], n: number): number | null {
  if (bars.length < n) return null;
  const slice = bars.slice(-n);
  const sum = slice.reduce((acc, b) => acc + b.close, 0);
  return round(sum / n, 4);
}

function realizedVol(bars: Bar[], n: number): number | null {
  if (bars.length < n + 1) return null;
  const slice = bars.slice(-(n + 1));
  const rets: number[] = [];
  for (let i = 1; i < slice.length; i += 1) {
    const a = slice[i - 1].close;
    const b = slice[i].close;
    if (!Number.isFinite(a) || !Number.isFinite(b) || a <= 0 || b <= 0) continue;
    rets.push(Math.log(b / a));
  }
  if (rets.length < n) return null;
  const mean = rets.reduce((x, y) => x + y, 0) / rets.length;
  const variance = rets.reduce((x, y) => x + ((y - mean) ** 2), 0) / rets.length;
  return round(Math.sqrt(variance) * Math.sqrt(252) * 100, 3);
}

function maxDrawdown(bars: Bar[], n: number): number | null {
  if (bars.length < 2) return null;
  const slice = bars.slice(-Math.max(2, n));
  let peak = -Infinity;
  let worst = 0;
  for (const b of slice) {
    peak = Math.max(peak, b.close);
    if (peak > 0) {
      const dd = ((b.close / peak) - 1) * 100;
      if (dd < worst) worst = dd;
    }
  }
  return round(worst, 3);
}

function trendFlag(lastClose: number | null, ma: number | null): boolean | null {
  if (!Number.isFinite(Number(lastClose)) || !Number.isFinite(Number(ma)) || Number(ma) === 0) return null;
  return Number(lastClose) > Number(ma);
}

function computeFeatures(bars: Bar[]): Record<string, number | boolean | null> {
  const lastClose = bars.length > 0 ? bars[bars.length - 1].close : null;
  const ma20 = movingAverage(bars, 20);
  const ma50 = movingAverage(bars, 50);
  const ma200 = movingAverage(bars, 200);
  const ret1w = percentReturn(bars, 5);
  const ret1m = percentReturn(bars, 21);
  const ret3m = percentReturn(bars, 63);
  const ret6m = percentReturn(bars, 126);
  const ret12m = percentReturn(bars, 252);
  const vol20 = realizedVol(bars, 20);
  const mdd63 = maxDrawdown(bars, 63);
  const mdd252 = maxDrawdown(bars, 252);

  const momentumPieces = [ret1m, ret3m, ret6m, ret12m].filter((v): v is number => Number.isFinite(Number(v)));
  const momentumComposite = momentumPieces.length > 0
    ? round(momentumPieces.reduce((a, b) => a + b, 0) / momentumPieces.length, 3)
    : null;

  return {
    return_1w_pct: ret1w,
    return_1m_pct: ret1m,
    return_3m_pct: ret3m,
    return_6m_pct: ret6m,
    return_12m_pct: ret12m,
    ma_20: ma20,
    ma_50: ma50,
    ma_200: ma200,
    above_ma_50: trendFlag(lastClose, ma50),
    above_ma_200: trendFlag(lastClose, ma200),
    vol_20d_annualized_pct: vol20,
    max_drawdown_63d_pct: mdd63,
    max_drawdown_252d_pct: mdd252,
    momentum_composite_pct: momentumComposite,
  };
}

function scoreRow(market: SymbolMarketRecord) {
  const f = market.features || {};
  return {
    ticker: market.ticker,
    last_close: market.last_close,
    asof_date: market.latest_bar_date,
    ret_1m_pct: f.return_1m_pct ?? null,
    ret_3m_pct: f.return_3m_pct ?? null,
    ret_6m_pct: f.return_6m_pct ?? null,
    ret_12m_pct: f.return_12m_pct ?? null,
    momentum_composite_pct: f.momentum_composite_pct ?? null,
    above_ma_50: f.above_ma_50 ?? null,
    above_ma_200: f.above_ma_200 ?? null,
    vol_20d_annualized_pct: f.vol_20d_annualized_pct ?? null,
    max_drawdown_63d_pct: f.max_drawdown_63d_pct ?? null,
  };
}

function fmt(v: unknown, digits = 2): string {
  const n = Number(v);
  if (!Number.isFinite(n)) return 'n/a';
  return n.toFixed(digits);
}

function buildPromptText(params: {
  runDate: string;
  quality: any;
  benchmarkRows: any[];
  holdingRows: any[];
  topMomentum: any[];
  bottomMomentum: any[];
  missingSymbols: string[];
  candidatePoolPath: string | null;
}): string {
  const {
    runDate, quality, benchmarkRows, holdingRows, topMomentum, bottomMomentum, missingSymbols, candidatePoolPath,
  } = params;

  const lines: string[] = [];
  lines.push(`Arena input pack v1 (Yahoo deterministic prices) for ${runDate}`);
  lines.push(`Pack status: ${quality?.status || 'unknown'}`);
  lines.push(`Yahoo coverage: ${quality?.yahoo_success_count ?? 0}/${quality?.yahoo_symbol_count ?? 0} (errors=${quality?.yahoo_error_count ?? 0})`);
  lines.push(`Required symbol coverage: ${quality?.required_symbol_coverage?.available_count ?? 0}/${quality?.required_symbol_coverage?.required_count ?? 0}`);
  lines.push(`Benchmark coverage: ${quality?.benchmark_coverage?.available_count ?? 0}/${quality?.benchmark_coverage?.required_count ?? 0}`);
  if (candidatePoolPath) lines.push(`Candidate pool config: ${candidatePoolPath}`);
  if (missingSymbols.length > 0) lines.push(`Missing symbols: ${missingSymbols.join(', ')}`);
  lines.push('');
  lines.push('Benchmarks (deterministic price/history features):');
  for (const row of benchmarkRows) {
    lines.push(
      `- ${row.ticker}: close=${fmt(row.last_close)} 1m=${fmt(row.ret_1m_pct)}% 3m=${fmt(row.ret_3m_pct)}% 6m=${fmt(row.ret_6m_pct)}% 12m=${fmt(row.ret_12m_pct)}% mom=${fmt(row.momentum_composite_pct)}% MA50=${String(row.above_ma_50)} MA200=${String(row.above_ma_200)}`
    );
  }
  if (holdingRows.length > 0) {
    lines.push('');
    lines.push('Current holdings (deterministic price/history features):');
    for (const row of holdingRows) {
      lines.push(
        `- ${row.ticker}: close=${fmt(row.last_close)} 1m=${fmt(row.ret_1m_pct)}% 3m=${fmt(row.ret_3m_pct)}% 6m=${fmt(row.ret_6m_pct)}% 12m=${fmt(row.ret_12m_pct)}% mom=${fmt(row.momentum_composite_pct)}% vol20=${fmt(row.vol_20d_annualized_pct)}% dd63=${fmt(row.max_drawdown_63d_pct)}%`
      );
    }
  }
  lines.push('');
  lines.push('Top momentum candidates (from deterministic pack):');
  for (const row of topMomentum) {
    lines.push(`- ${row.ticker}: mom=${fmt(row.momentum_composite_pct)}% 3m=${fmt(row.ret_3m_pct)}% 6m=${fmt(row.ret_6m_pct)}% 12m=${fmt(row.ret_12m_pct)}%`);
  }
  lines.push('');
  lines.push('Weakest momentum candidates (from deterministic pack):');
  for (const row of bottomMomentum) {
    lines.push(`- ${row.ticker}: mom=${fmt(row.momentum_composite_pct)}% 3m=${fmt(row.ret_3m_pct)}% 6m=${fmt(row.ret_6m_pct)}% 12m=${fmt(row.ret_12m_pct)}%`);
  }
  return `${lines.join('\n')}\n`;
}

async function main() {
  const [, , fundId, runDate, outPathArg, prevOutputPathArg] = process.argv;
  if (!fundId || !runDate || !outPathArg) die(USAGE, 64);

  const repoRoot = resolve(dirname(import.meta.path.replace(/^file:\/\//, '')), '..');
  const outPath = resolve(outPathArg);
  const candidatePoolPath = resolve(repoRoot, 'funds', 'arena', 'config', `${fundId}.candidates.json`);

  const candidateConfig = readJsonSafe<CandidateConfig>(candidatePoolPath, {});
  const aliases = Object.fromEntries(
    Object.entries(candidateConfig.symbol_aliases || {}).map(([k, v]) => [String(k).toUpperCase(), String(v).toUpperCase()])
  );

  const prevOutput = prevOutputPathArg ? readJsonSafe<any>(resolve(prevOutputPathArg), {}) : {};
  const previousPortfolio = Array.isArray(prevOutput?.target_portfolio) ? prevOutput.target_portfolio as PortfolioItem[] : [];
  const previousHoldings = uniqTickers(previousPortfolio.map((h) => h?.ticker), aliases);

  const candidateSymbols = uniqTickers(candidateConfig.candidate_symbols || [], aliases);
  const benchmarkSymbols = uniqTickers(candidateConfig.benchmark_symbols || ['SPY', 'QQQ'], aliases);
  const requiredBase = uniqTickers([...(candidateConfig.required_symbols || []), ...benchmarkSymbols, ...previousHoldings], aliases);
  const allSymbols = uniqTickers([...candidateSymbols, ...benchmarkSymbols, ...previousHoldings], aliases);

  const marketData: Record<string, SymbolMarketRecord> = {};
  const yahooErrors: Array<{ ticker: string; error: string }> = [];
  const sourceManifest: any = {
    yahoo_chart: {
      source: 'query1.finance.yahoo.com/v8/finance/chart',
      interval: '1d',
      symbols_requested: allSymbols,
      symbols_succeeded: [] as string[],
      symbols_failed: [] as string[],
    },
    financial_datasets: {
      included_in_pack_v1: false,
      note: 'Fundamentals/news remain qualitative via Dexter financial_search in this rollout.',
    },
  };

  const concurrency = Math.max(1, Math.min(8, Number(process.env.ARENA_YAHOO_CONCURRENCY || '6') || 6));
  let cursor = 0;
  async function worker() {
    while (true) {
      const i = cursor;
      cursor += 1;
      if (i >= allSymbols.length) return;
      const ticker = allSymbols[i];
      try {
        const { resolvedSymbol, raw } = await fetchYahooChart(repoRoot, ticker, runDate);
        const { meta, bars } = parseYahooBars(raw, runDate);
        const lastClose = bars.length > 0 ? round(bars[bars.length - 1].close, 4) : null;
        marketData[ticker] = {
          ticker,
          yahoo_symbol: resolvedSymbol,
          name: meta?.longName || meta?.shortName || null,
          currency: meta?.currency || null,
          exchange: meta?.exchangeName || null,
          instrument_type: meta?.instrumentType || null,
          bars_available: bars.length,
          latest_bar_date: bars.length > 0 ? bars[bars.length - 1].date : null,
          last_close: lastClose,
          features: computeFeatures(bars),
          fetch_status: 'success',
        };
        sourceManifest.yahoo_chart.symbols_succeeded.push(ticker);
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        marketData[ticker] = {
          ticker,
          yahoo_symbol: ticker,
          name: null,
          currency: null,
          exchange: null,
          instrument_type: null,
          bars_available: 0,
          latest_bar_date: null,
          last_close: null,
          features: {},
          fetch_status: 'error',
          error: message,
        };
        yahooErrors.push({ ticker, error: message });
        sourceManifest.yahoo_chart.symbols_failed.push(ticker);
      }
    }
  }
  await Promise.all(Array.from({ length: concurrency }, () => worker()));

  const missingRequired = requiredBase.filter((t) => marketData[t]?.fetch_status !== 'success');
  const missingBenchmarks = benchmarkSymbols.filter((t) => marketData[t]?.fetch_status !== 'success');
  const yahooSuccessCount = allSymbols.filter((t) => marketData[t]?.fetch_status === 'success').length;
  const yahooErrorCount = allSymbols.length - yahooSuccessCount;

  let qualityStatus: 'ok' | 'degraded' | 'failed' = 'ok';
  if (missingRequired.length > 0) qualityStatus = 'failed';
  else if (missingBenchmarks.length > 0 || yahooErrorCount > 0) qualityStatus = 'degraded';

  const candidateRows = candidateSymbols
    .map((ticker) => marketData[ticker])
    .filter(Boolean)
    .filter((r) => r.fetch_status === 'success')
    .map(scoreRow);
  const benchmarkRows = benchmarkSymbols
    .map((ticker) => marketData[ticker])
    .filter(Boolean)
    .filter((r) => r.fetch_status === 'success')
    .map(scoreRow);
  const holdingRows = previousHoldings
    .map((ticker) => marketData[ticker])
    .filter(Boolean)
    .filter((r) => r.fetch_status === 'success')
    .map(scoreRow);

  const sortableByMomentum = (rows: any[]) =>
    [...rows].sort((a, b) => {
      const av = Number(a.momentum_composite_pct);
      const bv = Number(b.momentum_composite_pct);
      const af = Number.isFinite(av) ? av : -Infinity;
      const bf = Number.isFinite(bv) ? bv : -Infinity;
      if (bf !== af) return bf - af;
      return String(a.ticker).localeCompare(String(b.ticker));
    });
  const topMomentum = sortableByMomentum(candidateRows).slice(0, 10);
  const bottomMomentum = [...sortableByMomentum(candidateRows)].reverse().slice(0, 10);

  const pack = {
    meta: {
      fund_id: fundId,
      run_date: runDate,
      generated_at: new Date().toISOString(),
      pack_version: 'v1',
    },
    symbols: {
      candidates: candidateSymbols,
      benchmarks: benchmarkSymbols,
      required: requiredBase,
      previous_holdings: previousHoldings,
    },
    quality: {
      status: qualityStatus,
      yahoo_symbol_count: allSymbols.length,
      yahoo_success_count: yahooSuccessCount,
      yahoo_error_count: yahooErrorCount,
      required_symbol_coverage: {
        required_count: requiredBase.length,
        available_count: requiredBase.length - missingRequired.length,
        missing_count: missingRequired.length,
        missing_symbols: missingRequired,
      },
      benchmark_coverage: {
        required_count: benchmarkSymbols.length,
        available_count: benchmarkSymbols.length - missingBenchmarks.length,
        missing_count: missingBenchmarks.length,
        missing_symbols: missingBenchmarks,
      },
      warnings: [
        ...(yahooErrorCount > 0 ? [`Yahoo fetch errors for ${yahooErrorCount} symbol(s)`] : []),
      ],
      errors: [
        ...(missingRequired.length > 0 ? [`Missing required symbol data: ${missingRequired.join(', ')}`] : []),
      ],
    },
    market_data: marketData,
    prompt_context: {
      benchmark_snapshot: benchmarkRows,
      current_holdings_snapshot: holdingRows,
      top_momentum_candidates: topMomentum,
      weakest_momentum_candidates: bottomMomentum,
    },
    source_manifest: {
      ...sourceManifest,
      yahoo_errors: yahooErrors.slice(0, 20),
      candidate_pool_path: existsSync(candidatePoolPath) ? candidatePoolPath : null,
    },
  };

  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, `${JSON.stringify(pack, null, 2)}\n`);
  writeFileSync(`${outPath}.prompt.txt`, buildPromptText({
    runDate,
    quality: pack.quality,
    benchmarkRows,
    holdingRows,
    topMomentum,
    bottomMomentum,
    missingSymbols: missingRequired,
    candidatePoolPath: existsSync(candidatePoolPath) ? candidatePoolPath : null,
  }));

  process.stdout.write(`${outPath}\n`);
}

main().catch((err) => {
  die(err instanceof Error ? err.stack || err.message : String(err));
});
