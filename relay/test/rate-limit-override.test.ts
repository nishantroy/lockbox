import { describe, it, expect } from "vitest";
import { rateLimitMax, GLOBAL_RATE_LIMIT_MAX } from "../src/db.js";

describe("rate limit override (local testing only)", () => {
  it("defaults when unset", () => {
    expect(rateLimitMax(60, "X", {})).toBe(60);
    expect(GLOBAL_RATE_LIMIT_MAX).toBe(60);
  });

  it("is honoured outside production", () => {
    expect(rateLimitMax(60, "X", { X: "100000", RELAY_LOCAL_DEV: "1" })).toBe(100000);
    expect(rateLimitMax(60, "X", { X: "5", NODE_ENV: "development", RELAY_LOCAL_DEV: "1" })).toBe(5);
  });

  it("is ignored without the positive local opt-in that only the dev server sets", () => {
    expect(rateLimitMax(60, "X", { X: "100000" })).toBe(60);
    expect(rateLimitMax(60, "X", { X: "100000", RELAY_LOCAL_DEV: "0" })).toBe(60);
  });

  it("fails closed in production or on Vercel, and on invalid values", () => {
    expect(rateLimitMax(60, "X", { X: "100000", VERCEL_ENV: "production", RELAY_LOCAL_DEV: "1" })).toBe(60);
    expect(rateLimitMax(60, "X", { X: "100000", NODE_ENV: "production", RELAY_LOCAL_DEV: "1" })).toBe(60);
    expect(rateLimitMax(60, "X", { X: "100000", VERCEL: "1", VERCEL_ENV: "preview", RELAY_LOCAL_DEV: "1" })).toBe(60);
    for (const bad of ["abc", "0", "-3", "1.5"]) expect(rateLimitMax(60, "X", { X: bad, RELAY_LOCAL_DEV: "1" })).toBe(60);
  });
});
