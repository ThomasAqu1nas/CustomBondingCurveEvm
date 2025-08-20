import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("UniswapV2", (moduleBuilder) => {
  //router: 0xb3b2467E615abD0B204952c200BC139645514361
  const smthTokenFactory = moduleBuilder.contract("SmthTokenFactory", [
    "0xb3b2467E615abD0B204952c200BC139645514361",
    "0xea108037a703ADA6De08DA6d5f729124b2FEf7F8",
  ]);

  return {
    smthTokenFactory,
  };
});
