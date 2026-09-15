# Expired claim locks retain and ratchet boosted reward weight

This Foundry PoC runs only against a local Ethereum mainnet fork. It does not broadcast a transaction.

## Target fixture

- DepositPool proxy: `0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790`
- Deployed implementation: `0xdB10dAEF167eA2233Ba6811457dD24D676FbD670`
- Reward pool: `0` (stETH)
- Pinned block: `25,978,896`
- Pinned block hash: `0x49601ab9767bc927911c751a2b6eb88d19213e02fc0c18680a09f7617d666812`
- Historical expiry-adjacent block: `25,530,507` (`claimLockEnd + 2 seconds`)
- Ordinary live staker fixture: `0xb13c99b5df2d72261b6f642f7104438f9d2543ab`

The staker has `8.7 stETH` deposited and a claim lock that expired at timestamp `1,784,027,565`, but the deployed pool still stores and rewards `27.536439500729018151 stETH` of virtual weight. Between the expiry-adjacent and pinned blocks, the position accrued exactly `284.729172604043791108 MOR`. At the same observed rate, a 1x position would accrue `89.958754529233869076 MOR`; the retained expired boost accounts for `194.770418074809922032 MOR` of excess allocation.

## Reproduce

Foundry is the only dependency. `ETH_RPC_URL` must be an archive-capable Ethereum RPC because the tests read both pinned historical blocks.

```sh
ETH_RPC_URL=https://eth-mainnet.public.blastapi.io forge test -vv
```

Expected result: `5 passed; 0 failed; 0 skipped`.

## What the tests prove

1. `testLiveHistoricalStateAccruedExactPostExpiryExcess` uses only unmodified deployed state at two historical blocks. It asserts that the expired position did not change, the boost remained active, and the exact post-expiry excess is `194.770418074809922032 MOR`.
2. `testLiveExpiredUserCanRelockFor100SecondsUsingHistoricalStart` impersonates only the ordinary staker on the local fork. After a fully unlocked gap, a 100-second lock reuses the 2025 `claimLockStart`, raising both multiplier and virtual deposit; expiry again leaves that higher weight intact.
3. `testLiveExpiredRewardClaimTraversesLayerZeroAndResetsWeight` quotes the live LayerZero V1 endpoint fee, pays exactly that fee on the fork, asserts its outbound nonce increments, and verifies the claim finally resets the user's lock and weight to 1x.
4. `testControlNonStakerCannotCreateClaimLock` is the negative control: an address without a deposit cannot create a lock.
5. `testMockedAccumulatorShowsOtherUserDilutionEqualsAttackerExcess` is intentionally isolated from the live-state tests. It changes only the Distributor reward getter by a fixed `1,000 MOR`, reproduces the deployed accounting formula within one wei of rounding, and proves aggregate other-user dilution equals the attacker's excess allocation.

## Attack data flow and pseudocode

```text
ordinary staker
    |
    | waits until claimLockEnd has passed (claim is unlocked)
    v
lockClaim(pool=0, end=now+100)
    |
    | validation checks only end > now and end > old end
    v
claimLockStart = stored nonzero historical start
    |
    v
multiplier = f(historical start, now+100)
    |
    v
virtualDeposited increases and remains stored after the 100-second expiry
    |
    v
future fixed-pool MOR emissions allocate an excess share to the staker
```

```text
require(user.deposited > 0)
require(block.timestamp > user.claimLockEnd)       // unlocked gap

shortEnd = block.timestamp + 100
pool.lockClaim(0, shortEnd)

assert(user.claimLockStart == historicalStart)     // stale start reused
assert(user.virtualDeposited > oldVirtualDeposit)  // reward weight ratcheted

warp(shortEnd + 1)
assert(user.claimLockEnd < block.timestamp)
assert(user.virtualDeposited == ratchetedWeight)   // expiry does not reset weight
```

## Scope and limitations

- No owner, admin, multisig, upgrader, or other privileged caller is impersonated.
- The live staker is impersonated only inside Foundry's disposable fork.
- The tests execute the source-chain LayerZero endpoint and prove the outbound nonce changes. They do not simulate delivery or minting on the destination chain.
- Only the explicitly named accumulator test uses `vm.mockCall`; the historical-state, relock, claim, and negative-control tests are fully unmocked.
- The `194.770418074809922032 MOR` historical figure is the exact excess weight allocation at the observed live rate, not a replay of every intermediate Distributor checkpoint under a hypothetical 1x denominator. The isolated fixed-`1,000 MOR` accumulator test supplies that pool-wide counterfactual and asserts dilution equality.
- RPC providers can rate-limit public endpoints. Any archive-capable Ethereum endpoint can be supplied through `ETH_RPC_URL` without changing the code.
