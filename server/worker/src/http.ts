// JSON responses, the error envelope {"error":"<code>"}, request-body limits and structured logs.

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

export function errorResponse(status: number, code: string, headers: Record<string, string> = {}): Response {
  return json(status, { error: code }, headers);
}

/** Thrown inside handlers; the router turns it into {"error":code}. */
export class HttpError extends Error {
  readonly status: number;
  readonly code: string;
  readonly headers: Record<string, string>;
  constructor(status: number, code: string, headers: Record<string, string> = {}) {
    super(code);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
    this.headers = headers;
  }
}

/**
 * Reads the whole body (exact bytes), never more than `limit` bytes.
 *
 * With Content-Length (what URLSession and Cloudflare send): rejects a declared size above `limit` before reading,
 * allocates the buffer once, and answers 413 when more or fewer bytes arrive than declared. Without it (chunked):
 * reads incrementally and stops at `limit`.
 */
export async function readBody(request: Request, limit: number): Promise<Uint8Array> {
  const header = request.headers.get("content-length");
  if (!request.body) {
    if (header !== null && header !== "0") throw new HttpError(413, "payload_too_large");
    return new Uint8Array(0);
  }
  const reader = request.body.getReader();
  const fail = async (status: number, code: string): Promise<never> => {
    await reader.cancel().catch(() => {});
    throw new HttpError(status, code);
  };

  if (header !== null) {
    if (!/^\d{1,10}$/.test(header)) return fail(400, "invalid_request");
    const declared = Number(header);
    if (declared > limit) return fail(413, "payload_too_large");
    const out = new Uint8Array(declared);
    let offset = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (offset + value.byteLength > declared) return fail(413, "payload_too_large");
      out.set(value, offset);
      offset += value.byteLength;
    }
    if (offset !== declared) throw new HttpError(413, "payload_too_large");
    return out;
  }

  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) return fail(413, "payload_too_large");
    chunks.push(value);
  }
  if (chunks.length === 1) return chunks[0]!;
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}

export function parseJson(bytes: Uint8Array): unknown {
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
  } catch {
    return undefined;
  }
}

/** One JSON line per event; never pass secrets, tokens or request bodies. */
export function log(level: "info" | "warn" | "error", event: string, fields: Record<string, unknown> = {}): void {
  const line = JSON.stringify({ level, event, ...fields });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}
