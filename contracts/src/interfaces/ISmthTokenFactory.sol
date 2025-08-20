// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ISmthTokenFactory
/// @notice Interface for the Smth Token Factory: launching ERC20-like tokens,
///         tracking bonding-curve style virtual/real reserves, handling buys/sells,
///         and migrating liquidity to AMMs.
interface ISmthTokenFactory {
    // -------------------- Errors --------------------
    error SmthTokenFactory__ZeroAddress();
    error SmthTokenFactory__ZeroAmount();
    error SmthTokenFactory_InsufficientOutputAmount(uint256 amount);
    error SmthTokenFactory_InsufficientFundsInProtocol();
    error SmthTokenFactory_NotEnoughFunds();
    error SmthTokenFactory_TransferFailed();
    error SmthTokenFactory_NotInitialized();
    error SmthTokenFactory_InvalidBpsDenominator(uint256 bpsDenominator);
    error SmthTokenFactory_InvalidDecimals(uint8 decimals);
    error SmthTokenFactory_InvalidInitialRatio(uint256 initialRatioBps, uint256 denominator);
    error SmthTokenFactory_TradeFeeTooHigh(uint256 tradeFeeBps, uint256 denominator);
    error SmthTokenFactory_MigrationFeeTooHigh(uint256 migrationFeeWad); // must be < 1e18
    error SmthTokenFactory_InvalidTR(uint256 T, uint256 R); // either is zero
    error SmthTokenFactory_NetRaiseZero(uint256 gross, uint256 feeBps);
    error SmthTokenFactory_BaseRaiseZero(uint256 netSS, uint256 migrationFeeWad);
    error SmthTokenFactory_IncompatibleGeometry(uint256 S, uint256 R, uint256 SS, uint256 T); // requires S*R > SS*T
    error SmthTokenFactory_InvalidVirtuals(uint256 vS, uint256 vT, uint256 R); // vS>0 && vT>R
    error SmthTokenFactory_InvalidTokenDelta(uint256 tokenDelta, uint256 vTokenReserves);
    error SmthTokenFactory_FactoryTokenBalanceTooLow(uint256 required, uint256 actual);
    error SmthTokenFactory_InsufficientEthForPartialFill(uint256 neededGrossWei, uint256 providedWei);
    error SmthTokenFactory_InvalidVirtualReservesForMigration(uint256 vS, uint256 vT);
    error SmthTokenFactory_InsufficientTokenBalanceForLP(uint256 required, uint256 actual);

    /// @notice Global configuration used on token launch and fee accounting.
    // -------------------- Config --------------------

    /// @notice Total supply to be minted at token launch (18 decimals).
    function totalSupply() external view returns(uint256);

    /// @dev `migrationFeeNumerator` is a WAD fraction (0..1e18), others are BPS or raw integers.
    /// @notice Migration fee fraction in WAD (e.g., 0.05e18 = 5%).
    function migrationFeeNumerator() external view returns(uint256);

    /// @notice Trading fee in basis points (e.g., 100 = 1%).
    function tradeFeeBpsNumerator() external view returns(uint256);

    /// @notice BPS denominator, typically 10_000.
    function defaultBpsDenominator() external view returns(uint256);

    /// @notice Token decimals (for display/metadata; the math assumes 18 decimals).
    function tokenDecimals() external view returns(uint8);

    /// @notice Whether the config has been initialized.
    function isInitialized() external view returns(uint8);

    // -------------------- TokenInfo --------------------

    /// @notice Per-token accounting tracked by the factory for bonding-curve math and migration.
    /// @dev vEthReserves * vTokenReserves = constant product (virtual reserves).
    struct TokenInfo {
        /// @notice Original token creator address.
        address creator;

        /// @notice Launched token address (ERC20-like).
        address tokenAddress;

        /// @notice Token metadata (not enforced on-chain here).
        string name;
        string symbol;
        string uri;

        /// @notice Total supply and decimals (decimals kept for completeness).
        uint256 tokenTotalSupply;
        uint256 tokenDecimals;

        /// @notice Virtual ETH reserve (vS) used by the bonding-curve formulas.
        uint256 vEthReserves;

        /// @notice Virtual token reserve (vT) used by the bonding-curve formulas.
        uint256 vTokenReserves;

        /// @notice Real ETH reserve (accumulated ETH the protocol can pay out on sells).
        uint256 rEthReserves;

