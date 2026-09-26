import { migrate, closePool } from "../src/db.js";

async function main() {
  await migrate();
  console.log("migrations applied");
}

main()
  .catch((error) => {
    console.error("migration failed:", error instanceof Error ? error.message : error);
    process.exitCode = 1;
  })
  .finally(() => closePool());
