// Postgres access for APNs device tokens (migrations/006_push_tokens.sql).
// A token is a delivery address only; nothing here is ever logged.

import type pg from "pg";
import { withTransaction } from "./db.js";

export const MAX_PUSH_TOKENS_PER_IDENTITY = 5;
export const PUSH_TOKEN_RETENTION_SECONDS = 90 * 86_400;

export type PushEnvironment = "sandbox" | "production";

export interface PushTokenRow {
  identityID: string;
  token: string;
  environment: PushEnvironment;
}

/** Inserts or refreshes `(identity, token)`, then deletes the oldest rows beyond the per-identity cap. */
export async function upsertPushToken(pool: pg.Pool, identityID: string, token: string, environment: PushEnvironment, nowSeconds: number): Promise<void> {
  await withTransaction(pool, async (client) => {
    await client.query(
      `INSERT INTO companion_push_token (identity_id, token, environment, updated_at) VALUES ($1, $2, $3, $4)
       ON CONFLICT (identity_id, token) DO UPDATE SET environment = EXCLUDED.environment, updated_at = EXCLUDED.updated_at`,
      [identityID, token, environment, Math.floor(nowSeconds)]
    );
    // Newest first; on an updated_at tie the just-written token wins.
    await client.query(
      `DELETE FROM companion_push_token WHERE identity_id = $1 AND token NOT IN (
         SELECT token FROM companion_push_token WHERE identity_id = $1 ORDER BY updated_at DESC, (token = $2) DESC, token LIMIT $3
       )`,
      [identityID, token, MAX_PUSH_TOKENS_PER_IDENTITY]
    );
  });
}

/** Unregister: removes every token this identity registered on `environment`. */
export async function deletePushTokensForEnvironment(pool: pg.Pool, identityID: string, environment: PushEnvironment): Promise<void> {
  await pool.query(`DELETE FROM companion_push_token WHERE identity_id = $1 AND environment = $2`, [identityID, environment]);
}

export async function pushTokensForIdentities(pool: pg.Pool, identityIDs: readonly string[]): Promise<PushTokenRow[]> {
  if (identityIDs.length === 0) return [];
  const result = await pool.query<{ identity_id: string; token: string; environment: PushEnvironment }>(
    `SELECT identity_id, token, environment FROM companion_push_token WHERE identity_id = ANY($1::text[])`,
    [identityIDs]
  );
  return result.rows.map((r) => ({ identityID: r.identity_id, token: r.token, environment: r.environment }));
}

export async function deletePushToken(pool: pg.Pool, identityID: string, token: string): Promise<void> {
  await pool.query(`DELETE FROM companion_push_token WHERE identity_id = $1 AND token = $2`, [identityID, token]);
}

export async function purgeStalePushTokens(pool: pg.Pool, nowSeconds: number): Promise<number> {
  const result = await pool.query(`DELETE FROM companion_push_token WHERE updated_at < $1`, [Math.floor(nowSeconds - PUSH_TOKEN_RETENTION_SECONDS)]);
  return result.rowCount ?? 0;
}
