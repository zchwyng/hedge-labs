#!/usr/bin/env bun
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { config } from 'dotenv';

config({ quiet: true });

async function loadAgentCtor() {
  const importPaths = [
    'dexter-ts/src/agent/index.js',
    'dexter-ts/src/agent/agent.js',
  ];

  for (const importPath of importPaths) {
    try {
      const mod = await import(importPath);
      if (typeof mod.Agent === 'function') {
        return mod.Agent as {
          create(config: { model: string; maxIterations: number }): {
            run(query: string): AsyncGenerator<{
              type: string;
              answer?: unknown;
              iterations?: number;
              tool?: string;
              args?: Record<string, unknown>;
              result?: string;
              duration?: number;
            }>;
          };
        };
      }
    } catch {
      // Try next candidate path.
    }
  }

  throw new Error(
    'Unable to import Dexter Agent from dexter-ts. Ensure dexter-ts is installed and compatible.'
  );
}

async function loadCallLlm() {
  const importPaths = [
    'dexter-ts/src/model/llm.js',
    'dexter-ts/src/model/llm.ts',
  ];

  for (const importPath of importPaths) {
    try {
      const mod = await import(importPath);
      if (typeof mod.callLlm === 'function') {
        return mod.callLlm as (prompt: string, options: { model?: string; systemPrompt?: string }) => Promise<{ response: string }>;
      }
    } catch {
      // Try next candidate path.
    }
  }

  throw new Error('Unable to import callLlm from dexter-ts');
}

function extractJsonObject(text: string): string {
  const raw = String(text || '').trim();
  if (!raw) return '';

  // Fast path: already JSON.
  if (raw.startsWith('{') && raw.endsWith('}')) {
    try {
      JSON.parse(raw);
      return raw;
    } catch {
      // Fall through.
    }
  }

  // Best-effort: find first '{' and last '}' and try parse.
  const start = raw.indexOf('{');
  const end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return '';
  const candidate = raw.slice(start, end + 1).trim();
  try {
    JSON.parse(candidate);
    return candidate;
  } catch {
    return '';
  }
}

function summarizeFinancialSearchResult(result: string): string {
  let doc: any;
  try {
    doc = JSON.parse(result);
  } catch {
    return `financial_search result (non-JSON, length=${result.length})`;
  }

  const data = doc?.data && typeof doc.data === 'object' ? doc.data : {};
  const sourceUrls = Array.isArray(doc?.sourceUrls) ? doc.sourceUrls : [];
  const errors = [
    ...(Array.isArray(doc?._errors) ? doc._errors : []),
    ...(Array.isArray(doc?.errors) ? doc.errors : []),
    ...(Array.isArray(doc?.data?._errors) ? doc.data._errors : []),
    ...(Array.isArray(doc?.data?.errors) ? doc.data.errors : []),
  ];
  const keys = Object.keys(data).sort();
  const keyRatios: Array<{ ticker: string; pe?: number; roe?: number; revenue_growth?: number }> = [];
  const newsHits: Array<{ ticker: string; headlines: number }> = [];

  for (const [k, v] of Object.entries<any>(data)) {
    if (k.startsWith('get_key_ratios_') && v && typeof v === 'object') {
      keyRatios.push({
        ticker: String((v as any).ticker || k.replace('get_key_ratios_', '')).trim(),
        pe: Number((v as any).pe_ratio ?? (v as any).price_to_earnings_ratio),
        roe: Number((v as any).return_on_equity ?? (v as any).roe),
        revenue_growth: Number((v as any).revenue_growth ?? (v as any).revenue_growth_yoy),
      });
    }
    if (k.startsWith('get_news_') && Array.isArray(v)) {
      const ticker = String(k.replace('get_news_', '')).trim();
      newsHits.push({ ticker, headlines: v.length });
    }
  }

  keyRatios.sort((a, b) => a.ticker.localeCompare(b.ticker));
  newsHits.sort((a, b) => a.ticker.localeCompare(b.ticker));

  const lines: string[] = [];
  lines.push(`financial_search: sources=${sourceUrls.length}`);
  lines.push(`data_keys=${keys.length}`);
  if (errors.length > 0) {
    lines.push(`errors=${errors.length}`);
  }
  if (keys.length > 0) {
    lines.push(`keys_sample=${keys.slice(0, 8).join(', ')}`);
  }

  if (keyRatios.length > 0) {
    lines.push('key_ratios:');
    for (const r of keyRatios.slice(0, 20)) {
      const pe = Number.isFinite(r.pe) ? r.pe!.toFixed(2) : 'n/a';
      const roe = Number.isFinite(r.roe) ? `${(r.roe! * 100).toFixed(1)}%` : 'n/a';
      const growth = Number.isFinite(r.revenue_growth) ? `${(r.revenue_growth! * 100).toFixed(1)}%` : 'n/a';
      lines.push(`- ${r.ticker}: pe=${pe} roe=${roe} revenue_growth=${growth}`);
    }
  }

  if (newsHits.length > 0) {
    lines.push('news_headlines:');
    for (const n of newsHits.slice(0, 20)) {
      lines.push(`- ${n.ticker}: ${n.headlines}`);
    }
  }

  return lines.join('\n');
}

