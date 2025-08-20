import { AddressLike, ethers, Provider } from "ethers";
import { configVariable } from "hardhat/config";
import { NetworkConnection } from "hardhat/types/network";
import * as dotenv from "dotenv";
dotenv.config();
export default async function impersonate(connection: NetworkConnection) {
  let defaultAddress = new ethers.Wallet(
    process.env.DEFAULT_PRIVATE_KEY as string,
  ).address;
  await connection.provider.request({
    method: "hardhat_impersonateAccount",
    params: [defaultAddress],
  });

  await connection.provider.request({
    method: "hardhat_setBalance",
    params: [
      defaultAddress,
      "0x3635C9ADC5DEA00000", // 1000 ETH в hex wei
    ],
  });
}
