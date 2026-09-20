import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { SQLiteCache } from "./sqlite.js";

test("SQLite cache persists decisions and expires them", async () => {
  const directory = mkdtempSync(join(tmpdir(), "interlinked-relay-"));
  try {
    const path = join(directory, "relay.sqlite");
    const first = new SQLiteCache(path);
    await first.put("request", { answer: "cached" }, 2_000);
    const reopened = new SQLiteCache(path);
    assert.deepEqual(await reopened.get("request", 1_000), { answer: "cached" });
    assert.equal(await reopened.get("request", 2_001), undefined);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("SQLite rate limits each signed app transaction independently", async () => {
  const directory = mkdtempSync(join(tmpdir(), "interlinked-relay-"));
  try {
    const cache = new SQLiteCache(join(directory, "relay.sqlite"));
    assert.equal(await cache.consume("tester-a", "2026-09-19", 2), true);
    assert.equal(await cache.consume("tester-a", "2026-09-19", 2), true);
    assert.equal(await cache.consume("tester-a", "2026-09-19", 2), false);
    assert.equal(await cache.consume("tester-b", "2026-09-19", 2), true);
    assert.equal(await cache.consume("tester-a", "2026-09-20", 2), true);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