function buildToolSummary(toolCalls: Array<{ tool: string; args: Record<string, unknown>; result: string }>): string {
  if (toolCalls.length === 0) return 'n/a';

  const blocks: string[] = [];
  for (const call of toolCalls.slice(0, 6)) {
    if (call.tool === 'financial_search') {
      blocks.push(`TOOL financial_search\nquery=${String((call.args as any)?.query || '').slice(0, 400)}\n${summarizeFinancialSearchResult(call.result)}`);
      continue;
    }
    blocks.push(`TOOL ${call.tool}\nargs=${JSON.stringify(call.args)}\nresult_len=${call.result.length}`);
  }
  return blocks.join('\n\n');
}

const promptFile = process.env.DEXTER_PROMPT_FILE;
if (!promptFile) {
  throw new Error('DEXTER_PROMPT_FILE is required');
}

const model = (process.env.DEXTER_MODEL || 'gpt-5.2').trim();
const maxIterations = Number(process.env.DEXTER_MAX_ITERATIONS || '10');
if (!Number.isFinite(maxIterations) || maxIterations <= 0) {
  throw new Error(`Invalid DEXTER_MAX_ITERATIONS: ${process.env.DEXTER_MAX_ITERATIONS || ''}`);
}

const query = readFileSync(resolve(promptFile), 'utf8').trim();
if (!query) {
  throw new Error(`Prompt file is empty: ${promptFile}`);
}

const Agent = await loadAgentCtor();
const agent = Agent.create({
  model,
  maxIterations,
});

let finalAnswer = '';
let totalIterations = 0;
let toolCalls = 0;
const toolResults: Array<{ tool: string; args: Record<string, unknown>; result: string }> = [];

for await (const event of agent.run(query)) {
  if (event.type === 'tool_start') {
    toolCalls += 1;
  }

  if (event.type === 'tool_end') {
    toolResults.push({
      tool: String(event.tool || ''),
      args: (event.args && typeof event.args === 'object') ? event.args : {},
      result: String(event.result || ''),
    });
  }

  if (event.type === 'done') {
    finalAnswer = typeof event.answer === 'string' ? event.answer : '';
    if (typeof event.iterations === 'number') {
      totalIterations = event.iterations;
    }
    break;
  }
}

if (!finalAnswer.trim()) {
  throw new Error('Dexter returned empty final answer');
}

let output = extractJsonObject(finalAnswer);
if (!output) {
  // Some models strongly follow Dexter's CLI system prompt and will ignore "Output ONLY JSON".
  // When that happens, do a strict "JSON-only" synthesis pass without tools, using a compact tool-results summary.
  const callLlm = await loadCallLlm();
  const toolSummary = buildToolSummary(toolResults);
  const fixPrompt =
    `You must return ONLY one valid JSON object (no markdown, no prose, no code fences).\n` +
    `Begin with '{' and end with '}'.\n\n` +
    `ASSIGNMENT:\n${query}\n\n` +
    `TOOL RESULTS (summarized):\n${toolSummary}\n\n` +
    `DRAFT ANSWER (invalid):\n${finalAnswer}\n\n` +
    `Return ONLY the corrected JSON object now.`;

  const { response } = await callLlm(fixPrompt, {
    model,
    systemPrompt:
      'You are a strict JSON generator. Output must be a single valid JSON object with no surrounding text. Do not use markdown.',
  });

  output = extractJsonObject(String(response || ''));
  if (!output) {
    throw new Error('Dexter returned non-JSON output even after JSON-only synthesis pass');
  }
}

process.stderr.write(`dexter_info: model=${model} iterations=${totalIterations} tool_calls=${toolCalls}\n`);
process.stdout.write(`${output.trim()}\n`);
