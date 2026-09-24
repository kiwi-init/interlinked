import { createHash } from "node:crypto";

export const cacheLifetimeMs = 5 * 24 * 60 * 60 * 1000;
const maxBodyBytes = 2_000_000;
const maxQuestions = 1_000;
export const upstreamTimeoutMs = 60_000;

export interface CacheStore {
  get(key: string, now: number): Promise<unknown | undefined>;
  put(key: string, response: unknown, expiresAt: number): Promise<void>;
  consume(user: string, day: string, limit: number): Promise<boolean>;
}

export interface RelayDependencies {
  verifyAppTransaction(jws: string): Promise<string>;
  cache: CacheStore;
  callOpenRouter(body: Uint8Array, signal: AbortSignal): Promise<{ status: number; body: Uint8Array }>;
  now(): number;
  /** Deadline for the whole upstream call. Defaults to `upstreamTimeoutMs`. */
  upstreamTimeoutMs?: number;
}

export interface RelayRequest {
  method: string;
  path: string;
  headers: Record<string, string | undefined>;
  body: Uint8Array;
}

export interface RelayResponse {
  status: number;
  headers?: Record<string, string>;
  body: Uint8Array;
}

const encoder = new TextEncoder();
const json = (status: number, value: unknown, headers: Record<string, string> = {}): RelayResponse => ({
  status,
  headers: { "content-type": "application/json", ...headers },
  body: encoder.encode(JSON.stringify(value))
});

// The only request shape the relay forwards. It mirrors `JevRequest` and
// `JevQuestion` in Interlinked/Model/Jev.swift; change both together.
//
//   {
//     "model": "typesafe/jev-1.13",
//     "state": string, at most 1,500,000 characters,
//     "provider": { "data_collection": "deny" },
//     "questions": {                      // 1 to 1,000 entries
//       "<id>": {
//         "type": "choice" | "noul" | "score",
//         "instructions": string,         // at most 8,000 characters
//         "criteria": object              // { option: description }, or an array of levels for "score"
//       }
//     }
//   }
//
// Any other key, at the top level, in `provider`, or in a question, is
// rejected so a client cannot pass extra OpenRouter parameters such as
// `stream` through the relay.
const decisionKeys = new Set(["model", "state", "provider", "questions"]);
const providerKeys = new Set(["data_collection"]);
const questionKeys = new Set(["type", "instructions", "criteria"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, allowed: Set<string>): boolean {
  return Object.keys(value).every(key => allowed.has(key));
}

function validDecision(body: Uint8Array): boolean {
  if (body.byteLength === 0 || body.byteLength > maxBodyBytes) return false;
  let decision: unknown;
  try { decision = JSON.parse(new TextDecoder().decode(body)); } catch { return false; }
  if (!isRecord(decision) || !hasOnlyKeys(decision, decisionKeys)) return false;
  if (decision.model !== "typesafe/jev-1.13" || typeof decision.state !== "string") return false;
  if (decision.state.length > 1_500_000) return false;
  const provider = decision.provider;
  if (!isRecord(provider) || !hasOnlyKeys(provider, providerKeys) || provider.data_collection !== "deny") return false;
  const questions = decision.questions;
  if (!isRecord(questions)) return false;
  const entries = Object.values(questions);
  if (entries.length === 0 || entries.length > maxQuestions) return false;
  return entries.every(question => {
    if (!isRecord(question) || !hasOnlyKeys(question, questionKeys)) return false;
    if (!["choice", "noul", "score"].includes(String(question.type))) return false;
    if (typeof question.instructions !== "string" || question.instructions.length > 8_000) return false;
    return question.criteria !== null && typeof question.criteria === "object";
  });
}

// Settles with `work`, or rejects when `timeoutMs` passes first. The signal
// lets `work` cancel its own I/O; the race covers work that ignores it.
function withDeadline<T>(timeoutMs: number, work: (signal: AbortSignal) => Promise<T>): Promise<T> {
  const signal = AbortSignal.timeout(timeoutMs);
  return new Promise<T>((resolve, reject) => {
    const abort = () => reject(signal.reason);
    signal.addEventListener("abort", abort, { once: true });
    work(signal)
      .then(resolve, reject)
      .finally(() => signal.removeEventListener("abort", abort));
  });
}

export function createRelay(dependencies: RelayDependencies) {
  return async (request: RelayRequest): Promise<RelayResponse> => {
    if (request.method === "GET" && request.path === "/health") return json(200, { ok: true });
    if (request.method !== "POST" || request.path !== "/v1/jev") return json(404, { error: "not_found" });
    if (!validDecision(request.body)) return json(400, { error: "invalid_request" });

    const signedTransaction = request.headers["x-interlinked-app-transaction"];
    if (!signedTransaction) return json(401, { error: "missing_app_transaction" });

    let user: string;
    try { user = await dependencies.verifyAppTransaction(signedTransaction); }
    catch { return json(401, { error: "invalid_app_transaction" }); }

    const now = dependencies.now();
    const day = new Date(now).toISOString().slice(0, 10);
    if (!await dependencies.cache.consume(user, day, 250)) {
      return json(429, { error: "daily_limit" }, { "retry-after": "3600" });
    }

    const key = createHash("sha256").update(request.body).digest("hex");
    const cached = await dependencies.cache.get(key, now);
    if (cached !== undefined) return json(200, cached, { "x-interlinked-cache": "hit" });

    let upstream: { status: number; body: Uint8Array };
    try {
      upstream = await withDeadline(
        dependencies.upstreamTimeoutMs ?? upstreamTimeoutMs,
        signal => dependencies.callOpenRouter(request.body, signal)
      );
    } catch {
      // A timeout or network failure is an unavailable upstream, not a bad request.
      upstream = { status: 503, body: new Uint8Array() };
    }
    if (upstream.status !== 200) {
      const status = upstream.status === 413 || upstream.status === 429 ? upstream.status : 503;
      return json(status, { error: status === 429 ? "rate_limited" : status === 413 ? "too_large" : "unavailable" });
    }

    let response: unknown;
    try { response = JSON.parse(new TextDecoder().decode(upstream.body)); }
    catch { return json(502, { error: "invalid_upstream_response" }); }
    await dependencies.cache.put(key, response, now + cacheLifetimeMs);
    return json(200, response, { "x-interlinked-cache": "miss" });
  };
}
