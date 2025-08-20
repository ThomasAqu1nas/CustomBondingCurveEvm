import { network } from "hardhat";
import connect from "./connectNetwork.js";
import impersonate from "./networkImpersonate.js";

async function setupAccount(): Promise<void> {
  const connection = await connect({ network: "hardhatFork" });
  return impersonate(connection);
}

setupAccount()
  .then(process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
