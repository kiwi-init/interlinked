import assert from "node:assert/strict";
import test from "node:test";
import { cacheLifetimeMs, createRelay, type CacheStore } from "./app.js";

class MemoryCache implements CacheStore {
  values = new Map<string, { response: unknown; expiresAt: number }>();
  count = 0;
  async get(key: string, now: number) {
    const value = this.values.get(key);
    return value && value.expiresAt > now ? value.response : undefined;
  }
  async put(key: string, response: unknown, expiresAt: number) { this.values.set(key, { response, expiresAt }); }
  async consume() { this.count += 1; return this.count <= 250; }
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const body = encoder.encode(JSON.stringify({
  model: "typesafe/jev-1.13",
  state: "Untrusted source",
  provider: { data_collection: "deny" },
  questions: { page: { type: "choice", instructions: "Classify", criteria: { none: "None" } } }
}));

test("authenticates TestFlight, caches exact requests for five days, and hides the key", async () => {
  const cache = new MemoryCache();
  let now = 1_000;
  let upstreamCalls = 0;
  const relay = createRelay({
    cache,
    now: () => now,
    verifyAppTransaction: async jws => { assert.equal(jws, "signed-by-apple"); return "tester-1"; },
    callOpenRouter: async received => {
      upstreamCalls += 1;
      assert.deepEqual(received, body);
      return { status: 200, body: encoder.encode('{"answers":{"page":{"type":"choice","choice":"none","confidence":0.9}}}') };
    }
  });
  const request = { method: "POST", path: "/v1/jev", headers: { "x-interlinked-app-transaction": "signed-by-apple" }, body };
  const first = await relay(request);
  const second = await relay(request);
  assert.equal(first.headers?.["x-interlinked-cache"], "miss");
  assert.equal(second.headers?.["x-interlinked-cache"], "hit");
  assert.equal(upstreamCalls, 1);

  now += cacheLifetimeMs + 1;
  await relay(request);
  assert.equal(upstreamCalls, 2);
  assert.doesNotMatch(decoder.decode(first.body), /OpenRouter|api.key/i);
});

test("rejects unsigned and arbitrary model requests before spending", async () => {
  const cache = new MemoryCache();
  let upstreamCalls = 0;
  const relay = createRelay({
    cache,
    now: () => 1_000,
    verifyAppTransaction: async () => "tester",
    callOpenRouter: async () => { upstreamCalls += 1; return { status: 500, body: new Uint8Array() }; }
  });
  const unsigned = await relay({ method: "POST", path: "/v1/jev", headers: {}, body });
  const arbitrary = await relay({ method: "POST", path: "/v1/jev", headers: { "x-interlinked-app-transaction": "signed" }, body: encoder.encode('{"model":"other"}') });
  assert.equal(unsigned.status, 401);
  assert.equal(arbitrary.status, 400);
  assert.equal(upstreamCalls, 0);
});

const signedRelay = (callOpenRouter: (body: Uint8Array, signal: AbortSignal) => Promise<{ status: number; body: Uint8Array }>, upstreamTimeoutMs?: number) => {
  const relay = createRelay({
    cache: new MemoryCache(),
    now: () => 1_000,
    verifyAppTransaction: async () => "tester",
    callOpenRouter,
    upstreamTimeoutMs
  });
  return (value: unknown) => relay({
    method: "POST",
    path: "/v1/jev",
    headers: { "x-interlinked-app-transaction": "signed" },
    body: encoder.encode(JSON.stringify(value))
  });
};

test("rejects unknown fields at every level before spending", async () => {
  let upstreamCalls = 0;
  const send = signedRelay(async () => { upstreamCalls += 1; return { status: 200, body: encoder.encode("{}") }; });
  const valid = JSON.parse(decoder.decode(body));

  assert.equal((await send({ ...valid, temperature: 2 })).status, 400);
  assert.equal((await send({ ...valid, stream: true })).status, 400);
  assert.equal((await send({ ...valid, provider: { data_collection: "deny", order: ["other"] } })).status, 400);
  assert.equal((await send({ ...valid, questions: { page: { ...valid.questions.page, max_tokens: 9 } } })).status, 400);
  assert.equal(upstreamCalls, 0);

  const score = { type: "score", instructions: "Rate", criteria: ["low", "high"] };
  assert.equal((await send({ ...valid, questions: { ...valid.questions, score } })).status, 200);
  assert.equal(upstreamCalls, 1);
});

test("answers a hanging upstream with 503 once the deadline passes", async () => {
  let aborted = false;
  const send = signedRelay((_, signal) => {
    signal.addEventListener("abort", () => { aborted = true; });
    return new Promise(() => {});
  }, 50);
  const started = Date.now();
  const response = await send(JSON.parse(decoder.decode(body)));

  assert.equal(response.status, 503);
  assert.deepEqual(JSON.parse(decoder.decode(response.body)), { error: "unavailable" });
  assert.ok(Date.now() - started < 1_000);
  assert.ok(aborted);
});
