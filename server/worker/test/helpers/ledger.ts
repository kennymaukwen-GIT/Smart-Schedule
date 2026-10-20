// In-memory stand-ins for the 「該出發了」 ledger Durable Object: synchronous KV (like ctx.storage.kv on a
// SQLite-backed object), alarms, and a namespace whose stubs call the real DepartureLedger class.

import type { DurableObjectNamespaceLike } from "../../src/env.ts";
import { DepartureLedger } from "../../src/ledger.ts";
import type { SyncKv } from "../../src/ledger.ts";

export class MemorySyncKv implements SyncKv {
  readonly store = new Map<string, unknown>();

  get<T = unknown>(key: string): T | undefined {
    return this.store.get(key) as T | undefined;
  }

  put<T>(key: string, value: T): void {
    // Stored as a structured clone, like Durable Object storage.
    this.store.set(key, structuredClone(value));
  }

  delete(key: string): boolean {
    return this.store.delete(key);
  }

  *list<T = unknown>(options: { prefix?: string } = {}): Iterable<[string, T]> {
    for (const key of [...this.store.keys()].sort()) {
      if (!options.prefix || key.startsWith(options.prefix)) yield [key, this.store.get(key) as T];
    }
  }
}

export interface FakeLedger extends DurableObjectNamespaceLike {
  kv: MemorySyncKv;
  alarm: number | null;
  /** Every request the Worker sent to the object (path and JSON body). */
  requests: { op: string; body: Record<string, unknown> }[];
  /** Make the next calls fail (the object unreachable). */
  failing: boolean;
}

export function makeFakeLedger(): FakeLedger {
  const kv = new MemorySyncKv();
  const fake: FakeLedger = {
    kv,
    alarm: null,
    requests: [],
    failing: false,
    idFromName: (name: string) => name,
    get: () => ({
      async fetch(input: string, init?: RequestInit) {
        if (fake.failing) throw new Error("Durable Object unreachable");
        const request = new Request(input, init);
        fake.requests.push({ op: new URL(input).pathname.slice(1), body: (await request.clone().json()) as Record<string, unknown> });
        return object.fetch(request);
      },
    }),
  };
  const object = new DepartureLedger(
    {
      storage: {
        kv,
        getAlarm: async () => fake.alarm,
        setAlarm: async (time: number) => {
          fake.alarm = time;
        },
      },
    },
    {},
  );
  return fake;
}
