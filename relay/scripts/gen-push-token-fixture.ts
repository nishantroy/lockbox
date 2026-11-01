// Regenerates test/fixtures/push-token-op.json: a deterministic (fixed Ed25519
// seed, fixed timestamp) signed `push_token` operation whose body bytes follow
// the Swift `JSONEncoder` `.sortedKeys` layout the app will produce for
// `PushTokenRegistration`. NOT Swift-produced: hand-built with this relay's
// canonical encoder (CompanionVectorGen lives outside relay/). The Swift
// builder should reproduce `bodyJSON` byte-for-byte and verify `signature`.
//
//   npx tsx scripts/gen-push-token-fixture.ts > test/fixtures/push-token-op.json

import { publicKeyFromSeed, sign } from "../src/crypto.js";
import { deviceIdentityID, canonicalBytes, base64url, digest, COMPANION_VERSION, secondsToSwiftDate } from "../src/canonical.js";

const seed = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 1));
const publicKey = publicKeyFromSeed(seed);
const identityID = deviceIdentityID(publicKey);
const issuedAtUnix = 1_793_491_200; // 2026-11-01T00:00:00Z
const token = "0123456789abcdef".repeat(4);
const bodyJSON = `{"environment":"sandbox","identityID":"${identityID}","issuedAt":${secondsToSwiftDate(issuedAtUnix)},"token":"${token}"}`;
const body = Buffer.from(bodyJSON, "utf8");
const operationID = base64url(digest(canonicalBytes(`${COMPANION_VERSION}.operation-id`, ["push_token", identityID, base64url(digest(body))]))).slice(0, 32);
const fields = [operationID, "none", "push_token", identityID, base64url(publicKey), base64url(digest(body))];
const signature = sign(canonicalBytes(`${COMPANION_VERSION}.operation`, fields), seed, publicKey);

console.log(
  JSON.stringify(
    {
      note: "Hand-built with the relay's canonical encoder, not Swift-produced. See scripts/gen-push-token-fixture.ts.",
      issuedAtUnix,
      bodyJSON,
      operation: {
        operationID,
        kind: "push_token",
        signer: { identityID, role: "trustedApprover", publicKey: publicKey.toString("base64") },
        body: body.toString("base64"),
        signature: signature.toString("base64")
      }
    },
    null,
    2
  )
);
