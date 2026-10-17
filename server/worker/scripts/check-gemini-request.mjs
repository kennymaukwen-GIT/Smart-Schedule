// Sends Google the same kinds of request the app sends, one piece at a time, with the key read from stdin, and prints
// Google's whole answer for each (status, message, details), so a 400 "invalid argument" names its cause.
// Run through scripts/check-gemini-request.sh (npm run check-request), which asks for the key without showing it.
// Prints no key; only HTTP statuses, Google's error text and the names of the functions the model called.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "..", "..", "..");
const key = readFileSync(0, "utf8").trim();
if (!key) { console.error("No key given."); process.exit(1); }
const xcconfig = readFileSync(join(repo, "Config", "Base.xcconfig"), "utf8");
const model = process.env.GEMINI_MODEL_ID || (xcconfig.match(/^\s*GEMINI_MODEL_ID\s*=\s*(\S+)/m) || [])[1] || "gemini-3.8-flash";
const declarations = JSON.parse(readFileSync(join(repo, "Shared", "AI", "FunctionDeclarations.json"), "utf8"));
const conversational = declarations.map((d) => d.name).filter((n) => n !== "suggest_event_notes");
const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;
const now = new Date();
const system = `You are a calendar assistant. now_local: ${now.toISOString().slice(0, 16)}. Always answer by calling a function.`;
const user = (text) => ({ role: "user", parts: [{ text }] });
const tools = [{ functionDeclarations: declarations }];
const toolConfig = { functionCallingConfig: { mode: "ANY", allowedFunctionNames: conversational } };
const thinking = { thinkingConfig: { thinkingLevel: "low" } };

async function probe(label, body) {
  let status = 0, json = null;
  try {
    const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json", "x-goog-api-key": key }, body: JSON.stringify(body) });
    status = r.status;
    json = await r.json().catch(() => null);
  } catch (e) {
    console.log(`${label.padEnd(46)} network error: ${e.message}`);
    return null;
  }
  console.log(`${label.padEnd(46)} HTTP ${status}`);
  if (json?.error) {
    console.log(`  ${json.error.status ?? ""} ${String(json.error.message ?? "").slice(0, 600)}`);
    for (const d of json.error.details ?? []) {
      const violations = d.fieldViolations ?? d.field_violations ?? [];
      for (const v of violations) console.log(`  field: ${v.field} — ${String(v.description ?? "").slice(0, 300)}`);
      if (d.reason) console.log(`  reason: ${d.reason}`);
    }
    return null;
  }
  const parts = json?.candidates?.[0]?.content?.parts ?? [];
  const calls = parts.filter((p) => p.functionCall).map((p) => p.functionCall.name);
  const text = parts.filter((p) => p.text && !p.thought).map((p) => p.text).join("").trim().slice(0, 60);
  console.log(`  ${calls.length ? `calls: ${calls.join(", ")}` : `reply: ${text}`}${parts.some((p) => p.thoughtSignature) ? " (with thoughtSignature)" : ""}`);
  return json?.candidates?.[0]?.content ?? null;
}

console.log(`Model: ${model}. ${declarations.length} function declarations, ${conversational.length} allowed in chat.`);
await probe("1. text only", { contents: [user("Reply with the single word OK.")] });
await probe("2. + thinkingLevel low", { contents: [user("Reply with the single word OK.")], generationConfig: thinking });
await probe("3. + functions, mode ANY", { contents: [user("10分鐘後吃飯")], tools, toolConfig });
const first = await probe("4. like the app: system + functions + thinking", {
  systemInstruction: { parts: [{ text: system }] }, contents: [user("10分鐘後吃飯")], tools, toolConfig, generationConfig: thinking,
});
if (first) {
  // The app's next message: the model turn as returned (thought signatures included), the function results, then the
  // new request.
  const modelTurn = { ...first, role: "model" };
  const responses = (first.parts ?? []).filter((p) => p.functionCall).map((p) => ({
    functionResponse: { name: p.functionCall.name, response: { ok: true }, ...(p.functionCall.id ? { id: p.functionCall.id } : {}) },
  }));
  const history = [user("10分鐘後吃飯"), modelTurn, ...(responses.length ? [{ role: "user", parts: responses }] : [])];
  await probe("5. like the app's second message", {
    systemInstruction: { parts: [{ text: system }] }, contents: [...history, user("明天下午兩點開會")], tools, toolConfig, generationConfig: thinking,
  });
}
