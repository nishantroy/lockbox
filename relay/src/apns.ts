// APNs wake-up sender (docs/r5-apns-plan.md). Push is a wake-up, never state or
// a credential: the payload is an alert, a sound, a thread id and a top-level
// `kind`. Delivery failure never changes an operation's outcome; every error is
// swallowed and only counted. Nothing sensitive is ever logged: no device
// tokens, JWTs, key material or signatures -- only aggregate counts.

import { createPrivateKey, createSign, type KeyObject } from "node:crypto";
import { connect, constants as http2Constants, type ClientHttp2Session } from "node:http2";
import type pg from "pg";
import { deletePushToken, pushTokensForIdentities, type PushEnvironment } from "./push-store.js";

export type PushKind = "request" | "answer" | "joined";

export interface PushMessage {
  title: string;
  body: string;
  kind: PushKind;
}

/** One banner for every device registered under `identityID`. */
export interface PushNotification {
  identityID: string;
  message: PushMessage;
}

export interface PushTarget {
  token: string;
  environment: PushEnvironment;
}

export type PushResult = "sent" | "failed" | "invalid_token";

/** Seam for tests: inject a fake with `setPushSenderForTesting`. */
export interface PushSender {
  send(target: PushTarget, message: PushMessage): Promise<PushResult>;
  /** Called after each dispatch (including after a timeout) to release connections. */
  close?(): void;
}

export const PUSH_TOTAL_TIMEOUT_MS = 3_000;
const JWT_REFRESH_SECONDS = 50 * 60;
const DEFAULT_TOPIC = "com.phone-lockbox.app";
const FALLBACK_TITLE = "Phone Lockbox";

export interface ApnsConfig {
  keyP8: string;
  keyID: string;
  teamID: string;
  topic: string;
}

/** Returns the APNs configuration, or null (push disabled) unless `APNS_KEY_P8`, `APNS_KEY_ID` and `APNS_TEAM_ID` are all set. */
export function apnsConfigFromEnv(env: NodeJS.ProcessEnv = process.env): ApnsConfig | null {
  const keyP8 = env.APNS_KEY_P8?.trim();
  const keyID = env.APNS_KEY_ID?.trim();
  const teamID = env.APNS_TEAM_ID?.trim();
  if (!keyP8 || !keyID || !teamID) return null;
  return { keyP8: keyP8.includes("\\n") ? keyP8.replace(/\\n/g, "\n") : keyP8, keyID, teamID, topic: env.APNS_TOPIC?.trim() || DEFAULT_TOPIC };
}

function base64urlJSON(value: object): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

/** ES256 provider token: header `{alg, kid}`, claims `{iss, iat}`; the signature is raw r||s (JWS), not DER. */
export function buildApnsJWT(config: Pick<ApnsConfig, "keyP8" | "keyID" | "teamID">, nowSeconds: number, key: KeyObject = createPrivateKey(config.keyP8)): string {
  const signingInput = `${base64urlJSON({ alg: "ES256", kid: config.keyID })}.${base64urlJSON({ iss: config.teamID, iat: Math.floor(nowSeconds) })}`;
  const signature = createSign("SHA256").update(signingInput).sign({ key, dsaEncoding: "ieee-p1363" });
  return `${signingInput}.${signature.toString("base64url")}`;
}

let cachedJWT: { token: string; issuedAt: number; fingerprint: string } | null = null;

/** Module-scoped cache: reused until it is 50 minutes old (APNs rejects tokens older than 60). */
export function cachedApnsJWT(config: ApnsConfig, nowSeconds: number = Date.now() / 1000): string {
  const fingerprint = `${config.keyID}.${config.teamID}.${config.keyP8.length}`;
  if (cachedJWT && cachedJWT.fingerprint === fingerprint && nowSeconds - cachedJWT.issuedAt < JWT_REFRESH_SECONDS && nowSeconds >= cachedJWT.issuedAt) return cachedJWT.token;
  const token = buildApnsJWT(config, nowSeconds);
  cachedJWT = { token, issuedAt: nowSeconds, fingerprint };
  return token;
}

export function resetApnsJWTCacheForTesting(): void {
  cachedJWT = null;
}

/** The exact APNs JSON body. Keys are fixed: alert, sound, thread-id, kind. No identifiers or secrets. */
export function buildPushPayload(message: PushMessage): { aps: { alert: { title: string; body: string }; sound: string; "thread-id": string }; kind: PushKind } {
  return {
    aps: { alert: { title: message.title.trim() === "" ? FALLBACK_TITLE : message.title, body: message.body }, sound: "default", "thread-id": "companion" },
    kind: message.kind
  };
}

const APNS_HOSTS: Record<PushEnvironment, string> = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com"
};

export class ApnsSender implements PushSender {
  private sessions = new Map<PushEnvironment, ClientHttp2Session>();

  /** `hosts` overrides the APNs origins (tests point it at a local HTTP/2 server). */
  constructor(private readonly config: ApnsConfig, private readonly hosts: Record<PushEnvironment, string> = APNS_HOSTS) {}

