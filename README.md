# Limit Orders Hook

## Overview
Building an orderbook for Limit Orders and create an onchain orderbook directly integrated into Uniswap through a hook.

A take-profit is a type of order where the user wants to sell a token once it's price increases to hit a certain price. For example, if ETH is currently trading at 3,500 USDC - We can place a take-profit order that would represent something like "Sell 1 ETH when it's trading at 4,000 USDC".

NOTE: 
A take-profit order is just a normal swap that is just automatically executed when certain conditions matches due to the fact that a hook automatically executes it.



## Mechanism design
1. Place a take-profit order on a pool.
2. Cancel the placed take-profit order.
3. Redeem the tokens once the order is filled.

## Assumptions
1. We are not gonna worry about the gas costs associated with executing the take-profit order. The gas costs associated with it would be bore by the swapper.
2. We are not gonna conside the slippage placed on the take-profit order.
3. We will not write this hook for native-eth/token pool.

## Potential improvements

1. partial cancel orders functionality.
2. develop a functionality where in we place a cancelOrder after a particular time.
3. build an incentive mechanism for the gas costs handled by the normal swapper by paying him a proportion of the token of his choice on the pool he performed the swap on by the user who places the takeProfit order.
4. Use transient storage to store current tick values.