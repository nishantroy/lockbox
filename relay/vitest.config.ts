import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    testTimeout: 20_000,
    hookTimeout: 30_000,
    // The Postgres-backed reducer/race tests share one database; running
    // them serially avoids cross-test interference on the same connection
    // pool and keeps failure output attributable to one scenario at a time.
    fileParallelism: false
  }
});
