# reHackt

Reproductions of historical DeFi exploits for research and education.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (Forge, Anvil, Cast)
- Git submodules / dependencies:

```bash
# Install dependencies (forge-std and any libs in foundry.toml / remappings)
forge install
```

## Balancer (osETH/wETH Composable Stable Pool)

Reproduces the exploit against the Balancer V2 osETH/wETH composable stable pool (rounding in `_upscale()`). The contract builds a single `batchSwap` that depletes the pool, runs the rounding exploit, then refills and withdraws profit.

### Run (simulation on fork)

Uses a mainnet fork at the hack block. No broadcast.

```bash
forge script script/DeployBalancerHacker.s.sol:DeployBalancerHacker
```

The script forks at block `23717396`, deploys `BalancerHacker` with computed depletion rounds and 30 exploit rounds, runs the exploit in the constructor, then withdraws internal balance to the deployer and logs WETH/osETH balances.

---

## Cover Protocol (Blacksmith)

Reproduces the December 2020 exploit against Cover Protocol’s Blacksmith contract (reward calculation abuse). The test forks mainnet at the historical block and runs the attack to claim excess COVER rewards.

### Run tests

```bash
# All Cover Protocol tests
forge test --match-path "test/Cover-Protocol/*.sol" -vvv

# Single test contract (Hacker)
forge test --match-contract "Hacker" --match-path "test/Cover-Protocol/*.sol" -vvv

# Single test (test_StealCover)
forge test --match-test "test_StealCover" -vvv
```

Tests fork mainnet at block `11_542_183`, swap ETH for DAI then for BPT, stake on Blacksmith, and run the exploit to steal COVER. Verbosity (`-vvv`) shows logs and traces.

---

## Project layout

- `src/Balancer/` — Balancer exploit contract and helpers
- `src/interfaces/` — IVault, IERC20, etc.
- `script/DeployBalancerHacker.s.sol` — Balancer deploy + run script
- `test/Cover-Protocol/` — Cover Protocol exploit tests
- `lib/` — forge-std, cover-token-mining, and other deps (see `remappings.txt`)
