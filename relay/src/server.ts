import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { Environment, SignedDataVerifier } from "@apple/app-store-server-library";
import { createRelay } from "./app.js";
import { SQLiteCache } from "./sqlite.js";

const bundleId = "computer.interlinked";
const appAppleId = 6814002217;
const rootCertificateURLs = [
  "https://www.apple.com/appleca/AppleIncRootCertificate.cer",
  "https://www.apple.com/certificateauthority/AppleRootCA-G2.cer",
  "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer"
];

async function loadAppleRoots(): Promise<Buffer[]> {
  return Promise.all(rootCertificateURLs.map(async url => {
    const response = await fetch(url);
    if (!response.ok) throw new Error("Apple root certificate unavailable");
    return Buffer.from(await response.arrayBuffer());
  }));
}

const openRouterKey = process.env.OPENROUTER_API_KEY;
if (!openRouterKey) throw new Error("OPENROUTER_API_KEY is required");

const roots = await loadAppleRoots();
const sandboxVerifier = new SignedDataVerifier(roots, true, Environment.SANDBOX, bundleId);
const productionVerifier = new SignedDataVerifier(roots, true, Environment.PRODUCTION, bundleId, appAppleId);
const relay = createRelay({
  cache: new SQLiteCache(),
  now: Date.now,
  async verifyAppTransaction(jws) {
    let transaction;
    try { transaction = await sandboxVerifier.verifyAndDecodeAppTransaction(jws); }
    catch { transaction = await productionVerifier.verifyAndDecodeAppTransaction(jws); }
    const identifier = transaction.appTransactionId;
    if (!identifier) throw new Error("App transaction has no identifier");
    return identifier;
  },
  async callOpenRouter(body, signal) {
    const response = await fetch("https://openrouter.ai/api/alpha/decisions", {
      method: "POST",
      headers: {
        authorization: `Bearer ${openRouterKey}`,
        "content-type": "application/json",
        "x-title": "Interlinked"
      },
      body: Buffer.from(body),
      signal
    });
    return { status: response.status, body: new Uint8Array(await response.arrayBuffer()) };
  }
});

const port = Number(process.env.PORT ?? 8080);
createServer(async (request, response) => {
  try {
    await handle(request, response);
  } catch {
    // A malformed URL, aborted upload, or upstream failure must not end the process.
    if (!response.headersSent) response.writeHead(400, { "content-type": "application/json" });
    response.end('{"error":"bad_request"}');
  }
}).listen(port);

async function handle(request: IncomingMessage, response: ServerResponse) {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const bytes = Buffer.from(chunk);
    size += bytes.length;
    if (size > 2_000_000) {
      response.writeHead(413, { "content-type": "application/json" });
      response.end('{"error":"too_large"}');
      return;
    }
    chunks.push(bytes);
  }
  const result = await relay({
    method: request.method ?? "GET",
    path: new URL(request.url ?? "/", "http://localhost").pathname,
    headers: { "x-interlinked-app-transaction": request.headers["x-interlinked-app-transaction"] as string | undefined },
    body: Buffer.concat(chunks)
  });
  response.writeHead(result.status, result.headers);
  response.end(result.body);
}
