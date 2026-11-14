// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "./Interfaces.sol";
import "../src/VenusMarketRescuePatch.sol";
import "../src/RakeDepositorsClaim.sol";
import "../src/libraries/RescueContractsDeployment.sol";
import "../src/libraries/VenusRescueProposalCommands.sol";

interface IAccrueS {
    function accrueInterest() external returns (uint256);
}

interface IMarketS {
    function exchangeRateStored() external view returns (uint256);
    function getCash() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function borrowIndex() external view returns (uint256);
    function mint(uint256) external returns (uint256);
}

interface IComptrollerS {
    function claimVenus(address holder, address[] calldata vTokens) external;
    function oracle() external view returns (address);
}

interface IOracleS {
    function getUnderlyingPrice(address vToken) external view returns (uint256);
}

interface IRateS {
    function supplyRatePerBlock() external view returns (uint256);
}

/// Simulates script/live/VenusRescueProposal.s.sol on a BSC fork: the contracts are deployed exactly as
/// script/live/Deploy.s.sol deploys them, then every command of the
/// proposal (VenusRescueProposalCommands.build, the very list the script prints) is sent from the
/// Venus Normal Timelock, byte-for-byte as Venus would submit it: 25 commands (26 with the optional
/// XVS grant). The first, patch.preflight(), checks the live markets; the last, claim.open(),
/// redeems, takes the 10% fee and opens the window.
contract VenusRescueProposalTest is Test {
    using VenusRescueProposalCommands for VenusRescueProposalCommands.Command;

    address constant TIMELOCK = RakeFrozenPositions.VENUS_NORMAL_TIMELOCK;
    address constant TREASURY = RakeFrozenPositions.VENUS_TREASURY;
    address constant COMPTROLLER = RakeFrozenPositions.VENUS_COMPTROLLER;
    address constant XVS = RakeFrozenPositions.XVS;
    uint256 constant GRANT = RakeFrozenPositions.XVS_GRANT;

    RakeDepositorsClaim claim;
    address patch;
    address FEE_TO; // the claim's fee recipient = the hardcoded RAKE owner (fee and leftovers)

    function setUp() public {
        // Pin FORK_BLOCK to reuse foundry's RPC cache across tests and runs.
        uint256 b = vm.envOr("FORK_BLOCK", uint256(0));
        string memory rpc = vm.envOr("BSC_RPC_URL", string("https://bsc-rpc.publicnode.com"));
        if (b == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, b);
        claim = RescueContractsDeployment.deployClaim(); // the RAKE owner is fee recipient
        FEE_TO = claim.FEE_RECIPIENT();
        patch = RescueContractsDeployment.deployRescuePatch(address(claim));
    }

    function _markets() internal pure returns (address[7] memory) {
        return RakeFrozenPositions.vTokens();
    }

    function _commands(uint256 grant) internal view returns (VenusRescueProposalCommands.Command[] memory) {
        return VenusRescueProposalCommands.build(address(claim), patch, grant > 0);
    }

    function _vip(uint256 grant) internal {
        _run(_commands(grant));
    }

    function _run(VenusRescueProposalCommands.Command[] memory c) internal {
        vm.startPrank(TIMELOCK);
        VenusRescueProposalCommands.execute(c);
        vm.stopPrank();
    }

    /// Sends one proposal command from the Timelock, as Timelock.executeTransaction does.
    function _send(VenusRescueProposalCommands.Command memory c) internal {
        vm.prank(TIMELOCK);
        (bool ok, bytes memory ret) = c.target.call(c.callData());
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// The VIP split in two: every command but the last, and the last (claim.open()).
    function _rescueThenOpen()
        internal
        view
        returns (VenusRescueProposalCommands.Command[] memory rescue, VenusRescueProposalCommands.Command[] memory openCmd)
    {
        VenusRescueProposalCommands.Command[] memory c = _commands(0);
        rescue = new VenusRescueProposalCommands.Command[](c.length - 1);
        for (uint256 i; i < rescue.length; ++i) rescue[i] = c[i];
        openCmd = new VenusRescueProposalCommands.Command[](1);
        openCmd[0] = c[c.length - 1];
    }

    /// Markets, strategies and the patch line up with the claim contract and with Venus.
    function test_patchAndMarketsMatch() public view {
        address[7] memory m = _markets();
        address[7] memory s = RakeFrozenPositions.strategies();
        assertEq(FEE_TO, 0x16c7C45725A977ae6530e8dEE73F6da9aE2e7E07);
                for (uint256 i; i < 7; ++i) {
            assertEq(IVToken(m[i]).admin(), TIMELOCK, "admin");
            assertEq(claim.vTokenOf(claim.tokens(i)), m[i], "market");
            assertEq(IVToken(m[i]).underlying(), claim.tokens(i), "token order");
            VenusMarketRescuePatch p = VenusMarketRescuePatch(patch);
            assertEq(p.strategyOf(m[i]), s[i], "strategy");
            assertEq(p.OWNER(), address(claim), "owner");
            assertEq(p.ORIGINAL_IMPL(), IVToken(m[i]).implementation(), "impl");
        }
        assertEq(_commands(0).length, 25);
        assertEq(_commands(GRANT).length, 26);
        assertEq(_commands(0)[0].target, patch, "first command is the preflight");
        assertEq(_commands(0)[1].target, address(claim), "second command captures the claim's balances");
        assertEq(_commands(0)[24].target, address(claim), "last command opens the claim");
        assertEq(_commands(GRANT)[25].target, address(claim), "open stays last after the XVS grant");
    }

    /// The VIP splits every market's net vTokens 20% Venus / 80% claim, then in the same
    /// transaction claim.open() redeems exactly the 80% that arrived (balance now − captureBefore) to underlying, pays 1/8 of it
    /// (10% of the net) as the fee and pools the rest: Venus 20% in vTokens, fee 10% and
    /// depositors 70% in underlying.
    function test_vip_splits_20_10_70_andOpens() public {
        address[7] memory m = _markets();
        (VenusRescueProposalCommands.Command[] memory rescue, VenusRescueProposalCommands.Command[] memory openCmd) =
            _rescueThenOpen();
        uint256[7] memory t0;
        uint256[7] memory f0;
        for (uint256 i; i < 7; ++i) {
            t0[i] = IERC20(m[i]).balanceOf(TREASURY);
            f0[i] = IERC20(claim.tokens(i)).balanceOf(FEE_TO);
        }

        _run(rescue);
        for (uint256 i; i < 7; ++i) {
            uint256 toVenus = IERC20(m[i]).balanceOf(TREASURY) - t0[i];
            uint256 toClaim = IERC20(m[i]).balanceOf(address(claim));
            assertGt(toClaim, 0, "claim got nothing");
            assertEq(toVenus, (toVenus + toClaim) * 2_000 / 10_000, "Venus != 20%");
            assertEq(IVToken(m[i]).implementation(), VenusMarketRescuePatch(patch).ORIGINAL_IMPL(), "not restored");
            console.log("market", m[i]);
            console.log("   vTokens: Venus 20%", toVenus, " claim 80%", toClaim);
        }

        _run(openCmd); // same transaction in the real VIP
        for (uint256 i; i < 7; ++i) {
            address u = claim.tokens(i);
            assertEq(IERC20(m[i]).balanceOf(address(claim)), 0, "vTokens not redeemed");
            uint256 kept = IERC20(u).balanceOf(address(claim));
            uint256 fee = IERC20(u).balanceOf(FEE_TO) - f0[i];
            assertGt(kept, 0, "nothing redeemed");
            assertEq(fee, (kept + fee) * 1_250 / 10_000, "fee != 10% of the net");
            assertEq(claim.pool(u), kept, "pool != what the redeem returned, net of fee");
            assertGt(claim.rescued(m[i]), 0, "nothing arrived in the VIP");
            console.log("   underlying: fee 10%", fee, " depositors 70%", kept);
        }
        assertEq(claim.openedAt(), block.timestamp, "the VIP's open() starts the window");
    }

    /// USD value of the claim's 80% held as vTokens vs unwrapped to underlying in the VIP, priced by
    /// the Venus oracle. Also logs what the vTokens would have earned over the 90-day window.
    function test_value_vTokensVsUnderlying() public {
        (VenusRescueProposalCommands.Command[] memory rescue, VenusRescueProposalCommands.Command[] memory openCmd) =
            _rescueThenOpen();
        uint256[7] memory f0;
        for (uint256 i; i < 7; ++i) f0[i] = IERC20(claim.tokens(i)).balanceOf(FEE_TO);

        _run(rescue);
        (uint256[7] memory vUsd, uint256 growthUsd) = _claimVTokensUsd();

        _run(openCmd); // same transaction in the real VIP
        uint256 vTotal;
        uint256 uTotal;
        for (uint256 i; i < 7; ++i) {
            uint256 uUsd = _claimUnderlyingUsd(i, f0[i]);
            vTotal += vUsd[i];
            uTotal += uUsd;
            console.log("market", _markets()[i]);
            console.log("   USD as vTokens   ", vUsd[i] / 1e18, " as underlying", uUsd / 1e18);
            console.log("   lost by unwrapping (USD wei)", vUsd[i] - uUsd);
            assertApproxEqAbs(uUsd, vUsd[i], 1e15, "unwrapping lost more than $0.001");
        }
        console.log("TOTAL USD as vTokens   ", vTotal / 1e18);
        console.log("TOTAL USD as underlying", uTotal / 1e18);
        console.log("vTokens would earn over 90 days (USD, at today's supply rates)", growthUsd / 1e18);
    }

    /// The claim's vTokens in USD (1e18) per market, and what they would earn over 90 days.
    function _claimVTokensUsd() internal view returns (uint256[7] memory usd, uint256 growth) {
        address[7] memory m = _markets();
        IOracleS oracle = IOracleS(IComptrollerS(COMPTROLLER).oracle());
        uint256 blocks90 = uint256(90 days) * 1e6 / 450_209; // BSC: 1M blocks per 450,209 s, measured at block 132,814,066
        for (uint256 i; i < 7; ++i) {
            // all seven underlyings have 18 decimals, so the oracle price is USD * 1e18 per token
            uint256 underlying = IERC20(m[i]).balanceOf(address(claim)) * IMarketS(m[i]).exchangeRateStored() / 1e18;
            usd[i] = underlying * oracle.getUnderlyingPrice(m[i]) / 1e18;
            growth += usd[i] * IRateS(m[i]).supplyRatePerBlock() * blocks90 / 1e18;
        }
    }

    /// Underlying the redeem produced for market i (kept + fee) in USD (1e18).
    function _claimUnderlyingUsd(uint256 i, uint256 feeBefore) internal view returns (uint256) {
        address u = claim.tokens(i);
        uint256 got = IERC20(u).balanceOf(address(claim)) + IERC20(u).balanceOf(FEE_TO) - feeBefore;
        return got * IOracleS(IComptrollerS(COMPTROLLER).oracle()).getUnderlyingPrice(_markets()[i]) / 1e18;
    }

    function test_onlyTimelockOpens_once() public {
        vm.prank(makeAddr("anyone"));
        vm.expectRevert("not the Venus timelock");
        claim.open();
        vm.expectRevert("not the Venus timelock");
        claim.open(); // not the deployer either
        _vip(0);
        vm.prank(TIMELOCK);
        vm.expectRevert("already open");
        claim.open();
    }

    function test_open_revertsBeforeTheVip() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert("not captured");
        claim.open();
        claim.captureBefore();
        vm.expectRevert("market not rescued"); // captured, but no rescue ran
        claim.open();
        vm.stopPrank();
    }

    /// Dust attack on live BSC: underlying and vTokens sent to the claim before the VIP change
    /// neither the pool nor the fee; they stay here for the sweep to the fee recipient.
    function test_dustBeforeVip_notCounted() public {
        address usdc = claim.tokens(5);
        address vUsdc = _markets()[5];
        deal(usdc, address(claim), 1_000e18);
        deal(usdc, address(this), 2_000e18);
        IERC20(usdc).approve(vUsdc, 2_000e18);
        assertEq(IMarketS(vUsdc).mint(2_000e18), 0, "mint");
        uint256 vDust = IERC20(vUsdc).balanceOf(address(this));
        IERC20(vUsdc).transfer(address(claim), vDust);
        uint256 f0 = IERC20(usdc).balanceOf(FEE_TO);

        _vip(0);
        uint256 fee = IERC20(usdc).balanceOf(FEE_TO) - f0;
        assertEq(claim.pool(usdc), IERC20(usdc).balanceOf(address(claim)) - 1_000e18, "dust in the pool");
        assertEq(fee, (claim.pool(usdc) + fee) * 1_250 / 10_000, "fee includes dust");
        assertEq(IERC20(vUsdc).balanceOf(address(claim)), vDust, "dust vTokens were redeemed");
    }

    /// XVS each payee collects right after the VIP + open, on the seven markets.
    function _xvsCollected() internal returns (uint256 total) {
        address[7] memory m = _markets();
        address[] memory list = new address[](7);
        for (uint256 i; i < 7; ++i) list[i] = m[i];
        address[2] memory who = [address(claim), TREASURY];
        for (uint256 k; k < 2; ++k) {
            uint256 b = IERC20(XVS).balanceOf(who[k]);
            IComptrollerS(COMPTROLLER).claimVenus(who[k], list);
            total += IERC20(XVS).balanceOf(who[k]) - b;
        }
    }

    /// With the settle (command 2) the two vToken payees collect ~no XVS for the moved vTokens.
    function test_xvsSettle_noOverCredit() public {
        _vip(0);
        uint256 got = _xvsCollected();
        emit log_named_decimal_uint("XVS collected WITH settle", got, 18);
        assertLt(got, 1e18, "settle should leave ~0 XVS");
    }

    /// Without the settle (command 2) the moved vTokens collect back-dated XVS: why it is there.
    function test_withoutSettle_overCredits() public {
        VenusRescueProposalCommands.Command[] memory a = _commands(0);
        a[2] = a[0]; // drop the settle: run the read-only preflight again in its place
        _run(a);
        uint256 got = _xvsCollected();
        emit log_named_decimal_uint("XVS collected WITHOUT settle (over-credit)", got, 18);
        assertGt(got, 1_000e18, "expected a windfall without settle");
    }

    /// Optional grant: the strategies' earned XVS reaches the claim; 10% fee, 90% pool.
    function test_optionalXvsGrant() public {
        uint256 f0 = IERC20(XVS).balanceOf(FEE_TO);
        _vip(GRANT);
        uint256 fee = IERC20(XVS).balanceOf(FEE_TO) - f0;
        assertEq(claim.pool(XVS) + fee, GRANT);
        assertEq(fee, GRANT / 10, "XVS fee != 10%");
    }

    /// The whole VIP as one external call, so expectRevert sees the VIP's own revert.
    function runAsTimelock(VenusRescueProposalCommands.Command[] memory c) external {
        _run(c);
    }

    /// preflight() (command 0) stops the whole VIP if Venus upgraded a market's implementation.
    function test_preflight_implementationChanged() public {
        vm.mockCall(_markets()[3], abi.encodeWithSignature("implementation()"), abi.encode(address(0xBEEF)));
        VenusRescueProposalCommands.Command[] memory c = _commands(GRANT);
        vm.expectRevert("market implementation changed");
        this.runAsTimelock(c);
    }

    /// preflight() stops the VIP if Venus moved its treasury, so the 20% cannot go to an old address.
    function test_preflight_treasuryChanged() public {
        vm.mockCall(COMPTROLLER, abi.encodeWithSignature("treasuryAddress()"), abi.encode(address(0xBEEF)));
        VenusRescueProposalCommands.Command[] memory c = _commands(GRANT);
        vm.expectRevert("treasury changed");
        this.runAsTimelock(c);
    }

    /// preflight() stops the VIP if a strategy entered another market (its vTokens would then back
    /// a borrow elsewhere); on live state each is in its own market only.
    function test_preflight_strategyInAnotherMarket() public {
        VenusMarketRescuePatch(patch).preflight(); // live state passes
        address[] memory two = new address[](2);
        two[0] = _markets()[0];
        two[1] = _markets()[1];
        vm.mockCall(
            COMPTROLLER,
            abi.encodeWithSignature("getAssetsIn(address)", RakeFrozenPositions.strategies()[0]),
            abi.encode(two)
        );
        VenusRescueProposalCommands.Command[] memory c = _commands(GRANT);
        vm.expectRevert("strategy in another market");
        this.runAsTimelock(c);
    }

    /// A market whose redeem fails (here: reverts, as on too little cash) does not block the VIP:
    /// open() pools that market in vTokens (10% fee in vTokens too), the other six redeem, and a
    /// depositor's claim pays vTokens for it.
    function test_open_redeemFails_paysVTokens() public {
        address vEth = _markets()[2];
        address eth = claim.tokens(2);
        vm.mockCallRevert(vEth, abi.encodeWithSignature("redeem(uint256)"), "redeem: insufficient cash");
        uint256 f0 = IERC20(vEth).balanceOf(FEE_TO);
        _vip(GRANT);

        assertTrue(claim.paidInVTokens(eth), "not flagged");
        assertEq(claim.payoutToken(eth), vEth);
        uint256 got = claim.rescued(vEth);
        uint256 fee = IERC20(vEth).balanceOf(FEE_TO) - f0;
        assertEq(fee, got * 1_250 / 10_000, "vToken fee != 10% of the net");
        assertEq(claim.pool(eth), got - fee, "pool != vTokens less fee");
        assertEq(IERC20(vEth).balanceOf(address(claim)), claim.pool(eth));
        for (uint256 i; i < 7; ++i) {
            if (i == 2) continue;
            assertFalse(claim.paidInVTokens(claim.tokens(i)), "other market not redeemed");
            assertEq(IERC20(_markets()[i]).balanceOf(address(claim)), 0, "other market not redeemed");
        }

        address[] memory ws = claim.builtInWallets();
        address w;
        for (uint256 k; k < ws.length && w == address(0); ++k) {
            if (claim.claimable(ws[k], eth) > 0) w = ws[k];
        }
        uint256 want = claim.claimable(w, eth);
        vm.prank(w);
        claim.claimToken(eth);
        assertEq(IERC20(vEth).balanceOf(w), want, "claim did not pay vTokens");
    }

    /// A fee transfer that fails (fee recipient blocked by USDT, and by XVS) blocks neither open()
    /// nor claims: the fee waits as feeDue, is not re-counted into the XVS pool, and withdrawFee
    /// sends it once the transfer works.
    function test_feeTransferFails_doesNotBlock() public {
        address usdt = claim.tokens(4);
        bytes4 transfer = IERC20.transfer.selector;
        vm.mockCallRevert(usdt, abi.encodeWithSelector(transfer, FEE_TO), "blocked");
        vm.mockCallRevert(XVS, abi.encodeWithSelector(transfer, FEE_TO), "blocked");
        _vip(GRANT);

        uint256 dueUsdt = claim.feeDue(usdt);
        uint256 dueXvs = claim.feeDue(XVS);
        assertEq(dueUsdt, (claim.pool(usdt) + dueUsdt) * 1_250 / 10_000, "USDT fee not kept");
        assertEq(dueXvs, GRANT / 10, "XVS fee not kept");
        assertEq(claim.pool(XVS) + dueXvs, GRANT, "XVS pool");

        address[] memory ws = claim.builtInWallets();
        address w;
        for (uint256 k; k < ws.length && w == address(0); ++k) {
            if (claim.claimable(ws[k], XVS) > 0) w = ws[k];
        }
        vm.prank(w);
        claim.claim();
        assertEq(claim.pool(XVS) + dueXvs, GRANT, "kept XVS fee re-counted as arrived");

        vm.clearMockedCalls();
        uint256 b0 = IERC20(usdt).balanceOf(FEE_TO);
        claim.withdrawFee(usdt);
        assertEq(IERC20(usdt).balanceOf(FEE_TO) - b0, dueUsdt);
        b0 = IERC20(XVS).balanceOf(FEE_TO);
        claim.withdrawFee(XVS);
        assertEq(IERC20(XVS).balanceOf(FEE_TO) - b0, dueXvs);
        assertEq(claim.feeDue(XVS), 0);
    }

    /// VenusMarketRescuePatch accepts only the market's live admin: here the call comes from this test, not the Timelock.
    function test_patch_onlyMarketAdmin() public {
        VenusRescueProposalCommands.Command[] memory all = _commands(0);
        VenusRescueProposalCommands.Command[] memory a = new VenusRescueProposalCommands.Command[](1);
        a[0] = all[VenusRescueProposalCommands.SETUP_COMMANDS + 3]; // vBTC → the patch
        _run(a);
        vm.expectRevert("only admin");
        VenusMarketRescuePatch(_markets()[1]).settleAndRescue();
    }

    /// Other suppliers lose nothing: the VIP leaves every market's exchange rate (up to one-wei
    /// rounding, upward), reserves and borrow index unchanged; cash falls by exactly the claim's
    /// ordinary redeem; open() keeps the rate.
    function test_otherSuppliersUnchanged() public {
        address[7] memory m = _markets();
        uint256[7] memory er0;
        uint256[7] memory cash0;
        uint256[7] memory res0;
        uint256[7] memory bi0;
        uint256[7] memory fu0;
        for (uint256 i; i < 7; ++i) {
            fu0[i] = IERC20(claim.tokens(i)).balanceOf(FEE_TO);
            IAccrueS(m[i]).accrueInterest(); // same block as the VIP, so its own accrual is a no-op
            IMarketS mk = IMarketS(m[i]);
            (er0[i], cash0[i], res0[i], bi0[i]) =
                (mk.exchangeRateStored(), mk.getCash(), mk.totalReserves(), mk.borrowIndex());
        }

        _vip(0);

        for (uint256 i; i < 7; ++i) {
            IMarketS mk = IMarketS(m[i]);
            assertGe(mk.exchangeRateStored(), er0[i], "exchange rate fell");
            assertLe((mk.exchangeRateStored() - er0[i]) * 1e18 / er0[i], 1e6, "exchange rate moved more than dust");
            address u = claim.tokens(i);
            uint256 redeemed = IERC20(u).balanceOf(address(claim)) + IERC20(u).balanceOf(FEE_TO) - fu0[i];
            assertEq(cash0[i] - mk.getCash(), redeemed, "cash moved by more than the claim's redeem");
            assertEq(mk.totalReserves(), res0[i], "reserves changed");
            assertEq(mk.borrowIndex(), bi0[i], "borrow index changed");
        }

        for (uint256 i; i < 7; ++i) {
            assertGe(IMarketS(m[i]).exchangeRateStored(), er0[i], "exchange rate fell after open");
        }
    }

    /// Item 8: other suppliers lose nothing. For every market: a separate supplier deposits
    /// first; the rescue (same block) leaves exchange rate, cash, reserves and borrow index
    /// unchanged and the supplier's balance untouched; after the claim contract redeems, the supplier still
    /// redeems at least what they put in.
    function test_proposal_otherVenusSuppliersLoseNothing() public {
        address[7] memory m = _markets();
        address other = makeAddr("otherSupplier");
        uint256[7] memory er0;
        uint256[7] memory bal0;
        uint256[7] memory value0;
        bool[7] memory minted;

        for (uint256 i; i < 7; ++i) {
            IAccrueS(m[i]).accrueInterest();
            address u = IVToken(m[i]).underlying();
            uint256 amt = 1_000 * 10 ** 18 / (i == 1 ? 100_000 : i == 2 ? 3_000 : 1); // ~$1k each
            deal(u, other, amt);
            vm.startPrank(other);
            IERC20(u).approve(m[i], amt);
            // Some deprecated markets have mint paused; those are checked on market state only.
            try IMarketS(m[i]).mint(amt) returns (uint256 err) {
                minted[i] = err == 0 && IVToken(m[i]).balanceOf(other) > 0;
            } catch {}
            vm.stopPrank();
            bal0[i] = IVToken(m[i]).balanceOf(other);
            value0[i] = bal0[i] * IMarketS(m[i]).exchangeRateStored() / 1e18;
        }

        VenusRescueProposalCommands.Command[] memory c = _commands(0);
        uint256 k;
        for (; k < VenusRescueProposalCommands.SETUP_COMMANDS; ++k) _send(c[k]);
        for (uint256 i; i < 7; ++i) {
            IMarketS mk = IMarketS(m[i]);
            IVToken v = IVToken(m[i]);
            IAccrueS(m[i]).accrueInterest(); // same block: the patch's own accrual is then a no-op
            er0[i] = mk.exchangeRateStored();
            uint256 cash0 = mk.getCash();
            uint256 res0 = mk.totalReserves();
            uint256 bi0 = mk.borrowIndex();

            _send(c[k++]); // _setImplementation(patch)
            _send(c[k++]); // settleAndRescue()
            _send(c[k++]); // _setImplementation(original)

            assertGe(mk.exchangeRateStored(), er0[i], "exchange rate fell");
            // Only the rounded-UP burn can move it, by one vToken unit: < 1e-12 relative.
            assertLe((mk.exchangeRateStored() - er0[i]) * 1e18 / er0[i], 1e6, "exchange rate moved more than dust");
            assertEq(mk.getCash(), cash0, "cash changed");
            assertEq(mk.totalReserves(), res0, "reserves changed");
            assertEq(mk.borrowIndex(), bi0, "borrow index changed");
            assertEq(v.balanceOf(other), bal0[i], "other supplier balance changed");
            emit log_named_uint(string.concat("market ", vm.toString(i), " other supplier minted (1=yes)"), minted[i] ? 1 : 0);
        }

        _send(c[k++]); // claim.open(): the claim redeems its 80% through the ordinary path
        assertEq(k, c.length, "all VIP commands sent");

        for (uint256 i; i < 7; ++i) {
            assertGe(IMarketS(m[i]).exchangeRateStored(), er0[i], "exchange rate fell after redeem");
            if (!minted[i]) continue;
            address u = IVToken(m[i]).underlying();
            uint256 b = IERC20(u).balanceOf(other);
            vm.prank(other);
            assertEq(IVToken(m[i]).redeem(bal0[i]), 0, "other supplier cannot redeem");
            assertGe(IERC20(u).balanceOf(other) - b + 1, value0[i], "other supplier got back less");
        }
    }

    /// Full chain: VIP with the XVS grant (it opens the claim) → every one of the 103 wallets claims
    /// exactly pool × shares ÷ total → pools empty to dust → after the window the dust sweeps.
    function test_fullChain_all103Claim() public {
        _vip(GRANT);

        uint256 n = claim.tokenCount();
        address[] memory toks = new address[](n + 1);
        for (uint256 i; i < n; ++i) toks[i] = claim.tokens(i);
        toks[n] = XVS;

        address[] memory ws = claim.builtInWallets();
        assertEq(ws.length, 103);
        for (uint256 k; k < ws.length; ++k) {
            address w = ws[k];
            uint256[] memory want = new uint256[](n + 1);
            uint256[] memory b0 = new uint256[](n + 1);
            bool any;
            for (uint256 i; i <= n; ++i) {
                want[i] = claim.claimable(w, toks[i]);
                b0[i] = IERC20(toks[i]).balanceOf(w);
                if (want[i] > 0) any = true;
            }
            for (uint256 i; i < n; ++i) {
                assertEq(want[i], claim.pool(toks[i]) * claim.sharesOf(w, toks[i]) / claim.totalShares(toks[i]));
            }
            if (!any) {
                // Shares so small every cut rounds to 0 (< 1 wei of each token): nothing to pay.
                assertTrue(claim.claimedAll(w), "dust wallet not done");
                continue;
            }
            vm.prank(w);
            claim.claim();
            console.log("claimed", k, w);
            assertTrue(claim.claimedAll(w), "not fully claimed");
            for (uint256 i; i <= n; ++i) {
                assertEq(IERC20(toks[i]).balanceOf(w) - b0[i], want[i], "paid != claimable");
            }
        }

        for (uint256 i; i <= n; ++i) {
            uint256 left = IERC20(toks[i]).balanceOf(address(claim));
            assertEq(left, claim.pool(toks[i]) - claim.paidOut(toks[i]), "balance != unpaid");
            assertLe(left, ws.length, "more than dust left");
        }

        vm.warp(claim.deadline() + 1);
        for (uint256 i; i <= n; ++i) {
            uint256 left = IERC20(toks[i]).balanceOf(address(claim));
            if (left == 0) continue;
            uint256 b0 = IERC20(toks[i]).balanceOf(FEE_TO);
            claim.sweep(toks[i]);
            assertEq(IERC20(toks[i]).balanceOf(FEE_TO) - b0, left, "sweep");
        }
    }

    /// While the claim still holds vTokens the site's preview prices them at the stored exchange
    /// rate less the 10% fee; after open() the figure is exact and they agree.
    function test_claimable_previewBeforeOpenMatchesAfter() public {
        (VenusRescueProposalCommands.Command[] memory rescue, VenusRescueProposalCommands.Command[] memory openCmd) =
            _rescueThenOpen();
        _run(rescue);
        address w = claim.builtInWallets()[0];
        address t = claim.tokens(0);
        uint256 preview = claim.claimable(w, t);
        _run(openCmd);
        assertApproxEqRel(claim.claimable(w, t), preview, 1e12, "pre-open preview off");
        console.log("preview", preview, "after open", claim.claimable(w, t));
    }

    /// Before the VIP nothing can be swept, however long after deploy: the only clock is open().
    function test_noSweepBeforeVip() public {
        address v = _markets()[0];
        address t = claim.tokens(0);
        vm.warp(block.timestamp + 1_000 days);
        vm.expectRevert("not open");
        claim.sweep(v);
        vm.expectRevert("not open");
        claim.sweep(t);
    }

    /// A VIP long after deploy: the window starts when the VIP opens it, not at deploy.
    function test_lateVip_windowStartsAtOpen() public {
        vm.warp(block.timestamp + 200 days);
        _vip(0);
        assertEq(claim.deadline(), block.timestamp + 90 days);
        address usdc = claim.tokens(5);
        vm.expectRevert("window open");
        claim.sweep(usdc);
    }
}
