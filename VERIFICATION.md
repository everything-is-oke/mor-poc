# Verification record

Executed on 2026-09-15 from the standalone project directory with Foundry `1.7.1` (`4072e48705af9d93e3c0f6e29e93b5e9a40caed8`) and the archive-capable public endpoint `https://eth-mainnet.public.blastapi.io`.

```sh
$ forge fmt --check
# exit status 0; no formatter diff

$ ETH_RPC_URL=https://eth-mainnet.public.blastapi.io forge test -vv
Compiling 1 files with Solc 0.8.20
Solc 0.8.20 finished in 485.09ms
Compiler run successful!

Ran 5 tests for test/ExpiredClaimLock.t.sol:ExpiredClaimLockPoC
[PASS] testControlNonStakerCannotCreateClaimLock() (gas: 94084)
[PASS] testLiveExpiredRewardClaimTraversesLayerZeroAndResetsWeight() (gas: 608865)
Logs:
  layerzero_native_fee_wei: 43152915274982
  claimed_reward_wei: 2072153677237986240908

[PASS] testLiveExpiredUserCanRelockFor100SecondsUsingHistoricalStart() (gas: 248076)
Logs:
  old_multiplier_1e25: 31651079885895423170000000
  new_multiplier_1e25: 35072216545522978860000000
  old_virtual_deposit: 27536439500729018151
  new_virtual_deposit: 30512828394604991601

[PASS] testLiveHistoricalStateAccruedExactPostExpiryExcess() (gas: 138643)
Logs:
  post_expiry_reward_wei: 284729172604043791108
  post_expiry_one_x_equivalent_wei: 89958754529233869076
  post_expiry_excess_wei: 194770418074809922032

[PASS] testMockedAccumulatorShowsOtherUserDilutionEqualsAttackerExcess() (gas: 197039)
Logs:
  mocked_total_reward_wei: 1000000000000000000000
  attacker_increment_wei: 1809657404224197332
  intended_one_x_increment_wei: 516648711587904524
  attacker_excess_wei: 1293008692636292808
  aggregate_other_user_dilution_wei: 1293008692636292808

Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 42.04s (65.46s CPU time)

Ran 1 test suite in 42.04s (42.04s CPU time): 5 tests passed, 0 failed, 0 skipped (5 total tests)
```
