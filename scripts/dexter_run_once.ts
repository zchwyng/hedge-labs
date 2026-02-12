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

for await (const event of agent.run(query)) {
  if (event.type === 'tool_start') {
    toolCalls += 1;
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

process.stderr.write(`dexter_info: model=${model} iterations=${totalIterations} tool_calls=${toolCalls}\n`);
process.stdout.write(`${finalAnswer.trim()}\n`);