        /// @notice Real token reserve (remaining token inventory for sales; increases on user sells).
        uint256 rTokenReserves;

        /// @notice Initial token reserve in v2 amm protocol.
        uint256 ammTokenReserves;

        /// @notice Absolute migration fee kept aside from rEthReserves during liquidity migration.
        uint256 migrationFee;

        /// @notice True once the bonding-curve is completed (e.g., after final mint/migration).
        bool isCompleted;
        bool liquidityMigrated;
    }

    // -------------------- Events --------------------

    /// @notice Emitted once a token is launched and reserves are initialized.
    event SmthTokenFactory__TokenLaunched(
        address indexed token,
        string name,
        string symbol,
        string uri,
        uint256 vReserveEth,
        uint256 vReserveToken,
        uint256 rReserveEth,
        uint256 rReserveToken,
        uint256 initialRatio,
        uint256 initialAmmEthAmount,
        address indexed creator
    );

    /// @notice Emitted after a successful buy.
    /// @param token Token address.
    /// @param buyer Buyer address.
    /// @param amount Tokens minted to the buyer.
    /// @param cost ETH paid by the buyer (msg.value).
    /// @param vReserveEth Updated virtual ETH reserve.
    /// @param vReserveToken Updated virtual token reserve.
    /// @param rReserveEth Updated real ETH reserve.
    /// @param rReserveToken Updated real token reserve.
    event SmthTokenFactory__TokensPurchased(
        address indexed token,
        address indexed buyer,
        uint256 amount,
        uint256 cost,
        uint256 vReserveEth,
        uint256 vReserveToken,
        uint256 rReserveEth,
        uint256 rReserveToken
    );

    /// @notice Emitted after a successful sell.
    /// @param token Token address.
    /// @param seller Seller address.
    /// @param amount Tokens received from the seller.
    /// @param refund ETH sent to the seller (after fee).
    /// @param vReserveEth Updated virtual ETH reserve.
    /// @param vReserveToken Updated virtual token reserve.
    /// @param rReserveEth Updated real ETH reserve.
    /// @param rReserveToken Updated real token reserve.
    event SmthTokenFactory__TokensSold(
        address indexed token,
        address indexed seller,
        uint256 amount,
        uint256 refund,
        uint256 vReserveEth,
        uint256 vReserveToken,
        uint256 rReserveEth,
        uint256 rReserveToken
    );

    /// @notice Emitted after migrating liquidity to an AMM.
    event SmthTokenFactory__LiquiditySwapped(
        address indexed token,
        address indexed pair,
        uint256 tokenAmount,
        uint256 ethAmount
    );

    /// @notice Emitted after claiming accumulated protocol fees.
    event SmthTokenFactory__ClaimedFee(uint256 amount);

    // -------------------- Views --------------------

    /// @notice Get per-token info by token address.
    function tokenInfo(address token) external view returns (TokenInfo memory);

    /// @notice UniswapV2 router address used for liquidity migration.
    function uniswapRouter() external view returns (address);

    /// @notice UniswapV2 factory address used for pair address calc.
    function uniswapV2Factory() external view returns (address);

    /// @notice WETH address for the configured router.
    function WETH() external view returns (address);

    /// @notice Accumulated protocol fees (in ETH).
    function totalFee() external view returns (uint256);

    // -------------------- Actions --------------------

    /// @notice Launch a new token with bonding-curve parameters baked into virtual/real reserves.
    /// @dev The function may mint an initial supply and optionally handle an initial buy if msg.value > 0.
    /// @param name_ Token name (informational).
    /// @param symbol_ Token symbol (informational).
    /// @param uri_ Metadata URI (informational).
    /// @param initialAmmEthAmount_ Initial ETH amount “reserved” for AMM math (sets virtuals).
    /// @param initialRatio_ Ratio used to split token supply between meteora/real buckets.
    function launchToken(
        string memory name_,
        string memory symbol_,
        string memory uri_,
        uint256 initialAmmEthAmount_,
        uint256 initialRatio_
    ) external payable returns (address tokenAddress);

    /// @notice Buy tokens for ETH against the bonding curve.
    function buyToken(address _token) external payable;

    /// @notice Sell tokens for ETH against the bonding curve.
    function sellToken(address _token, uint256 tokenAmount) external;

    /// @notice Withdraw accumulated protocol fees to `to`.
    function claimFee(address to) external;

    /// @notice Receive ETH.
    receive() external payable;
}
