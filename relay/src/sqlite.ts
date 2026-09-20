import { createHash } from "node:crypto";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { CacheStore } from "./app.js";

export class SQLiteCache implements CacheStore {
  private readonly db: DatabaseSync;

  constructor(path = process.env.INTERLINKED_RELAY_DB ?? "/data/interlinked-relay.sqlite") {
    mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA busy_timeout = 5000;
      CREATE TABLE IF NOT EXISTS jev_cache (
        key TEXT PRIMARY KEY,
        response TEXT NOT NULL,
        expires_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS jev_cache_expiry ON jev_cache(expires_at);
      CREATE TABLE IF NOT EXISTS jev_rate (
        user_day TEXT PRIMARY KEY,
        count INTEGER NOT NULL,
        day TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS jev_rate_day ON jev_rate(day);
    `);
  }

  async get(key: string, now: number): Promise<unknown | undefined> {
    this.db.prepare("DELETE FROM jev_cache WHERE expires_at <= ?").run(now);
    const row = this.db.prepare(
      "SELECT response FROM jev_cache WHERE key = ? AND expires_at > ?"
    ).get(key, now) as { response: string } | undefined;
    if (!row) return undefined;
    try { return JSON.parse(row.response); }
    catch {
      this.db.prepare("DELETE FROM jev_cache WHERE key = ?").run(key);
      return undefined;
    }
  }

  async put(key: string, response: unknown, expiresAt: number): Promise<void> {
    this.db.prepare(
      `INSERT INTO jev_cache (key, response, expires_at) VALUES (?, ?, ?)
       ON CONFLICT(key) DO UPDATE SET response = excluded.response, expires_at = excluded.expires_at`
    ).run(key, JSON.stringify(response), expiresAt);
  }

  async consume(user: string, day: string, limit: number): Promise<boolean> {
    const userHash = createHash("sha256").update(user).digest("hex");
    const userDay = `${userHash}-${day}`;
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const row = this.db.prepare("SELECT count FROM jev_rate WHERE user_day = ?").get(userDay) as
        { count: number } | undefined;
      if ((row?.count ?? 0) >= limit) {
        this.db.exec("ROLLBACK");
        return false;
      }
      this.db.prepare(
        `INSERT INTO jev_rate (user_day, count, day) VALUES (?, 1, ?)
         ON CONFLICT(user_day) DO UPDATE SET count = count + 1`
      ).run(userDay, day);
      this.db.prepare("DELETE FROM jev_rate WHERE day < ?").run(day);
      this.db.exec("COMMIT");
      return true;
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }
}
