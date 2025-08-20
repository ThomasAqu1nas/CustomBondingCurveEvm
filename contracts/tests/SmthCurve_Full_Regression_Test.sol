// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SmthTokenFactory} from "../src/core/SmthTokenFactory.sol";
import {ISmthTokenFactory} from "../src/interfaces/ISmthTokenFactory.sol";
import {IUniswapV2Factory} from "../src/uniswap-v2/core/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "../src/uniswap-v2/periphery/interfaces/IUniswapV2Router02.sol";

// minimal
interface IUniswapV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}
/// MONAD FORK
contract SmthCurve_Full_Regression_Test is Test {
    // Mainnet WETH (для addLiquidityETH)
    address constant WETH = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;

    // Акторы
    address owner   = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    address buyer1  = address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
    address buyer2  = address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC);
    address feeSink = address(0x90F79bf6EB2c4f870365E785982E1f101E93b906);

    SmthTokenFactory factory;
    address uniFactory = 0x733E88f248b742db6C14C0b1713Af5AD7fDd59D0;
    address uniRouter = 0xfB8e1C3b833f9E67a71C859a132cf783b645e436;

    uint256 constant TRADE_FEE_BPS = 100;      // 1%
    uint256 constant BPS_DEN       = 10_000;
    uint256 constant MIG_WAD       = 62_500_000_000_000_000; // 0.0625e18

    function setUp() external {
        require(uniRouter.code.length > 0, "Router: no code at address");
        require(uniFactory.code.length > 0, "Factory: no code at address");
        address wethFromRouter = IUniswapV2Router02(uniRouter).WETH();
        require(wethFromRouter == WETH, "Router.WETH mismatch");
        // Балансы
        vm.prank(owner);
        factory = new SmthTokenFactory(address(uniRouter), address(uniFactory));

        assertEq(factory.uniswapRouter(), address(uniRouter));
        assertEq(factory.WETH(), WETH);
    }

    // ---------- helpers (повторяют контрактную математику) ----------
    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _netFromGross(uint256 gross) internal pure returns (uint256) {
        return (gross * (BPS_DEN - TRADE_FEE_BPS)) / BPS_DEN;
    }

    function _grossFromNetCeil(uint256 net) internal pure returns (uint256) {
        return _ceilDiv(net * BPS_DEN, (BPS_DEN - TRADE_FEE_BPS));
    }

    function _fullFillOutcome(uint256 vS, uint256 vT, uint256 ethNet)
        internal pure returns (uint256 newS, uint256 newT, uint256 outAmt)
    {
        newS = vS + ethNet;
        newT = (vS * vT) / newS;
        outAmt = vT - newT;
    }

    function _mulWadDown(uint256 a, uint256 wad) internal pure returns (uint256) {
        return (a * wad) / 1e18;
    }

    function _pairReserves(address token) internal view returns (uint256 weth, uint256 other) {
        address pair = IUniswapV2Factory(uniFactory).getPair(WETH, token);
        assertTrue(pair != address(0), "pair not created");
        (uint112 r0, uint112 r1, ) = IUniswapV2Pair(pair).getReserves();
        address t0 = IUniswapV2Pair(pair).token0();
        if (t0 == WETH) {
            weth  = uint256(r0);
            other = uint256(r1);
        } else {
            weth  = uint256(r1);
            other = uint256(r0);
        }
    }

    // ---------- Тесты ----------

    function test_Launch_SetsInitialState_And_FactoryHoldsSupply() external {
        vm.startPrank(owner);
        uint256 initialAmmEthAmount = 5 ether;
        uint256 initialRatioBps     = 1000; // 10%
        address token = factory.launchToken("Test", "TT", "uri", initialAmmEthAmount, initialRatioBps);
        vm.stopPrank();

        ISmthTokenFactory.TokenInfo memory info = factory.tokenInfo(token);
        uint256 curveReserve = info.tokenTotalSupply - (info.tokenTotalSupply * initialRatioBps) / BPS_DEN;

        // Базовая инвариантность
        assertEq(info.rEthReserves, 0);
        assertEq(info.rTokenReserves, curveReserve);
        assertEq(info.ammTokenReserves, (info.tokenTotalSupply * initialRatioBps) / BPS_DEN);

        // ✅ ключевое свойство: initialAmmEthAmount соответствует GROSS, нужному чтобы обнулить R
        uint256 newT   = info.vTokenReserves - info.rTokenReserves;                // vT - R
        uint256 newS   = _ceilDiv(info.vEthReserves * info.vTokenReserves, newT);  // ceil((vS*vT)/newT)
        uint256 netAll = newS - info.vEthReserves;
        uint256 grossAll = _grossFromNetCeil(netAll);

        // строгое равенство gross → initialAmmEthAmount (ceil уже учтён)
        assertApproxEqAbs(initialAmmEthAmount, grossAll, 10, "initialAmmEthAmount must equal grossAll");

        // дополнительная проверка: net(gross) ≈ netAll
        assertApproxEqAbs(_netFromGross(initialAmmEthAmount), netAll, 10); // допуск 10 wei
    }

    function test_Launch_WithImmediateBuy_AutoMigratesWhenInventoryZero() external {
        vm.startPrank(owner);
        address token = factory.launchToken{value: 10_000 ether}("LB", "LB", "uri", 1 ether, 1000);
        vm.stopPrank();

        ISmthTokenFactory.TokenInfo memory info = factory.tokenInfo(token);
        assertTrue(info.isCompleted);
        (uint256 wethReserve, uint256 tokReserve) = _pairReserves(token);
        assertGt(wethReserve, 0);
        assertGt(tokReserve, 0);
    }

    function _allRemainingOutcome(ISmthTokenFactory.TokenInfo memory B)
    internal
    pure
    returns (uint256 grossAll, uint256 netAll, uint256 newSstar, uint256 newTstar)
    {
        uint256 newT = B.vTokenReserves - B.rTokenReserves;                      // vT - R
        uint256 newS = _ceilDiv(B.vEthReserves * B.vTokenReserves, newT);        // ceil((vS*vT)/newT)
        uint256 net  = newS - B.vEthReserves;                                    // netAll
        uint256 gross= _grossFromNetCeil(net);                                   // grossAll
        return (gross, net, newS, newT);
    }

    function test_Buy_FullFill_UpdatesReservesAndFeeAndTransfers() external {
        vm.startPrank(owner);
        address token = factory.launchToken("T", "T", "u", 3 ether, 1000);
        vm.stopPrank();

        ISmthTokenFactory.TokenInfo memory B = factory.tokenInfo(token);
        (uint256 grossAll,,,) = _allRemainingOutcome(B);

        uint256 valueWei = grossAll - 1; // гарантированно full-fill

        vm.expectEmit(true, true, false, false, address(factory));
        emit ISmthTokenFactory.SmthTokenFactory__TokensPurchased(token, buyer1, 0, 0, 0, 0, 0, 0);

        vm.prank(buyer1);
        factory.buyToken{value: valueWei}(token);

        ISmthTokenFactory.TokenInfo memory A = factory.tokenInfo(token);

        uint256 net = _netFromGross(valueWei); // net ровно от valueWei
        (uint256 newS, uint256 newT, uint256 outAmt) =
            _fullFillOutcome(B.vEthReserves, B.vTokenReserves, net);

        assertEq(A.vEthReserves, newS);
        assertEq(A.vTokenReserves, newT);
        assertEq(IERC20(token).balanceOf(buyer1), outAmt);
        assertEq(A.rEthReserves, B.rEthReserves + net);
        assertEq(B.rTokenReserves - A.rTokenReserves, outAmt);

        // Комиссия на весь msg.value (full-fill)
        assertEq(factory.totalFee(), valueWei - net);
    }

    function test_Buy_PartialFill_Refund_AutoMigrate_And_FeeSum() external {
        vm.startPrank(owner);
        address token = factory.launchToken("P", "P", "u", 1 ether, 1500); // 15% AMM
        vm.stopPrank();

        ISmthTokenFactory.TokenInfo memory B = factory.tokenInfo(token);

        uint256 valueWei = 10_000 ether;

        uint256 newT = B.vTokenReserves - B.rTokenReserves;
        uint256 newS = _ceilDiv(B.vEthReserves * B.vTokenReserves, newT);
        uint256 netAll = newS - B.vEthReserves;
        uint256 grossAll = _grossFromNetCeil(netAll);
        uint256 tradeFee = grossAll - netAll;

        uint256 buyerBefore = buyer2.balance;
        vm.prank(buyer2);
        factory.buyToken{value: valueWei}(token);
        uint256 buyerAfter = buyer2.balance;

        assertEq(buyerBefore - buyerAfter, grossAll);

        ISmthTokenFactory.TokenInfo memory A = factory.tokenInfo(token);
        // R обнулился, кривая финализирована
        assertEq(A.rTokenReserves, 0);
        assertTrue(A.isCompleted);

        // Пара/ликвидность
        (uint256 wethReserve, uint256 tokReserve) = _pairReserves(token);
        assertGt(wethReserve, 0);
        assertGt(tokReserve, 0);
        assertLt(A.ammTokenReserves, B.ammTokenReserves);

        // Комиссии: totalFee = tradeFee + migrationFee (последнюю считаем от фактического ethNeeded)
        // ethNeeded_0 = (ammToken * newS)/newT, но может быть масштабирован из-за available=netAll
        uint256 ethNeeded0 = (B.ammTokenReserves * newS) / newT;
        uint256 migFee0    = _mulWadDown(ethNeeded0, MIG_WAD);
        uint256 available  = netAll;
        uint256 ethNeeded  = ethNeeded0;
        uint256 migFee     = migFee0;
        uint256 tokenToLP  = B.ammTokenReserves;
        if (available < ethNeeded0 + migFee0) {
            uint256 maxEthForPool = available > migFee0 ? (available - migFee0) : 0;
            assertGt(maxEthForPool, 0, "expected enough for scaled migration");
            tokenToLP = (tokenToLP * maxEthForPool) / ethNeeded0;
            ethNeeded = maxEthForPool;
            migFee    = _mulWadDown(ethNeeded, MIG_WAD);
        }

        uint256 tf = factory.totalFee();
        assertEq(tf, tradeFee + migFee, "totalFee must be tradeFee+migrationFee");
    }

    function test_Buy_ExactGrossNeededForAllRemaining_NoRefund() external {
        vm.startPrank(owner);
        address token = factory.launchToken("PP", "PP", "uri", 1 ether, 2000);
        vm.stopPrank();

        ISmthTokenFactory.TokenInfo memory B = factory.tokenInfo(token);
        uint256 newT   = B.vTokenReserves - B.rTokenReserves;
        uint256 newS   = _ceilDiv(B.vEthReserves * B.vTokenReserves, newT);
        uint256 netAll = newS - B.vEthReserves;
        uint256 grossAll = _grossFromNetCeil(netAll);

        uint256 before = buyer1.balance;
        vm.prank(buyer1);
        factory.buyToken{value: grossAll}(token);
        uint256 after_ = buyer1.balance;

        // добили R, мигрировали, рефанда нет
        ISmthTokenFactory.TokenInfo memory A = factory.tokenInfo(token);
        assertEq(A.rTokenReserves, 0);
        assertTrue(A.isCompleted);
        assertEq(before - after_, grossAll);
    }

    function test_Buy_AboveThreshold_RefundOneWei() external {
        vm.startPrank(owner);
        address token = factory.launchToken("PX", "PX", "uri", 1 ether, 2000);
        vm.stopPrank();

        ISmthTokenFactory.TokenInfo memory B = factory.tokenInfo(token);
        uint256 grossAll = _grossFromNetCeil(
            _ceilDiv(B.vEthReserves * B.vTokenReserves, (B.vTokenReserves - B.rTokenReserves)) - B.vEthReserves
        );

        uint256 before = buyer1.balance;
        vm.prank(buyer1);
        factory.buyToken{value: grossAll + 1}(token);
        uint256 after_ = buyer1.balance;

        // рефанд ровно 1 wei
        assertEq(before - after_, grossAll);
    }



    function test_FinalPrice_EqualsPoolStartPrice() external {
        vm.startPrank(owner);
        // initialAmmEthAmount_ можно любым (важно лишь, что мы потом добьём R до 0)
        address token = factory.launchToken("P", "P", "u", 1 ether, 1500);
        vm.stopPrank();

        // Снимем состояние ДО миграции — из него считаем newS/newT
        ISmthTokenFactory.TokenInfo memory B = factory.tokenInfo(token);

        uint256 newT = B.vTokenReserves - B.rTokenReserves;                // vT - R
        uint256 newS = _ceilDiv(B.vEthReserves * B.vTokenReserves, newT);  // ceil((vS*vT)/newT)

        // Добиваем rTokenReserves → автопереход + миграция
        vm.prank(buyer2);
        factory.buyToken{value: 10000 ether}(token);

        // Читаем резервы пула
        (uint256 wethReserve, uint256 tokReserve) = _pairReserves(token);
        assertGt(wethReserve, 0);
        assertGt(tokReserve, 0);

        // Сравниваем цены (в WAD), чтобы избежать overflow — берём отношение
        uint256 priceCurveWad = (newS * 1e18) / newT;           // ожидаемая цена S/T
        uint256 pricePoolWad  = (wethReserve * 1e18) / tokReserve;

        // Очень строгий относительный допуск (1e-9)
        // assertApproxEqRel использует масштаб 1e18 для допусka
        assertApproxEqRel(pricePoolWad, priceCurveWad, 1e9);    // 1e9 / 1e18 = 1e-9
    }


    function test_Sell_FullFlow_ReservesFees() external {
        // launch
        vm.startPrank(owner);
        address token = factory.launchToken("S", "S", "u", 2 ether, 1000);
        vm.stopPrank();

        // покупаем чуть-чуть (full-fill), чтобы пополнить rEth и выдать токены
        ISmthTokenFactory.TokenInfo memory B0 = factory.tokenInfo(token);
        (uint256 grossAll,,,) = _allRemainingOutcome(B0);
        uint256 buyValue = grossAll - 1; // гарантированный full-fill
        vm.prank(buyer1);
        factory.buyToken{value: buyValue}(token);

        // продадим часть обратно
        uint256 sellAmt = IERC20(token).balanceOf(buyer1) / 3;
        ISmthTokenFactory.TokenInfo memory B = factory.tokenInfo(token);

        // ожидаемая математика sell:
        // newT = vT + ΔT; newS = ceil((vS*vT)/newT);
        uint256 newT = B.vTokenReserves + sellAmt;
        uint256 newS = _ceilDiv(B.vEthReserves * B.vTokenReserves, newT);
        uint256 grossEthOut = B.vEthReserves - newS;
        uint256 fee = (grossEthOut * TRADE_FEE_BPS) / BPS_DEN;
        uint256 netEthOut = grossEthOut - fee;

        uint256 before = buyer1.balance;
        vm.startPrank(buyer1);
        IERC20(token).approve(address(factory), sellAmt);
        factory.sellToken(token, sellAmt);
        vm.stopPrank();
        uint256 after_ = buyer1.balance;

        ISmthTokenFactory.TokenInfo memory A = factory.tokenInfo(token);

        // резервы по формуле
        assertEq(A.vEthReserves, newS);
        assertEq(A.vTokenReserves, newT);
        assertEq(A.rEthReserves, B.rEthReserves - grossEthOut);
        assertEq(A.rTokenReserves, B.rTokenReserves + sellAmt);

        // деньги пришли и fee начислился (кумулятивно)
        assertEq(after_ - before, netEthOut);
        // totalFee уже содержит buy-fee; проверим приращение
        // вычислим buyFee:
        uint256 buyNet = _netFromGross(buyValue);
        uint256 buyFee = buyValue - buyNet;
        assertEq(factory.totalFee(), buyFee + fee);
    }

    function test_Sell_InsufficientFundsInProtocol_Reverts() external {
        // Запускаем и сразу пытаемся продать, когда rEthReserves ещё 0
        vm.startPrank(owner);
        address token = factory.launchToken("S2", "S2", "u", 2 ether, 1000);
        vm.stopPrank();

        // Отдадим себе немного токенов напрямую с фабрики (эмуляция «левого» владельца)
        // здесь это допустимо только для теста: фабрика держит весь supply
        uint256 give = factory.tokenInfo(token).rTokenReserves / 10;
        vm.prank(address(factory));
        IERC20(token).transfer(buyer1, give);

        vm.expectRevert(ISmthTokenFactory.SmthTokenFactory_InsufficientFundsInProtocol.selector);
        vm.prank(buyer1);
        factory.sellToken(token, give);
    }

    function test_ClaimFee_OnlyOwner_And_Reset() external {
        // создаём комиссии buy
        vm.startPrank(owner);
        address token = factory.launchToken("FEE", "FEE", "u", 2 ether, 1000);
        vm.stopPrank();

        ISmthTokenFactory.TokenInfo memory B = factory.tokenInfo(token);
        (uint256 grossAll,,,) = _allRemainingOutcome(B);
        uint256 buyValue = grossAll - 1; // full-fill
        vm.prank(buyer1);
        factory.buyToken{value: buyValue}(token);

        uint256 accrued = factory.totalFee();
        assertGt(accrued, 0);

        // non-owner → revert
        vm.expectRevert(abi.encodeWithSelector(
            Ownable.OwnableUnauthorizedAccount.selector,
            buyer1
        ));
        vm.prank(buyer1);
        factory.claimFee(feeSink);

        // zero address → revert
        vm.expectRevert(abi.encodeWithSelector(ISmthTokenFactory.SmthTokenFactory__ZeroAddress.selector));
        vm.prank(owner);
        factory.claimFee(address(0));

        // ok: owner получает ETH, totalFee обнуляется
        uint256 before = feeSink.balance;
        vm.prank(owner);
        factory.claimFee(feeSink);
        uint256 after_ = feeSink.balance;

        assertEq(after_ - before, accrued);
        assertEq(factory.totalFee(), 0);
    }

    function test_LiquidityMigratedFlag_WhenAMMReservesZero() external {
        // Настроим параметры так, чтобы при автопереходе мигрировался весь AMM-бакет
        vm.startPrank(owner);
        address token = factory.launchToken("LM", "LM", "u", 1 ether, 1000);
        vm.stopPrank();

        // добиваем rTokenReserves
        vm.prank(buyer2);
        factory.buyToken{value: 10000 ether}(token);

        ISmthTokenFactory.TokenInfo memory A = factory.tokenInfo(token);
        assertTrue(A.isCompleted);
        // если finalizeAndMigrate использовал весь `ammTokenReserves`, должен быть true
        assertTrue(A.liquidityMigrated);
    }

}
