// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * Imports
 */
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

contract TakeProfitsHook is BaseHook, ERC1155 {
    /**
     * Libraries
     */

    //Gives access to helper functions to read the storage values like `slot0` to PoolManager.
    using StateLibrary for IPoolManager;

    //Using PoolIdLibrary to convert PoolKeys to IDs.
    using PoolIdLibrary for PoolKey;

    //Used to represent currency types and other helper functions like `isNative()`
    using CurrencyLibrary for Currency;

    //Used for math helper functions like `mulDiv`
    using FixedPointMathLib for uint256;

    /**
     * Errors
     */
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

    //State variables
    mapping(PoolId poolId => mapping(int24 tickToSellAt => mapping(bool zeroForOne => uint256 inputAmount))) public
        pendingOrders;

    mapping(uint256 positionId => uint256 claimsSupply) public claimTokensSupply;

    mapping(uint256 positionId => uint256 outputClaimable) public claimableOutputTokens;

    //Constructor
    constructor(IPoolManager _manager, string memory _uri) BaseHook(_manager) ERC1155(_uri) {}

    /**
     * Public functions
     */
    //BaseHook permissions
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, //Need this for what?
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true, // To check and place take-profit orders after the swap is performed.
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick, bytes calldata)
        external
        override
        onlyByPoolManager
        returns (bytes4)
    {
        // TODO:

        return this.afterInitialize.selector;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4, int128) {
        //TODO:

        return (this.afterSwap.selector, 0);
    }

    /**
     * Helpers
     */

    /**
     * NOTE: 1.Why do we need to transfer sellTokens to this account?
     *  2. Before calling transferFrom() shouldnt we approve(give allowance) the hook contract to spend that input amount?
     *
     */
    function placeOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 inputAmount)
        external
        returns (int24)
    {
        //Get the usable tick for the tick provided.
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);

        //Creating a pending order.
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;

        //Mint claim tokens to user equal to input amount.
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        claimTokensSupply[positionId] += inputAmount;
        _mint(msg.sender, positionId, inputAmount, "");

        //Transfering input tokens to hook contract based on the direction of the swap.
        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);

        return tick;
    }

    function cancelOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne) external {
        //Fetching the usable tick and positionId.
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        //Validate claim tokens
        uint256 positionTokens = balanceOf(msg.sender, positionId);

        if (positionTokens == 0) revert InvalidOrder();

        //Removing users worth of positionTokens from the pendingOrder, cant make this 0 since for the same position there can be multiple take-profit orders.
        pendingOrders[key.toId()][tick][zeroForOne] -= positionTokens;

        //Reducing the claimTokens totalSupply based on previously minted value.
        claimTokensSupply[positionId] -= positionTokens;
        _burn(msg.sender, positionId, positionTokens);

        //Transfer the input tokens to the user.
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, positionTokens);
    }

    function redeem(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 inputAmountToClaimFor)
        external
    {
        //Fetch the usable tick and positionId.
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        //Check if the order is yet to be fulfilled.
        if (claimableOutputTokens[positionId] == 0) revert NothingToClaim();

        //Check if amount of OutputClaimTokens >= amount of InputClaimTokens
        uint256 positionTokens = balanceOf(msg.sender, positionId);

        if (positionTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        uint256 totalClaimableForPosition = claimableOutputTokens[positionId];
        uint256 totalInputAmountForPosition = claimTokensSupply[positionId];

        /**
         * Calculating output amount
         * outputAmount = (inputAmountToClaimFor * totalClaimableForPosition) / (totalInputAmountForPosition)
         */
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(totalClaimableForPosition, totalInputAmountForPosition);

        //Reduce claimable output tokens amount + Reduce total supply of claim Tokens + burn claim tokens
        claimableOutputTokens[positionId] -= outputAmount;
        claimTokensSupply[positionId] -= inputAmountToClaimFor;
        _burn(msg.sender, positionId, inputAmountToClaimFor);

        //Transfer output tokens.
        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    function swapAndSettleBalances(PoolKey calldata key, IPoolManager.SwapParams memory params)
        internal
        returns (BalanceDelta)
    {
        //Fetching delta from PM
        BalanceDelta delta = poolManager.swap(key, params, "");

        //Settling balances with PM based on the direction of the swap
        if (params.zeroForOne) {
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }

            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }

            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }

        return delta;
    }

    function executeOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 inputAmount) internal {
        //Swapping and settling balances with PM
        BalanceDelta delta = swapAndSettleBalances(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(inputAmount), //Negative amount specified cause we are deducting token from our share to fetch the profit, specifying exact input for output swap
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        //Deducting inputAmount from pendingOrders.
        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;

        //Fetching positionId and calculating outputAmount
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));

        //Updating claim tokens for the position provided with the calculated output amount.
        claimableOutputTokens[positionId] += outputAmount;
    }

    function _settle(Currency currency, uint128 amount) internal {
        //Transfering tokens to PM
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        //Transfer amount from PM to our hook contract.
        poolManager.take(currency, address(this), amount);
    }

    /**
     * @dev E.g. tickSpacing = 60, tick = -100,  closest usable tick rounded-down will be -120
     */
    function getLowerUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        // intervals = -100/60 = -1 (integer division)
        int24 intervals = tick / tickSpacing;

        // since tick < 0, we round `intervals` down to -2
        // if tick > 0, `intervals` is fine as it is
        if (tick < 0 && tick % tickSpacing != 0) intervals--; // round towards negative infinity

        // actual usable tick, then, is intervals * tickSpacing
        // i.e. -2 * 60 = -120
        return intervals * tickSpacing;
    }

    /**
     * @dev helper function to fetch the positionId
     */
    function getPositionId(PoolKey calldata key, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }
}
