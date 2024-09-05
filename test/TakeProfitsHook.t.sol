// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

//Imports
import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {TakeProfitsHook} from "../src/TakeProfitsHook.sol";

contract TakeProfitsHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency token0;
    Currency token1;

    TakeProfitsHook hook;

    function setUp() public {
        //Deploying v4 core contracts
        deployFreshManagerAndRouters();

        //Deploying two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        //Deploying our hooks
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("TakeProfitsHook.sol", abi.encode(manager, ""), hookAddress);
        hook = TakeProfitsHook(hookAddress);

        //Approving the hook to use token0 and token1
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        //Initializing a pool with the two tokens
        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        //Adding initial liquidity

        //Adding liquidity from -60 to +60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        //Adding liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickUpper: 120,
                tickLower: -120,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        //Adding liquidity to full range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_PlaceOrder() public {
        //Placing a zeroForOne take-profit order for 10e18 at tick 100
        int24 tick = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;

        //Original balance of token0
        uint256 originalBalance = token0.balanceOfSelf();

        //Placing the order
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);

        //New balance of token 0
        uint256 newBalance = token0.balanceOfSelf();

        //Since the tick spacing of the pool is 60, tick can only be in multiples of it. so the tick lower will be rounded to the nearest lower value i.e 60
        assertEq(tickLower, 60);

        //Checking the balance after placing the order.
        assertEq(originalBalance - newBalance, amount);

        //Checking the ERC-1155 balance for the user.
        uint256 positionId = hook.getPositionId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);

        assertTrue(positionId != 0);
        assertEq(tokenBalance, amount);
    }

    function test_cancelOrder() public {
        //Initializing order params
        int24 tick = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;

        //Capturing the initial balance and placing the order
        uint256 originalBalance = token0.balanceOfSelf();

        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);

        uint256 newBalance = token0.balanceOfSelf();

        //Asserting placing an order
        assertEq(tickLower, 60);
        assertEq(originalBalance - newBalance, amount);

        //Checking ERC1155 balance for the user
        uint256 positionId = hook.getPositionId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, amount);

        //Placing the cancel order
        hook.cancelOrder(key, tickLower, zeroForOne);

        //Checking that we received our token0 amount back and no longer own ERC-1155 tokens
        uint256 finalBalance = token0.balanceOfSelf();
        assertEq(finalBalance, originalBalance);

        tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, 0);
    }

    /**
     * @dev testing takeProfitOrder for zeroForOne swap
     */
    function test_orderExecute_zeroForOne() public {
        //initializing variable to place order.
        int24 tick = 100;
        uint256 amount = 1 ether;
        bool zeroForOne = true;

        //Placing takeProfitOrder at tick = 100 for 1e18 token0
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);

        //Initializing swap params
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        //Swapping 1e18 of token1 for token0
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        //Verifying the takeProfitOrder is successful by asserting that no pedingTokens are remaining.
        uint256 pendingTokensForPosition = hook.pendingOrders(key.toId(), tick, zeroForOne);
        assertEq(pendingTokensForPosition, 0);

        //Verifying that the hook contract has enough token1 ready to be redeemed.
        uint256 positionId = hook.getPositionId(key, tickLower, zeroForOne);
        uint256 claimableOutputTokens = hook.claimableOutputTokens(positionId);
        uint256 hookContractToken1Balance = token1.balanceOf(address(hook));
        assertEq(claimableOutputTokens, hookContractToken1Balance);

        //Redeeming available token1 in the hook contract.
        uint256 originalToken1Balance = token1.balanceOf(address(this));
        hook.redeem(key, tick, zeroForOne, amount);
        uint256 newToken1Balance = token1.balanceOf(address(this));
        assertEq(newToken1Balance - originalToken1Balance, claimableOutputTokens);
    }

    /**
     * @dev testing for takeProfitOrder for oneForZero swap
     */
    function test_orderExecute_oneForZero() public {
        //initializing takeProfitOrder variables
        int24 tick = -100;
        uint256 amount = 10 ether;
        bool zeroForOne = false;

        //Placing take profit order at tick = -100 for 10e18 of token1
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);

        //Initializing swap params and swap settings
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        //Buying 1e18 token0 for token1
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        //Verifying takeProfitOrder is successful by asserting that there are no pending tokens remaining
        uint256 tokensLeftToSell = hook.pendingOrders(key.toId(), tick, zeroForOne);
        assertEq(tokensLeftToSell, 0);

        //Verifying the hook contract has enough token0 to redeem.
        uint256 positionId = hook.getPositionId(key, tickLower, zeroForOne);
        uint256 claimableOutputTokens = hook.claimableOutputTokens(positionId);
        uint256 hookContractToken0Balance = token0.balanceOf(address(hook));
        assertEq(claimableOutputTokens, hookContractToken0Balance);

        //redeeming token0 available in the hook contract.
        uint256 originalToken0Balance = token0.balanceOfSelf();
        hook.redeem(key, tick, zeroForOne, amount);
        uint256 newToken0Balance = token0.balanceOfSelf();

        assertEq(newToken0Balance - originalToken0Balance, claimableOutputTokens);
    }

    /**
     * @dev testing multiple takeProfitOrder for zeroForOne swap. Swap changes the tick such that only the takeProfitOrder that is in range is of currentTick and the lastTick is executed
     */
    function test_multiple_orderExecute_zeroForOne_onlyOne() public {
        //Placing two takeProfitOrder, one at tick = 0 and tick = 60
        uint256 amount = 0.01 ether;
        hook.placeOrder(key, 0, true, amount);
        hook.placeOrder(key, 60, true, amount);

        //Verifying that the current tick is 0 initially
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertEq(currentTick, 0);

        //Initializing swap params and test settings
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        //Performing the swap
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        //Verifying that the takeProfitOrder at tick = 0 is executed.
        uint256 tokensLeftToSell = hook.pendingOrders(key.toId(), 0, true);
        assertEq(tokensLeftToSell, 0);

        //Verifying that the takeProfitOrder at tick = 60 is still pending.
        tokensLeftToSell = hook.pendingOrders(key.toId(), 60, true);
        assertEq(tokensLeftToSell, amount);
    }

    /**
     * @dev testing for multiple takeProfitOrders placed and both of them are executed.
     */
    function test_multiple_orderExecute_zeroForOne_both() public {
        //Placing takeProfitOrders at tick = 0 and tick = 60
        uint256 amount = 0.01 ether;
        hook.placeOrder(key, 0, true, amount);
        hook.placeOrder(key, 60, true, amount);

        //Initializing swap params and pool test settings
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -0.5 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        //Swapping to increase the tick value
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        //verifying that both the takeProfitOrder is executed i.e. at tick = 0 and also at tick = 60
        uint256 tokensLeftToSell = hook.pendingOrders(key.toId(), 0, true);
        assertEq(tokensLeftToSell, 0);

        tokensLeftToSell = hook.pendingOrders(key.toId(), 60, true);
        assertEq(tokensLeftToSell, 0);
    }

    /**
     * Adding this code snippet because ERC-1155 implimentation by OpenZeppline does not allow ERC-1155 tokens to be transferred to EOA account
     */
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