  private session(environment: PushEnvironment): ClientHttp2Session {
    const existing = this.sessions.get(environment);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const created = connect(this.hosts[environment]);
    created.on("error", () => undefined); // surfaced per-request as a failed send
    this.sessions.set(environment, created);
    return created;
  }

  send(target: PushTarget, message: PushMessage): Promise<PushResult> {
    return new Promise<PushResult>((resolve) => {
      let settled = false;
      const finish = (result: PushResult) => {
        if (settled) return;
        settled = true;
        resolve(result);
      };
      try {
        const jwt = cachedApnsJWT(this.config);
        const request = this.session(target.environment).request({
          [http2Constants.HTTP2_HEADER_METHOD]: "POST",
          [http2Constants.HTTP2_HEADER_PATH]: `/3/device/${target.token}`,
          authorization: `bearer ${jwt}`,
          "apns-topic": this.config.topic,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600)
        });
        let status = 0;
        const chunks: Buffer[] = [];
        request.on("response", (headers) => {
          status = Number(headers[http2Constants.HTTP2_HEADER_STATUS] ?? 0);
        });
        request.on("data", (chunk: Buffer) => chunks.push(chunk));
        request.on("error", () => finish("failed"));
        // A stream closed without `end`/`error` must not wait for the 3 s budget.
        request.on("close", () => finish(status === 200 ? "sent" : "failed"));
        request.on("end", () => {
          if (status === 403) cachedJWT = null; // Expired/InvalidProviderToken: re-sign on the next dispatch.
          if (status === 200) return finish("sent");
          if (status === 410) return finish("invalid_token");
          if (status === 400) {
            let reason = "";
            try {
              reason = String((JSON.parse(Buffer.concat(chunks).toString("utf8")) as { reason?: unknown }).reason ?? "");
            } catch {
              reason = "";
            }
            return finish(reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic" ? "invalid_token" : "failed");
          }
          finish("failed");
        });
        request.end(JSON.stringify(buildPushPayload(message)));
      } catch {
        finish("failed");
      }
    });
  }

  close(): void {
    for (const session of this.sessions.values()) {
      try {
        session.destroy();
      } catch {
        // already gone
      }
    }
    this.sessions.clear();
  }
}

let senderOverride: PushSender | null | undefined;

/** Tests inject a fake sender (or `null` to force "disabled"); `undefined` restores env-based selection. */
export function setPushSenderForTesting(sender: PushSender | null | undefined): void {
  senderOverride = sender;
}

let timeoutOverrideMs: number | undefined;

/** Tests shorten the 3 s budget; `undefined` restores it. */
export function setPushTimeoutForTesting(ms: number | undefined): void {
  timeoutOverrideMs = ms;
}

function currentSender(): PushSender | null {
  if (senderOverride !== undefined) return senderOverride;
  const config = apnsConfigFromEnv();
  return config ? new ApnsSender(config) : null;
}

export interface PushSummary {
  sent: number;
  failed: number;
  pruned: number;
}

/**
 * Sends every notification to the devices registered for its identity, with a
 * hard total budget (token read + sends). Never throws and never rejects:
 * errors and timeouts only count as failures. Invalid tokens are pruned.
 */
export async function dispatchPush(pool: pg.Pool, notifications: readonly PushNotification[], timeoutMs: number = timeoutOverrideMs ?? PUSH_TOTAL_TIMEOUT_MS): Promise<PushSummary> {
  const summary: PushSummary = { sent: 0, failed: 0, pruned: 0 };
  if (notifications.length === 0) return summary;
  let sender: PushSender | null = null;
  try {
    sender = currentSender();
    if (!sender) return summary;
    const active = sender;
    let timer: NodeJS.Timeout | undefined;
    const budget = new Promise<"timeout">((resolve) => {
      timer = setTimeout(() => resolve("timeout"), timeoutMs);
    });
    const work = (async () => {
      const rows = await pushTokensForIdentities(pool, [...new Set(notifications.map((n) => n.identityID))]);
      const sends: Promise<void>[] = [];
      for (const notification of notifications) {
        for (const row of rows) {
          if (row.identityID !== notification.identityID) continue;
          sends.push(
            (async () => {
              let result: PushResult;
              try {
                result = await active.send({ token: row.token, environment: row.environment }, notification.message);
              } catch {
                result = "failed";
              }
              if (result === "sent") summary.sent += 1;
              else if (result === "invalid_token") {
                await deletePushToken(pool, row.identityID, row.token).catch(() => undefined);
                summary.pruned += 1;
              } else summary.failed += 1;
            })()
          );
        }
      }
      await Promise.allSettled(sends);
    })();
    const outcome = await Promise.race([work.then(() => "done" as const).catch(() => "done" as const), budget]);
    if (timer) clearTimeout(timer);
    if (outcome === "timeout") summary.failed += 1;
  } catch {
    summary.failed += 1;
  } finally {
    try {
      sender?.close?.();
    } catch {
      // ignore
    }
  }
  if (summary.sent + summary.failed + summary.pruned > 0) console.log(`apns: sent ${summary.sent}, failed ${summary.failed}, pruned ${summary.pruned}`);
  return summary;
}
