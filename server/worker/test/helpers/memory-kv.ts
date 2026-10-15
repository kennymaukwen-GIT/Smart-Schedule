// In-memory stand-in for Workers KV with the limits that matter: TTL ≥ 60 s, keys ≤ 512 bytes, expiry by the
// injected clock, sorted prefix listing with cursors. Records every write so tests can count them.

import type { KV } from "../../src/env.ts";

interface Entry {
  value: string;
  expiresAt: number | null;
}

export class MemoryKV implements KV {
  readonly store = new Map<string, Entry>();
  readonly writes: { key: string; value: string; expirationTtl?: number }[] = [];
  readonly clock: () => number;
  /** Return true to make a put for this key throw (e.g. KV's 1 write/s limit). */
  failPut: ((key: string) => boolean) | null = null;
  /** Runs before every get (to simulate a concurrent writer between a read and a write). */
  onGet: ((key: string) => void | Promise<void>) | null = null;
  readonly gets: string[] = [];

  constructor(clock: () => number) {
    this.clock = clock;
  }

  private live(key: string): Entry | null {
    const entry = this.store.get(key);
    if (!entry) return null;
    if (entry.expiresAt !== null && entry.expiresAt <= this.clock()) {
      this.store.delete(key);
      return null;
    }
    return entry;
  }

  async get(key: string): Promise<string | null> {
    this.gets.push(key);
    await this.onGet?.(key);
    return this.live(key)?.value ?? null;
  }

  async put(key: string, value: string, options?: { expirationTtl?: number; expiration?: number }): Promise<void> {
    if (new TextEncoder().encode(key).length > 512) throw new Error("KV key longer than 512 bytes");
    if (options?.expirationTtl !== undefined && options.expirationTtl < 60) throw new Error("KV expirationTtl must be >= 60");
    if (this.failPut?.(key)) throw new Error("KV PUT failed: 429 Too Many Requests");
    const expiresAt = options?.expirationTtl !== undefined ? this.clock() + options.expirationTtl * 1000 : null;
    this.store.set(key, { value, expiresAt });
    const write: { key: string; value: string; expirationTtl?: number } = { key, value };
    if (options?.expirationTtl !== undefined) write.expirationTtl = options.expirationTtl;
    this.writes.push(write);
  }

  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }

  async list(options: { prefix: string; cursor?: string; limit?: number }) {
    const limit = options.limit ?? 1000;
    const names = [...this.store.keys()].filter((k) => k.startsWith(options.prefix) && this.live(k)).sort();
    const start = options.cursor ? Number(options.cursor) : 0;
    const page = names.slice(start, start + limit);
    const done = start + limit >= names.length;
    return done
      ? { keys: page.map((name) => ({ name })), list_complete: true }
      : { keys: page.map((name) => ({ name })), list_complete: false, cursor: String(start + limit) };
  }

  /** Live keys with this prefix (test convenience). */
  keysWithPrefix(prefix: string): string[] {
    return [...this.store.keys()].filter((k) => k.startsWith(prefix) && this.live(k)).sort();
  }
}
