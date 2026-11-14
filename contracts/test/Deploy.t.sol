// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/libraries/RescueContractsDeployment.sol";

/// Checks script/live/Deploy.s.sol on a BSC fork: the RAKE owner (hardcoded) is fee recipient
/// (fee and leftovers) whoever deploys, the claim lists the seven underlyings in market order and snapshots
/// every depositor before any rescue runs; the one patch is bound to the claim contract, the Venus
/// treasury and the markets' shared implementation, and knows exactly the seven market/strategy pairs.
contract DeployTest is Test {
    RakeDepositorsClaim claim;
    VenusMarketRescuePatch patch;

    function setUp() public {
        uint256 b = vm.envOr("FORK_BLOCK", uint256(0));
        string memory rpc = vm.envOr("BSC_RPC_URL", string("https://bsc-rpc.publicnode.com"));
        if (b == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, b);
        vm.startPrank(makeAddr("anyDeployer")); // not the RAKE owner
        claim = RescueContractsDeployment.deployClaim();
        patch = VenusMarketRescuePatch(RescueContractsDeployment.deployRescuePatch(address(claim)));
        vm.stopPrank();
    }

    function test_deploy_onlyTheTimelockOpensAndTheSevenUnderlyingsAreInMarketOrder() public view {
        assertEq(claim.VENUS_TIMELOCK(), RakeFrozenPositions.VENUS_NORMAL_TIMELOCK, "opener");
        assertEq(claim.FEE_RECIPIENT(), 0x16c7C45725A977ae6530e8dEE73F6da9aE2e7E07, "fee recipient = RAKE owner");
        assertEq(claim.openedAt(), 0, "must not be open");
        address[7] memory markets = RakeFrozenPositions.vTokens();
        for (uint256 i; i < RakeFrozenPositions.COUNT; ++i) {
            assertEq(claim.tokens(i), IVTokenClaim(markets[i]).underlying(), "token order");
        }
    }

    function test_deploy_claimContractSnapshotsAll103DepositorsCoveringEveryPoolsShares() public view {
        address[] memory wallets = claim.builtInWallets();
        assertEq(wallets.length, 103, "wallet count");
        for (uint256 i; i < RakeFrozenPositions.COUNT; ++i) {
            address t = claim.tokens(i);
            uint256 recorded;
            for (uint256 j; j < wallets.length; ++j) {
                assertTrue(claim.recorded(wallets[j]), "wallet not recorded");
                recorded += claim.snapshot(wallets[j], t);
            }
            assertLe(claim.totalShares(t) - recorded, 10, "a pool has unrecorded shares");
        }
    }

    function test_deploy_thePatchIsBoundToTheClaimTheTreasuryAndTheCurrentImplementation() public view {
        assertEq(patch.OWNER(), address(claim), "claim contract");
        assertEq(patch.TREASURY(), RakeFrozenPositions.VENUS_TREASURY, "treasury");
        address[7] memory markets = RakeFrozenPositions.vTokens();
        address[7] memory strategies = RakeFrozenPositions.strategies();
        for (uint256 i; i < RakeFrozenPositions.COUNT; ++i) {
            assertEq(patch.ORIGINAL_IMPL(), IVTokenImplementation(markets[i]).implementation(), "original implementation");
            assertEq(patch.strategyOf(markets[i]), strategies[i], "strategy");
        }
    }

    function test_deploy_revertsIfAMarketNoLongerRunsTheExpectedImplementation() public {
        address vBusd = RakeFrozenPositions.vTokens()[0];
        vm.mockCall(vBusd, abi.encodeWithSignature("implementation()"), abi.encode(address(0xBEEF)));
        vm.expectRevert("market implementation changed");
        this.deployPatchExternally(address(claim));
    }

    function deployPatchExternally(address c) external returns (address) {
        return RescueContractsDeployment.deployRescuePatch(c);
    }
}
