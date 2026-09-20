import { createHash } from "node:crypto";

export const cacheLifetimeMs = 5 * 24 * 60 * 60 * 1000;
const maxBodyBytes = 2_000_000;
const maxQuestions = 1_000;

export interface CacheStore {
  get(key: string, now: number): Promise<unknown | undefined>;
  put(key: string, response: unknown, expiresAt: number): Promise<void>;
  consume(user: string, day: string, limit: number): Promise<boolean>;
}

export interface RelayDependencies {
  verifyAppTransaction(jws: string): Promise<string>;
  cache: CacheStore;
  callOpenRouter(body: Uint8Array): Promise<{ status: number; body: Uint8Array }>;
  now(): number;
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

function validDecision(body: Uint8Array): boolean {
  if (body.byteLength === 0 || body.byteLength > maxBodyBytes) return false;
  let value: unknown;
  try { value = JSON.parse(new TextDecoder().decode(body)); } catch { return false; }
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const decision = value as Record<string, unknown>;
  if (decision.model !== "typesafe/jev-1.13" || typeof decision.state !== "string") return false;
  if ((decision.state as string).length > 1_500_000) return false;
  const provider = decision.provider as Record<string, unknown> | undefined;
  if (!provider || provider.data_collection !== "deny") return false;
  const questions = decision.questions;
  if (!questions || typeof questions !== "object" || Array.isArray(questions)) return false;
  const entries = Object.values(questions as Record<string, unknown>);
  if (entries.length === 0 || entries.length > maxQuestions) return false;
  return entries.every(question => {
    if (!question || typeof question !== "object" || Array.isArray(question)) return false;
    const q = question as Record<string, unknown>;
    if (!["choice", "noul", "score"].includes(String(q.type))) return false;
    if (typeof q.instructions !== "string" || q.instructions.length > 8_000) return false;
    return q.criteria !== null && typeof q.criteria === "object";
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

    const upstream = await dependencies.callOpenRouter(request.body);
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
