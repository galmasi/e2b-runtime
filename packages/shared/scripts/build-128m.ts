import { Template } from "e2b";
import { template } from "./template.js";

async function main() {
  const useCache = process.env.USE_CACHE === 'true';

  console.log(`cache = ${useCache ? 'enabled' : 'disabled'}`);

  await Template.build(template, {
    alias: "base-128m",
    memoryMB: 128,
    skipCache: !useCache,
    onBuildLogs: (it) => console.log(it.toString()),
  });
}

main().catch((err) => console.error(err));
