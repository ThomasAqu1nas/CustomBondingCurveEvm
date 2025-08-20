// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "../uniswap-v2/periphery/interfaces/IUniswapV2Router02.sol";
import {SmthToken} from "./SmthToken.sol";
import {ISmthTokenFactory} from "../interfaces/ISmthTokenFactory.sol";
import {FixedPointMathLib} from "../../../lib/FixedPointMathLib.sol";

/// @title SmthTokenFactory
/// @notice Bonding-curve trading with fixed-supply token, partial-fill buys, and delayed migration to Uniswap V2.
contract SmthTokenFactory is ISmthTokenFactory, Ownable, ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;


    // ------------- Storage -------------
    mapping(address => TokenInfo) private tokens; // token => info

    address private _uniswapRouter;
    address private _WETH;
    uint256 private _totalFee;
    Config  private _config;

    // ------------- Constructor / Admin -------------
    constructor(address router_) Ownable(_msgSender()) {
        if (router_ == address(0)) revert SmthTokenFactory__ZeroAddress();
        _uniswapRouter = router_;
        _WETH = IUniswapV2Router02(router_).WETH();

        setConfig(
            1_000_000_000 ether,    // total supply (18 decimals)
            62_500_000_000_000_000, // migrationFeeNumerator = 0.0625 WAD (example)
            100,                    // trade fee = 1% (BPS)
            10_000,                 // denominator
            18                      // token decimals (display)
        );
    }

    function setConfig(
        uint256 totalSupply_,
        uint256 migrationFeeNumerator_,   // WAD fraction in [0..1e18)
        uint256 tradeFeeBpsNumerator_,    // BPS (0..10000)
        uint256 bpsDenominator_,          // usually 10_000
        uint256 tokenDecimals_            // 18
    ) public onlyOwner {
        if (bpsDenominator_ == 0) revert SmthTokenFactory_InvalidBpsDenominator(bpsDenominator_);
        _config = Config({
            totalSupply: totalSupply_,
            migrationFeeNumerator: migrationFeeNumerator_,
            tradeFeeBpsNumerator: tradeFeeBpsNumerator_,
            defaultBpsDenominator: bpsDenominator_,
            tokenDecimals: tokenDecimals_,
            isInitialized: true
        });
    }

    // ------------- Views -------------
    function tokenInfo(address token) external view override returns (TokenInfo memory) { return tokens[token]; }
    function uniswapRouter() external view override returns (address) { return _uniswapRouter; }
    function WETH() external view override returns (address) { return _WETH; }
    function totalFee() external view override returns (uint256) { return _totalFee; }

    // ------------- Launch -------------
    /// @notice Deploy token (full supply to factory) and initialize curve reserves so that:
    /// - Putting exactly `initialAmmEthAmount_` (GROSS, incl. trade fee) into the curve
    ///   empties real inventory R, and final curve price equals AMM start price S/T;
    /// - rEthReserves is enough to fund AMM with S and pay migration fee.
    function launchToken(
        string memory name_,
        string memory symbol_,
        string memory uri_,
        uint256 initialAmmEthAmount_, // GROSS ETH expected to be raised on the curve before migration
        uint256 initialRatio_         // BPS: e.g. 1000 = 10% to AMM
    ) external payable nonReentrant returns (address tokenAddress) {
        if (!_config.isInitialized) revert SmthTokenFactory_NotInitialized();
        if (initialAmmEthAmount_ == 0) revert SmthTokenFactory__ZeroAmount();
        if (initialRatio_ == 0 || initialRatio_ >= _config.defaultBpsDenominator) {
            revert SmthTokenFactory_InvalidInitialRatio(initialRatio_, _config.defaultBpsDenominator);
        }
        if (_config.tradeFeeBpsNumerator >= _config.defaultBpsDenominator) {
            revert SmthTokenFactory_TradeFeeTooHigh(_config.tradeFeeBpsNumerator, _config.defaultBpsDenominator);
        }
        if (_config.migrationFeeNumerator >= 1e18) {
            revert SmthTokenFactory_MigrationFeeTooHigh(_config.migrationFeeNumerator);
        }

        // 1) Deploy token (mints full supply to this factory)
        SmthToken token = new SmthToken(name_, symbol_, _config.totalSupply);

        // 2) Fill per-token metadata
        TokenInfo storage info = tokens[address(token)];
        info.creator = _msgSender();
        info.tokenAddress = address(token);
        info.name = name_;
        info.symbol = symbol_;
        info.uri = uri_;
        info.tokenTotalSupply = _config.totalSupply;
        info.tokenDecimals = _config.tokenDecimals;

        // 3) Initialize curve virtual/real reserves per Solana logic
        _initReserves(info, initialAmmEthAmount_, initialRatio_);

        emit SmthTokenFactory__TokenLaunched(
            address(token), name_, symbol_, uri_,
            info.vEthReserves, info.vTokenReserves,
            info.rEthReserves, info.rTokenReserves,
            _msgSender()
        );

        // 4) Optional immediate buy with msg.value (same rules as buyToken: fee, partial fill, refund)
        if (msg.value > 0) {
            _buyWithValue(address(token), info, _msgSender(), msg.value);
            if (info.rTokenReserves == 0 && !info.isCompleted) {
                info.isCompleted = true;
                finalizeAndMigrate(address(token), info.ammTokenReserves);
            }
        }

        return address(token);
    }

    // ------------- Curve math helpers -------------

    /// @dev Compute and set reserves so that:
    /// (vS + SS)/(vT - R) = S/T  and  vS*vT = (vS+SS)*(vT - R),
    /// where SS = netFromGross(GROSS), S = floor(SS / (1+m)).
    /// Writes directly into `info` to avoid stacking too many locals in caller.
    function _initReserves(
        TokenInfo storage info,
        uint256 gross,           // initialAmmEthAmount_ (GROSS, incl. trade fee)
        uint256 initialRatioBps  // share to AMM in BPS
    ) private {
        // Split supply
        uint256 T = (_config.totalSupply * initialRatioBps) / _config.defaultBpsDenominator; // to AMM
        uint256 R = _config.totalSupply - T;                                                 // curve inventory
        if (T == 0 || R == 0) revert SmthTokenFactory_InvalidTR(T, R);

        // Net ETH to accumulate on curve before migration (after trade fee)
        uint256 SS = _netFromGross(gross, _config.defaultBpsDenominator, _config.tradeFeeBpsNumerator);
        if (SS == 0) revert SmthTokenFactory_NetRaiseZero(gross, _config.tradeFeeBpsNumerator);

        // S = floor( SS / (1 + m) ), m is WAD
        uint256 onePlusM = 1e18 + _config.migrationFeeNumerator;
        uint256 S = FixedPointMathLib.divWadDown(SS, onePlusM);
        if (S == 0) revert SmthTokenFactory_BaseRaiseZero(SS, _config.migrationFeeNumerator);

        // Feasibility: S*R > SS*T
        uint256 SR  = FixedPointMathLib.mulDivDown(S, R, 1);
        uint256 SST = FixedPointMathLib.mulDivDown(SS, T, 1);
        if (SR <= SST) revert SmthTokenFactory_IncompatibleGeometry(S, R, SS, T);

        // vT = R * (S*R) / (S*R - SS*T)
        uint256 den = SR - SST;
        uint256 vT = FixedPointMathLib.mulDivDown(R, SR, den);

        // vS = SS * (vT - R) / R
        uint256 vS = FixedPointMathLib.mulDivDown(SS, (vT - R), R);
        if (vS == 0 || vT <= R) revert SmthTokenFactory_InvalidVirtuals(vS, vT, R);

        // Write reserves
        info.vEthReserves     = vS;
        info.vTokenReserves   = vT;
        info.rEthReserves     = 0;
        info.rTokenReserves   = R;
        info.ammTokenReserves = T;
        info.migrationFee     = 0;
        info.isCompleted      = false;
    }

    /// @dev ceil(a/b) for positive integers
    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev Given (vS,vT) and net ETH in, return (newS,newT,tokensOut). x*y=k model.
    function _buyAfterNetEth(uint256 vS, uint256 vT, uint256 ethNet)
        internal
        pure
        returns (uint256 newS, uint256 newT, uint256 tokensOut)
    {
        newS = vS + ethNet;
        newT = (vS * vT) / newS;
        tokensOut = vT - newT;
    }

    /// @dev Net ETH required to buy exactly `tokenDelta` (ceil), with current (vS,vT).
    function _ethForExactTokensBuy(uint256 vS, uint256 vT, uint256 tokenDelta)
        internal
        pure
        returns (uint256 ethNetNeeded, uint256 newS, uint256 newT)
    {
        if (tokenDelta == 0 || tokenDelta >= vT) revert SmthTokenFactory_InvalidTokenDelta(tokenDelta, vT);
        newT = vT - tokenDelta;
        newS = _ceilDiv(vS * vT, newT);
        ethNetNeeded = newS - vS;
    }

    function _netFromGross(uint256 gross, uint256 denom, uint256 feeBps) private pure returns (uint256) {
        // net = gross * (denom - fee) / denom
        return (gross * (denom - feeBps)) / denom;
    }

    function _grossFromNetCeil(uint256 ethNetNeeded, uint256 denom, uint256 feeBps) private pure returns (uint256) {
        return _ceilDiv(ethNetNeeded * denom, (denom - feeBps));
    }

    function _fullFillOutcome(
        uint256 vS,
        uint256 vT,
        uint256 ethNet
    ) internal pure returns (uint256 newS, uint256 newT, uint256 outAmt) {
        newS = vS + ethNet;
        newT = (vS * vT) / newS;
        outAmt = vT - newT;
    }

    function _forExactTokensBuyAllRemaining(
        uint256 vS,
        uint256 vT,
        uint256 rToken,
        uint256 bpsDen,
        uint256 feeBps
    ) internal pure returns (uint256 ethNetNeeded, uint256 newS, uint256 newT, uint256 ethGrossNeeded) {
        // _ethForExactTokensBuy(vS, vT, rToken)
        uint256 _newT = vT - rToken;
        uint256 _newS = (vS * vT + _newT - 1) / _newT; // ceilDiv
        uint256 _net  = _newS - vS;

        ethNetNeeded  = _net;
        newS          = _newS;
        newT          = _newT;
        ethGrossNeeded = ( _net * bpsDen + (bpsDen - feeBps) - 1 ) / (bpsDen - feeBps); // grossFromNetCeil
    }

    // ------------- Trading (with partial fill) -------------

    /// @notice Buy tokens against the curve; if desired amount exceeds curve inventory, perform partial fill and refund surplus ETH.
    function buyToken(address _token) external payable override nonReentrant {
        if (msg.value == 0) revert SmthTokenFactory__ZeroAmount();
        TokenInfo storage info = tokens[_token];
        if (info.tokenAddress == address(0)) revert SmthTokenFactory__ZeroAddress();
        _buyWithValue(_token, info, _msgSender(), msg.value);
        if (info.rTokenReserves == 0 && !info.isCompleted) {
            info.isCompleted = true;
            finalizeAndMigrate(_token, info.ammTokenReserves);
        }
    }

    /// @notice Sell tokens back to the curve (ceil math to avoid value leakage).
    function sellToken(address _token, uint256 tokenAmount) external override nonReentrant {
        if (tokenAmount == 0) revert SmthTokenFactory__ZeroAmount();

        TokenInfo storage info = tokens[_token];
        if (info.tokenAddress == address(0)) revert SmthTokenFactory__ZeroAddress();

        // newT = vT + ΔT; newS = ceil((vS*vT)/newT)
        uint256 newReserveToken = info.vTokenReserves + tokenAmount;
        uint256 numerator = info.vEthReserves * info.vTokenReserves;
        uint256 newReserveEth = _ceilDiv(numerator, newReserveToken);

        uint256 grossEthOut = info.vEthReserves - newReserveEth;
        if (grossEthOut == 0) revert SmthTokenFactory_InsufficientOutputAmount(0);

        uint256 fee = (grossEthOut * _config.tradeFeeBpsNumerator) / _config.defaultBpsDenominator;
        uint256 netEthOut = grossEthOut - fee;

        if (grossEthOut > info.rEthReserves) revert SmthTokenFactory_InsufficientFundsInProtocol();
        if (address(this).balance < netEthOut) revert SmthTokenFactory_NotEnoughFunds();

        // pull tokens
        IERC20(_token).safeTransferFrom(_msgSender(), address(this), tokenAmount);

        // state
        info.vEthReserves = newReserveEth;
        info.vTokenReserves = newReserveToken;
        info.rEthReserves -= grossEthOut;
        info.rTokenReserves += tokenAmount;

        // pay ETH
        (bool ok, ) = payable(_msgSender()).call{value: netEthOut}("");
        if (!ok) revert SmthTokenFactory_TransferFailed();
        _totalFee += fee;

        emit SmthTokenFactory__TokensSold(
            _token, _msgSender(), tokenAmount, netEthOut,
            info.vEthReserves, info.vTokenReserves,
            info.rEthReserves, info.rTokenReserves
        );
    }

    // ------------- Internal buy executor (used by launch + buyToken) -------------

    struct BuyCtx {
        uint256 ethNetMax;
        uint256 newS;
        uint256 newT;
        uint256 outAmt;
        uint256 ethNetNeeded;
        uint256 ethGrossNeeded;
        uint256 refund;
        uint256 R;
    }

    function _buyWithValue(address _token, TokenInfo storage info, address buyer, uint256 valueWei) internal {
        IERC20 tkn = IERC20(_token);
        BuyCtx memory C;

        // Try full fill with all valueWei
        {
            C.ethNetMax = _netFromGross(valueWei, _config.defaultBpsDenominator, _config.tradeFeeBpsNumerator);
            (C.newS, C.newT, C.outAmt) = _fullFillOutcome(info.vEthReserves, info.vTokenReserves, C.ethNetMax);

            if (C.outAmt <= info.rTokenReserves) {
                if (C.outAmt == 0) revert SmthTokenFactory_InsufficientOutputAmount(0);
                uint256 bal = tkn.balanceOf(address(this));
                if (C.outAmt > bal) revert SmthTokenFactory_FactoryTokenBalanceTooLow(C.outAmt, bal);

                // state
                info.vEthReserves = C.newS;
                info.vTokenReserves = C.newT;
                info.rEthReserves += C.ethNetMax;
                info.rTokenReserves -= C.outAmt;

                // transfer
                tkn.safeTransfer(buyer, C.outAmt);

                emit SmthTokenFactory__TokensPurchased(
                    _token, buyer, C.outAmt, valueWei,
                    info.vEthReserves, info.vTokenReserves,
                    info.rEthReserves, info.rTokenReserves
                );

                _totalFee += (valueWei - C.ethNetMax);
                return;
            }
        }

        // ----- Partial fill -----
        if (info.rTokenReserves == 0) revert SmthTokenFactory_InsufficientOutputAmount(0);

        (C.ethNetNeeded, C.newS, C.newT, C.ethGrossNeeded) =
            _forExactTokensBuyAllRemaining(
                info.vEthReserves,
                info.vTokenReserves,
                info.rTokenReserves,
                _config.defaultBpsDenominator,
                _config.tradeFeeBpsNumerator
            );

        if (C.ethGrossNeeded > valueWei) revert SmthTokenFactory_InsufficientEthForPartialFill(C.ethGrossNeeded, valueWei);

        C.R = info.rTokenReserves;

        // state
        info.vEthReserves = C.newS;
        info.vTokenReserves = C.newT;
        info.rEthReserves += C.ethNetNeeded;
        info.rTokenReserves = 0;

        uint256 bal2 = tkn.balanceOf(address(this));
        if (C.R > bal2) revert SmthTokenFactory_FactoryTokenBalanceTooLow(C.R, bal2);
        tkn.safeTransfer(buyer, C.R);

        // refund
        C.refund = valueWei - C.ethGrossNeeded;
        if (C.refund > 0) {
            (bool ok, ) = payable(buyer).call{value: C.refund}("");
            if (!ok) revert SmthTokenFactory_TransferFailed();
        }

        emit SmthTokenFactory__TokensPurchased(
            _token, buyer, C.R, C.ethGrossNeeded,
            info.vEthReserves, info.vTokenReserves,
            info.rEthReserves, info.rTokenReserves
        );

        _totalFee += (C.ethGrossNeeded - C.ethNetNeeded);
    }

    // ------------- Migration to UniswapV2 (after curve finalization) -------------

    /// @notice Migrate a portion (or all) of `ammTokenReserves` to Uniswap V2 at the current curve price.
    /// @dev Curve remains active after migration. Migration fee policy is applied on protocol ETH.
    function finalizeAndMigrate(address _token, uint256 tokenToLP) internal {
        TokenInfo storage info = tokens[_token];
        if (info.tokenAddress == address(0)) revert SmthTokenFactory__ZeroAddress();

        if (tokenToLP == 0) revert SmthTokenFactory__ZeroAmount();
        if (tokenToLP > info.ammTokenReserves) tokenToLP = info.ammTokenReserves;

        if (info.vEthReserves == 0 || info.vTokenReserves == 0) {
            revert SmthTokenFactory_InvalidVirtualReservesForMigration(info.vEthReserves, info.vTokenReserves);
        }

        // Keep AMM price == curve price
        uint256 ethNeeded = (tokenToLP * info.vEthReserves) / info.vTokenReserves;

        // Migration fee (WAD)
        uint256 fee = ethNeeded.mulWadDown(_config.migrationFeeNumerator);

        // Ensure enough ETH
        uint256 available = info.rEthReserves;
        if (available < ethNeeded + fee) {
            uint256 maxEthForPool = available > fee ? (available - fee) : 0;
            if (maxEthForPool == 0) revert SmthTokenFactory_NotEnoughFunds();
            tokenToLP = (tokenToLP * maxEthForPool) / ethNeeded;
            ethNeeded = maxEthForPool;
            fee = ethNeeded.mulWadDown(_config.migrationFeeNumerator);
        }
        if (tokenToLP == 0 || ethNeeded == 0) revert SmthTokenFactory_NotEnoughFunds();

        IERC20 t = IERC20(_token);
        uint256 bal = t.balanceOf(address(this));
        if (bal < tokenToLP) revert SmthTokenFactory_InsufficientTokenBalanceForLP(tokenToLP, bal);
        t.forceApprove(_uniswapRouter, tokenToLP);

        (uint amountToken, uint amountETH, ) = IUniswapV2Router02(_uniswapRouter).addLiquidityETH{value: ethNeeded}(
            _token,
            tokenToLP,
            (tokenToLP * 9900) / 10_000,
            (ethNeeded * 9900) / 10_000,
            address(this),
            block.timestamp + 1200
        );

        t.forceApprove(_uniswapRouter, 0);

        info.rEthReserves = info.rEthReserves - amountETH - fee;
        info.ammTokenReserves -= amountToken;
        _totalFee += fee;
        info.migrationFee += fee;

        if (info.ammTokenReserves == 0) {
            info.liquidityMigrated = true;
        }

        emit SmthTokenFactory__LiquiditySwapped(_token, amountToken, amountETH);
    }

    // ------------- Fees -------------
    function claimFee(address to) external override onlyOwner {
        if (to == address(0)) revert SmthTokenFactory__ZeroAddress();
        uint256 amt = _totalFee;
        _totalFee = 0;
        (bool ok, ) = payable(to).call{value: amt}("");
        if (!ok) revert SmthTokenFactory_TransferFailed();
        emit SmthTokenFactory__ClaimedFee(amt);
    }

    // ------------- Receive -------------
    receive() external payable {}
}
