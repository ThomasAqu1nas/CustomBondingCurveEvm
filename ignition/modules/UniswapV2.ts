import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("UniswapV2", (moduleBuilder) => {
  const feeToSetter = moduleBuilder.getAccount(0);
  const factory = moduleBuilder.contract("UniswapV2Factory", [feeToSetter]);

  const router01 = moduleBuilder.contract("UniswapV2Router01", [
    factory,
    "0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701",
  ]);
  const router02 = moduleBuilder.contract("UniswapV2Router02", [
    factory,
    "0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701",
  ]);

  return {
    factory,
    router01,
    router02,
  };
});
