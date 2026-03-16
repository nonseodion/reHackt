// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import {StableMath} from "./libraries/StableMath.sol";
import {FixedPoint} from "./libraries/FixedPoint.sol";
import {_upscale, _downscaleUp} from "./helpers.sol";

// Externalized StableMath quoting used by `BalancerHacker` while assembling batch swaps.
// Keeping this in a separate contract lets `BalancerHacker` use try/catch when Newton iteration fails (BAL#321).
contract ExploitSwapQuoter {
    using FixedPoint for uint256;

    function quoteAmountInWithFee(
        uint256 amplificationParameter,
        uint256 swapFeePercentage,
        uint256[] calldata balances,
        uint256[] calldata scalingFactors,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountOut
    ) external pure returns (uint256) {
        // This quoter is specialized to the 2-token StableMath domain (WETH, osETH):
        // tokenInIndex/tokenOutIndex are 0 or 1 for [WETH, osETH] (BPT is never passed).

        uint256[] memory scaledBalances = new uint256[](2);
        scaledBalances[0] = _upscale(balances[0], scalingFactors[0]);
        scaledBalances[1] = _upscale(balances[1], scalingFactors[1]);

        uint256 invariant = StableMath._calculateInvariant(
            amplificationParameter,
            scaledBalances
        );

        uint256 amountInScaled = StableMath._calcInGivenOut(
            amplificationParameter,
            scaledBalances,
            tokenInIndex,
            tokenOutIndex,
            _upscale(amountOut, scalingFactors[tokenOutIndex]),
            invariant
        );

        uint256 amountInUnscaled = _downscaleUp(
            amountInScaled,
            scalingFactors[tokenInIndex]
        );
        
        return amountInUnscaled.divUp(
            swapFeePercentage.complement()
        );
    }
}
