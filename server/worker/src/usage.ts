// What one Gemini answer cost, from the usageMetadata Google returns with every generateContent response.
//
// The proxy reads only these counts (never the text) and logs one line per answer, so `npx wrangler tail` shows the
// real cost of each request as it happens. Prices are per million tokens in USD, from wrangler.toml [vars]; Google
// bills thinking tokens as output, and tokens served from its implicit cache at the cached price.

import type { Env } from "./env.ts";

export interface GeminiUsage {
  /** All input tokens: system instruction, function declarations, history, the new message, images, PDF pages. */
  prompt: number;
  /** Of `prompt`, the tokens Google served from its implicit cache (billed at the cached price). */
  cached: number;
  /** Tokens of tool-use prompts (e.g. search results); billed as input. The app's requests have none. */
  toolPrompt: number;
  /** The answer: text and function calls. */
  output: number;
  /** Thinking tokens, billed as output. */
  thoughts: number;
  /** Of `prompt`, the tokens images and PDF pages took (0 without attachments). */
  image: number;
  document: number;
}

export interface GeminiPrices {
  inputPerM: number;
  cachedPerM: number;
  outputPerM: number;
}

/** Gemini 3.8 Flash list prices until 31 Dec 2026 (USD per million tokens); wrangler.toml overrides them. */
export const DEFAULT_PRICES: GeminiPrices = { inputPerM: 0.75, cachedPerM: 0.075, outputPerM: 3.75 };

function price(raw: string | undefined, fallback: number): number {
  const value = Number(raw?.trim());
  return raw?.trim() && Number.isFinite(value) && value >= 0 ? value : fallback;
}

export function geminiPrices(env: Env): GeminiPrices {
  return {
    inputPerM: price(env.GEMINI_INPUT_USD_PER_M, DEFAULT_PRICES.inputPerM),
    cachedPerM: price(env.GEMINI_CACHED_USD_PER_M, DEFAULT_PRICES.cachedPerM),
    outputPerM: price(env.GEMINI_OUTPUT_USD_PER_M, DEFAULT_PRICES.outputPerM),
  };
}

function count(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** The counts of a generateContent response, or undefined when it has no usageMetadata. */
export function usageOf(response: unknown): GeminiUsage | undefined {
  if (!isObject(response) || !isObject(response.usageMetadata)) return undefined;
  const u = response.usageMetadata;
  const byModality = (name: string): number => {
    if (!Array.isArray(u.promptTokensDetails)) return 0;
    return u.promptTokensDetails
      .filter((d): d is Record<string, unknown> => isObject(d) && d.modality === name)
      .reduce((sum, d) => sum + count(d.tokenCount), 0);
  };
  const prompt = count(u.promptTokenCount);
  return {
    prompt,
    cached: Math.min(count(u.cachedContentTokenCount), prompt),
    toolPrompt: count(u.toolUsePromptTokenCount),
    output: count(u.candidatesTokenCount),
    thoughts: count(u.thoughtsTokenCount),
    image: byModality("IMAGE"),
    document: byModality("DOCUMENT"),
  };
}

/** USD, rounded to 6 decimals (a millionth of a dollar). */
export function costUSD(usage: GeminiUsage, prices: GeminiPrices): number {
  const uncachedInput = usage.prompt - usage.cached + usage.toolPrompt;
  const usd =
    (uncachedInput * prices.inputPerM + usage.cached * prices.cachedPerM + (usage.output + usage.thoughts) * prices.outputPerM) /
    1_000_000;
  return Math.round(usd * 1_000_000) / 1_000_000;
}

/** The first candidate's finishReason (e.g. STOP, MAX_TOKENS, MALFORMED_FUNCTION_CALL), when there is one. */
export function finishReasonOf(response: unknown): string | undefined {
  if (!isObject(response) || !Array.isArray(response.candidates)) return undefined;
  const first = response.candidates[0];
  return isObject(first) && typeof first.finishReason === "string" ? first.finishReason.slice(0, 40) : undefined;
}

/** The model that answered (`modelVersion`), else the one in the path. */
export function modelOf(response: unknown, pathModel: string): string {
  const version = isObject(response) && typeof response.modelVersion === "string" ? response.modelVersion : pathModel;
  return version.slice(0, 64);
}
