// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "./RakeDepositorsClaimHarness.sol";

contract ClaimMockToken {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public blocked; // models a token that refuses some recipients

    constructor(uint8 d) {
        decimals = d;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function block_(address who) external {
        blocked[who] = true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        require(!blocked[to], "blocked");
        require(balanceOf[msg.sender] >= a, "insufficient");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// 1:1 vToken: redeem(n) pays n of the underlying and returns Venus's 0 = success code.
contract ClaimMockVToken {
    ClaimMockToken public immutable underlying;
    mapping(address => uint256) public balanceOf;

    constructor(ClaimMockToken u) {
        underlying = u;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        underlying.mint(address(this), a);
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function redeem(uint256 n) external returns (uint256) {
        balanceOf[msg.sender] -= n;
        underlying.transfer(msg.sender, n);
        return 0;
    }
}

contract MockStrat {
    uint256 public sharesTotal;

    function set(uint256 s) external {
        sharesTotal = s;
    }
}

contract MockFarm {
    struct P {
        address want;
        address strat;
    }

    mapping(uint256 => P) public p;
    mapping(uint256 => mapping(address => uint256)) public shares;

    function addPool(uint256 pid, address want, address strat) external {
        p[pid] = P(want, strat);
    }

    function setShares(uint256 pid, address user, uint256 s) external {
        shares[pid][user] = s;
    }

    function poolInfo(uint256 pid) external view returns (address, uint256, uint256, uint256, address) {
        return (p[pid].want, 0, 0, 0, p[pid].strat);
    }

    function userInfo(uint256 pid, address user) external view returns (uint256, uint256) {
        return (shares[pid][user], 0);
    }
}

contract RakeDepositorsClaimTest is Test, IClaimCfg {
    RakeDepositorsClaimHarness c;
    MockFarm farm;
    MockStrat sUsdc;
    MockStrat sBtc;
    ClaimMockToken usdc; // Binance-Peg USDC: 18 decimals on BSC
    ClaimMockToken btc8; // 8-decimal token, to prove decimals don't matter to the split
    ClaimMockToken xvs; // optional extra token, split by each pool's earned-XVS weight
    ClaimMockVToken vUsdc;
    ClaimMockVToken vBtc;
    // the hardcoded RAKE owner is fee recipient (fee and leftovers), whoever deploys
    address feeRecipient = 0x16c7C45725A977ae6530e8dEE73F6da9aE2e7E07;
    address dev = 0x16c7C45725A977ae6530e8dEE73F6da9aE2e7E07;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // Raw farm shares (18-dec, production scale): alice 3/4, bob 1/4 of USDC; alice all of BTC.
    uint256 constant ALICE_USDC = 144_759e18;
    uint256 constant BOB_USDC = 48_253e18;
    uint256 constant ALICE_BTC = 4.265e18;

    uint256[] pids;
    address[] wallets;
    uint256[] xvsWeights;

    function cfgFarm() external view returns (address) {
        return address(farm);
    }

    function cfgPids() external view returns (uint256[] memory) {
        return pids;
    }

    function cfgWallets() external view returns (address[] memory) {
        return wallets;
    }

    function cfgVTokens() external view returns (address[] memory v) {
        v = new address[](2);
        (v[0], v[1]) = (address(vUsdc), address(vBtc));
    }

    function cfgXvs() external view returns (address) {
        return address(xvs);
    }

    function cfgXvsWeights() external view returns (uint256[] memory) {
        return xvsWeights;
    }

    function setUp() public {
        usdc = new ClaimMockToken(18);
        btc8 = new ClaimMockToken(8);
        farm = new MockFarm();
        sUsdc = new MockStrat();
        sBtc = new MockStrat();
        vUsdc = new ClaimMockVToken(usdc);
        vBtc = new ClaimMockVToken(btc8);
        farm.addPool(14, address(usdc), address(sUsdc));
        farm.addPool(10, address(btc8), address(sBtc));
        farm.setShares(14, alice, ALICE_USDC);
        farm.setShares(14, bob, BOB_USDC);
        farm.setShares(10, alice, ALICE_BTC);
        sUsdc.set(ALICE_USDC + BOB_USDC);
        sBtc.set(ALICE_BTC);

        pids = [14, 10];
        xvs = new ClaimMockToken(18);
        xvsWeights = [3, 1]; // the USDC strategy earned 3x the XVS of the BTC one
        c = new RakeDepositorsClaimHarness(); // the RAKE owner is fee recipient
    }

    /// The VIP: captureBefore(), the patch sends the claim its 80% as vTokens, then open()
    /// redeems what arrived and pays 1/8 as the fee. Amounts are the 70% pools.
    function _fundAndOpen(uint256 usdcAmt, uint256 btcAmt) internal {
        vm.prank(c.VENUS_TIMELOCK());
        c.captureBefore();
        vUsdc.mint(address(c), usdcAmt * 8 / 7);
        vBtc.mint(address(c), btcAmt * 8 / 7);
        vm.prank(c.VENUS_TIMELOCK());
        c.open();
    }

    function test_tokensAndStratsReadFromFarm() public view {
        assertEq(c.tokens(0), address(usdc));
        assertEq(c.tokens(1), address(btc8));
        assertEq(c.pidOf(address(btc8)), 10);
        assertEq(c.sharesOf(alice, address(usdc)), ALICE_USDC);
    }

    function test_splitIsProRataOfWhatArrived() public {
        _fundAndOpen(140_000e18, 2.73e8);
        assertEq(vUsdc.balanceOf(address(c)), 0, "vTokens redeemed");
        assertEq(c.pool(address(usdc)), 140_000e18, "pool = 70%");
        assertEq(usdc.balanceOf(c.FEE_RECIPIENT()), 20_000e18, "fee = 10%, in underlying");

        vm.prank(alice);
        c.claim();
        vm.prank(bob);
        c.claim();
        // 140,000 split 3:1 (rounding down at most 1 wei each)
        assertApproxEqAbs(usdc.balanceOf(alice), 105_000e18, 1);
        assertApproxEqAbs(usdc.balanceOf(bob), 35_000e18, 1);
        assertEq(btc8.balanceOf(alice), 2.73e8); // sole BTC holder gets the whole pool
    }

    function test_differentAmountStillSplitsSameRatio() public {
        _fundAndOpen(123_480e18, 1);
        vm.prank(bob);
        c.claim();
        assertApproxEqAbs(usdc.balanceOf(bob), 123_480e18 / 4, 1);
    }

    function test_claimablePreviewMatchesClaim() public {
        _fundAndOpen(140_000e18, 2.73e8);
        uint256 q = c.claimable(alice, address(usdc));
        vm.prank(alice);
        c.claim();
        assertEq(usdc.balanceOf(alice), q);
        assertEq(c.claimable(alice, address(usdc)), 0);
    }

    function test_onlyDepositorsAndOnlyOnce() public {
        _fundAndOpen(140_000e18, 2.73e8);
        vm.prank(alice);
        c.claim();
        vm.prank(alice);
        vm.expectRevert("nothing to claim");
        c.claim();
        assertTrue(c.claimedAll(alice));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("nothing to claim");
        c.claim();
    }

    /// If farm shares ever grew after open, nobody could be paid past the pool.
    function test_sharesGrowingAfterOpenCannotOverpay() public {
        _fundAndOpen(140_000e18, 2.73e8);
        farm.setShares(14, bob, 10 * (ALICE_USDC + BOB_USDC)); // impossible on the real farm
        vm.prank(bob);
        c.claimToken(address(usdc)); // capped to shares == totalShares → at most the whole pool
        assertApproxEqAbs(usdc.balanceOf(bob), 140_000e18, 1);
        vm.prank(alice);
        vm.expectRevert("pool exhausted");
        c.claimToken(address(usdc));
    }

    /// Dust attack: underlying and vTokens sent here before the VIP change neither the pool nor the
    /// fee. open() redeems only the vTokens that arrived after captureBefore() and pools only what
    /// that redeem returned; the dust stays here and goes to the fee recipient at sweep.
    function test_dustIsNotCounted() public {
        usdc.mint(address(c), 1_000e18); // underlying sent directly
        vUsdc.mint(address(c), 5_000e18); // vTokens sent directly, before the VIP
        btc8.mint(address(c), 1);
        _fundAndOpen(140_000e18, 2.73e8);
        assertEq(c.pool(address(usdc)), 140_000e18, "pool = what the rescue's redeem returned, net of fee");
        assertEq(usdc.balanceOf(c.FEE_RECIPIENT()), 20_000e18, "fee = 1/8 of the rescue only");
        assertEq(c.pool(address(btc8)), 2.73e8, "BTC pool ignores the 1 wei");
        assertEq(vUsdc.balanceOf(address(c)), 5_000e18, "pre-VIP vTokens not redeemed");

        vm.prank(alice);
        c.claim();
        vm.prank(bob);
        c.claim();
        assertApproxEqAbs(usdc.balanceOf(alice), 105_000e18, 1);
        assertApproxEqAbs(usdc.balanceOf(bob), 35_000e18, 1);

        vm.warp(c.deadline() + 1);
        c.sweep(address(usdc));
        c.sweep(address(vUsdc));
        assertApproxEqAbs(usdc.balanceOf(feeRecipient) - 20_000e18, 1_000e18, 2, "dust swept");
        assertEq(vUsdc.balanceOf(feeRecipient), 5_000e18, "dust vTokens swept");
    }

    /// A VIP that missed a market reverts at open(), so nothing moves. vTokens sent before the
    /// VIP do not count as a rescue.
    function test_openRevertsIfAMarketWasNotRescued() public {
        vBtc.mint(address(c), 1e8); // before the VIP
        vm.startPrank(c.VENUS_TIMELOCK());
        vm.expectRevert("not captured");
        c.open();
        c.captureBefore();
        vUsdc.mint(address(c), 160_000e18); // only USDC is rescued
        vm.expectRevert("market not rescued");
        c.open();
        vm.stopPrank();
    }

    /// Only the Venus timelock can open: 1 wei of every token does not let anyone start the
    /// window early and fix the pools at dust.
    function test_oneWeiCannotOpenEarly() public {
        usdc.mint(address(c), 1);
        btc8.mint(address(c), 1);
        vm.prank(alice);
        vm.expectRevert("not the Venus timelock");
        c.open();
        vm.expectRevert("not the Venus timelock");
        c.open(); // not the deployer either
        assertEq(c.openedAt(), 0);
    }

    function test_timelockOpensOnce() public {
        _fundAndOpen(140_000e18, 2.73e8);
        vm.prank(c.VENUS_TIMELOCK());
        vm.expectRevert("already open");
        c.open();
    }

    /// Only the Venus timelock can capture the starting balances, once.
    function test_onlyTimelockCaptures_once() public {
        vm.prank(alice);
        vm.expectRevert("not the Venus timelock");
        c.captureBefore();
        _fundAndOpen(140_000e18, 2.73e8);
        vm.prank(c.VENUS_TIMELOCK());
        vm.expectRevert("already captured");
        c.captureBefore();
    }

    function test_oneBlockedTokenDoesNotBlockTheOthers() public {
        _fundAndOpen(140_000e18, 2.73e8);
        btc8.block_(alice);
        vm.prank(alice);
        vm.expectRevert("transfer failed");
        c.claim();
        vm.prank(alice);
        c.claimToken(address(usdc));
        assertApproxEqAbs(usdc.balanceOf(alice), 105_000e18, 1);
        assertFalse(c.claimedAll(alice));
        assertEq(c.claimable(alice, address(btc8)), 2.73e8);
    }

    function test_recordedSharesSurviveAFarmBurn() public {
        address[] memory ws = new address[](2);
        (ws[0], ws[1]) = (alice, bob);
        c.record(ws);
        farm.setShares(14, alice, 0); // a farm withdrawal after the rescue burns her shares
        _fundAndOpen(140_000e18, 2.73e8);
        vm.prank(alice);
        c.claim();
        assertApproxEqAbs(usdc.balanceOf(alice), 105_000e18, 1); // full claim kept
    }

    function test_recordIsOncePerWalletAndCannotBeRaised() public {
        address[] memory ws = new address[](1);
        ws[0] = bob;
        c.record(ws);
        farm.setShares(14, bob, 10 * BOB_USDC); // impossible on the real farm
        c.record(ws); // second record is ignored
        assertEq(c.sharesOf(bob, address(usdc)), BOB_USDC);
    }

    function test_constructorRecordsWallets() public {
        wallets = [alice];
        RakeDepositorsClaimHarness c2 = new RakeDepositorsClaimHarness();
        assertTrue(c2.recorded(alice));
        assertEq(c2.snapshot(alice, address(usdc)), ALICE_USDC);
        assertEq(c2.snapshot(alice, address(btc8)), ALICE_BTC);
    }

    function test_unrecordedWalletFallsBackToLiveShares() public {
        _fundAndOpen(140_000e18, 2.73e8);
        vm.prank(bob);
        c.claim();
        assertApproxEqAbs(usdc.balanceOf(bob), 35_000e18, 1);
    }

    function test_afterDeadlineRemainderToFeeRecipient() public {
        _fundAndOpen(140_000e18, 2.73e8);
        vm.prank(alice);
        c.claim();

        vm.warp(block.timestamp + 90 days);
        vm.expectRevert("window open");
        c.sweep(address(usdc));

        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        vm.expectRevert("window closed");
        c.claim();

        uint256 left = usdc.balanceOf(address(c));
        uint256 b0 = usdc.balanceOf(feeRecipient);
        c.sweep(address(usdc));
        assertEq(usdc.balanceOf(feeRecipient) - b0, left);
        assertApproxEqAbs(left, 35_000e18, 1);
    }

    /// The only clock is open(): before it nothing can be swept, however long after deploy.
    /// Once open, the 90 days count from open(), not from deploy.
    function test_noSweepBeforeOpen_windowCountsFromOpen() public {
        usdc.mint(address(c), 35_000e18);
        vm.warp(block.timestamp + 1_000 days);
        vm.expectRevert("not open");
        c.sweep(address(usdc));
        _fundAndOpen(140_000e18, 2.73e8);
        assertEq(c.deadline(), block.timestamp + 90 days);
        vm.warp(block.timestamp + 90 days);
        vm.expectRevert("window open");
        c.sweep(address(usdc));
        vm.warp(block.timestamp + 1);
        uint256 b0 = usdc.balanceOf(feeRecipient);
        vm.prank(alice);
        c.sweep(address(usdc));
        assertGt(usdc.balanceOf(feeRecipient) - b0, 0);
    }

    /// XVS: pool weight first (3:1), then shares within the pool.
    /// alice = (3 × 3/4 + 1 × 1) / 4 = 81.25%, bob = (3 × 1/4) / 4 = 18.75%.
    function test_xvsSplitByEarnedWeightThenShares() public {
        xvs.mint(address(c), 1_000e18);
        assertApproxEqAbs(c.claimable(alice, address(xvs)), 731.25e18, 1, "preview");
        _fundAndOpen(140_000e18, 2.73e8);
        assertEq(xvs.balanceOf(dev), 100e18, "fee on XVS");
        assertEq(c.pool(address(xvs)), 900e18);

        vm.prank(alice);
        c.claim();
        assertFalse(c.claimedAll(bob));
        vm.prank(bob);
        c.claim();
        assertApproxEqAbs(xvs.balanceOf(alice), 731.25e18, 1);
        assertApproxEqAbs(xvs.balanceOf(bob), 168.75e18, 1);
        assertTrue(c.claimedAll(alice) && c.claimedAll(bob));
        assertLe(c.paidOut(address(xvs)), c.pool(address(xvs)));
    }

    /// No XVS arriving changes nothing: open works, nobody is owed XVS.
    function test_noXvsChangesNothing() public {
        _fundAndOpen(140_000e18, 2.73e8);
        assertEq(c.pool(address(xvs)), 0);
        assertEq(c.claimable(alice, address(xvs)), 0);
        vm.prank(alice);
        c.claim();
        assertTrue(c.claimedAll(alice));
        vm.prank(alice);
        vm.expectRevert("nothing to claim");
        c.claimToken(address(xvs));
    }

    /// XVS stays open: it can arrive after open, in several transfers, and is claimable each time.
    function test_xvsArrivingAfterOpenIsStillClaimable() public {
        _fundAndOpen(140_000e18, 2.73e8);
        vm.prank(alice);
        c.claim();
        assertTrue(c.claimedAll(alice));

        xvs.mint(address(c), 1_000e18); // first XVS transfer, after open
        assertFalse(c.claimedAll(alice));
        assertApproxEqAbs(c.claimable(alice, address(xvs)), 731.25e18, 1, "preview");
        vm.prank(alice);
        c.claim();
        assertApproxEqAbs(xvs.balanceOf(alice), 731.25e18, 1);
        assertEq(xvs.balanceOf(dev), 100e18, "fee once");

        xvs.mint(address(c), 1_000e18); // second transfer
        vm.prank(alice);
        c.claimToken(address(xvs));
        assertApproxEqAbs(xvs.balanceOf(alice), 1_462.5e18, 2);
        vm.prank(bob);
        c.claim();
        assertApproxEqAbs(xvs.balanceOf(bob), 337.5e18, 2);
        assertEq(xvs.balanceOf(dev), 200e18, "each arrival fee'd once");
        assertLe(c.paidOut(address(xvs)), c.pool(address(xvs)));

        vm.prank(alice);
        vm.expectRevert("nothing to claim");
        c.claimToken(address(xvs));
    }

    /// A VIP that lands long after deploy still opens: nothing was swept in the meantime.
    function test_lateFundingStillOpens() public {
        vm.warp(block.timestamp + 200 days);
        _fundAndOpen(140_000e18, 2.73e8);
        vm.prank(alice);
        c.claim();
        assertGt(usdc.balanceOf(alice), 0);
    }

    /// After the window, claimable() reads 0 for every token, and the XVS view does not revert
    /// once XVS has been swept.
    function test_claimableZeroAfterWindowAndSweep() public {
        xvs.mint(address(c), 1_000e18);
        _fundAndOpen(140_000e18, 2.73e8);
        assertGt(c.claimable(alice, address(usdc)), 0);
        vm.warp(c.deadline() + 1);
        assertEq(c.claimable(alice, address(usdc)), 0);
        assertEq(c.claimable(alice, address(xvs)), 0);
        c.sweep(address(xvs));
        assertEq(c.claimable(alice, address(xvs)), 0);
        assertFalse(c.claimedAll(alice));
    }
}
