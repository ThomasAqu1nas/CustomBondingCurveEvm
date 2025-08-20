import { network } from "hardhat";
import {
  NetworkConnection,
  NetworkConnectionParams,
} from "hardhat/types/network";
export default async function connect(
  params: NetworkConnectionParams,
): Promise<NetworkConnection> {
  return network.connect(params);
}
