// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../../src/libraries/RescueContractsDeployment.sol";
import "../../src/libraries/VenusRescueProposalCommands.sol";

interface IVTokenSim {
    function balanceOf(address) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function underlying() external view returns (address);
}

interface IERC20Sim {
    function balanceOf(address) external view returns (uint256);
}

/// The whole rescue on a BSC fork, real actions in order, for anyone (Venus included) to run.
/// Sends nothing, needs no key and no addresses.json:
///   1. a RANDOM wallet runs the Deploy script's steps (claim contract + the one rescue patch);
///   2. the Venus Normal Timelock sends every proposal command exactly as
///      Timelock.executeTransaction would, each one logged (the last, claim.open(), redeems, takes
///      the 10% fee and opens the window);
///   3. checks where every token went: Venus treasury, fee to the hardcoded RAKE owner, 70% pooled
///      for depositors, nothing to the random deployer;
///   4. all 103 depositors claim from their own wallets, each paid exactly its share;
///   5. after 90 days a random wallet sweeps: the dust goes to the RAKE owner, not the caller.
/// Saves the propose() arrays to out/vip-proposal.json.
///
///   forge script script/simulation/SimulateVIP.s.sol --fork-url $BSC_RPC_URL
contract SimulateVIP is Script {
    using VenusRescueProposalCommands for VenusRescueProposalCommands.Command;

    function run() external {
        address[7] memory markets = RakeFrozenPositions.vTokens();
        string[7] memory symbols = RakeFrozenPositions.symbols();
        address treasury = RakeFrozenPositions.VENUS_TREASURY;
        console.log(string.concat("BSC block ", vm.toString(block.number), " (fork, nothing is sent)"));

        // ── 1. a random wallet deploys ──
        address deployer = _randomWallet("deployer");
        console.log("");
        console.log("1. DEPLOY from a random wallet", deployer);
        vm.startPrank(deployer);
        RakeDepositorsClaim claim = RescueContractsDeployment.deployClaim();
        address patch = RescueContractsDeployment.deployRescuePatch(address(claim));
        vm.stopPrank();
        address feeTo = claim.FEE_RECIPIENT();
        console.log("   claim contract          ", address(claim));
        console.log("   rescue patch            ", patch);
        console.log("   fee recipient           ", feeTo);
        _check(feeTo == 0x16c7C45725A977ae6530e8dEE73F6da9aE2e7E07 && feeTo != deployer,
            "fee recipient is the RAKE owner, not the deployer");

        uint256[7] memory t0;
        uint256[7] memory f0;
        for (uint256 i; i < 7; ++i) {
            t0[i] = IVTokenSim(markets[i]).balanceOf(treasury);
            f0[i] = IERC20Sim(IVTokenSim(markets[i]).underlying()).balanceOf(feeTo);
        }

        // ── 2. the VIP, every command from the Venus Timelock ──
        VenusRescueProposalCommands.Command[] memory c =
            VenusRescueProposalCommands.build(address(claim), patch, true);
        console.log("");
        console.log(string.concat("2. VIP: ", vm.toString(c.length), " commands, each sent by the Venus Timelock ",
            vm.toString(RakeFrozenPositions.VENUS_NORMAL_TIMELOCK)));
        uint256 gasTotal;
        uint256[3] memory b; // balances read before the patch goes in, logged after the restore
        for (uint256 i; i < c.length; ++i) {
            bytes32 sig = keccak256(bytes(c[i].signature));
            if (i + 1 < c.length && keccak256(bytes(c[i + 1].signature)) == keccak256("settleAndRescue()")) {
                b = _vBalances(c[i].target, address(claim)); // before the patch goes in
            }
            gasTotal += _send(c[i], i);
            if (i > 0 && sig == keccak256("_setImplementation(address,bool,bytes)")
                && keccak256(bytes(c[i - 1].signature)) == keccak256("settleAndRescue()")) {
                _logRescue(c[i].target, address(claim), b);
            }
        }
        console.log(string.concat("   total gas ", _thousands(gasTotal), "  (block limit 70,000,000)"));
        _check(claim.openedAt() == block.timestamp, "open() ran inside the VIP");

        // ── 3. where the funds went ──
        console.log("");
        console.log("3. WHERE THE FUNDS WENT (tokens)");
        console.log("            Venus 20%      fee 10%        depositors 70%   (Venus in vTokens' worth)");
        for (uint256 i; i < 7; ++i) {
            IVTokenSim v = IVTokenSim(markets[i]);
            address u = v.underlying();
            uint256 toVenus = (v.balanceOf(treasury) - t0[i]) * v.exchangeRateStored() / 1e18;
            uint256 toFee = IERC20Sim(u).balanceOf(feeTo) - f0[i];
            console.log(string.concat(
                "   ", _pad(symbols[i], 8), _pad(_dec(toVenus), 15), _pad(_dec(toFee), 15), _dec(claim.pool(u))
            ));
            console.log(string.concat("     MOVE  claim -> RAKE owner (fee) ", _dec(toFee), " ", symbols[i],
                "   | pooled in claim for depositors ", _dec(claim.pool(u)), " ", symbols[i]));
            uint256 total = toVenus + toFee + claim.pool(u);
            console.log(string.concat("     SHARE Venus ", _pct(toVenus, total), "   fee ", _pct(toFee, total),
                "   depositors ", _pct(claim.pool(u), total), "   (of ", _dec(total), " ", symbols[i], " net)"));
            _check(_near(toVenus, total, 2_000) && _near(toFee, total, 1_000) && _near(claim.pool(u), total, 7_000),
                string.concat(symbols[i], " split is 20/10/70"));
            _check(IERC20Sim(u).balanceOf(deployer) == 0 && v.balanceOf(deployer) == 0,
                string.concat("random deployer got no ", symbols[i]));
        }
        console.log(string.concat("   claim window closes at unix ", vm.toString(claim.deadline())));
        console.log("   OK  random deployer received nothing; fee went to the RAKE owner");

        // ── 4. every depositor claims ──
        console.log("");
        address[] memory ws = claim.builtInWallets();
        console.log(string.concat("4. CLAIMS: all ", vm.toString(ws.length), " depositors, each from its own wallet"));
        uint256 n = claim.tokenCount();
        address xvs = claim.XVS();
        uint256 paid;
        for (uint256 k; k < ws.length; ++k) {
            if (_claimAndCheck(claim, ws[k], n, xvs)) ++paid;
            else console.log(string.concat("   #", vm.toString(k + 1), " ", vm.toString(ws[k]), "  dust only, nothing to claim"));
        }
        console.log(string.concat("   OK  ", vm.toString(paid), " wallets paid exactly their claimable, to their own address"));

        // ── 5. after 90 days a random wallet sweeps ──
        address stranger = _randomWallet("stranger");
        vm.warp(claim.deadline() + 1);
        console.log("");
        console.log("5. SWEEP after the window, called by a random wallet", stranger);
        for (uint256 i; i <= n; ++i) {
            address t = i < n ? claim.tokens(i) : xvs;
            uint256 left = IERC20Sim(t).balanceOf(address(claim));
            if (left == 0) continue;
            uint256 b0 = IERC20Sim(t).balanceOf(feeTo);
            vm.prank(stranger);
            claim.sweep(t);
            uint256 got = IERC20Sim(t).balanceOf(feeTo) - b0;
            _check(got == left && IERC20Sim(t).balanceOf(stranger) == 0, "sweep pays the fee recipient, not the caller");
            console.log(string.concat("     MOVE  claim -> RAKE owner (sweep) ", vm.toString(got), " wei of ", vm.toString(t)));
        }
        console.log("   OK  every sweep went to the RAKE owner");

        _saveProposal(c);
        console.log("");
        console.log("ALL CHECKS PASSED");
    }

    function _strategyOf(address market) internal pure returns (address) {
        address[7] memory m = RakeFrozenPositions.vTokens();
        address[7] memory st = RakeFrozenPositions.strategies();
        for (uint256 i; i < 7; ++i) if (m[i] == market) return st[i];
        revert("unknown market");
    }

    /// vToken balances of the strategy, the Venus treasury and the claim contract.
    function _vBalances(address market, address claim) internal view returns (uint256[3] memory b) {
        IVTokenSim v = IVTokenSim(market);
        b = [v.balanceOf(_strategyOf(market)), v.balanceOf(RakeFrozenPositions.VENUS_TREASURY), v.balanceOf(claim)];
    }

    function _logRescue(address market, address claim, uint256[3] memory b) internal view {
        uint256[3] memory a = _vBalances(market, claim);
        console.log(string.concat("         MOVE  strategy ", vm.toString(_strategyOf(market)), "  vTokens ",
            vm.toString(b[0]), " -> ", vm.toString(a[0]), "  (debt burned + moved)"));
        console.log(string.concat("         MOVE  -> Venus treasury +", vm.toString(a[1] - b[1]),
            " vTokens   -> claim contract +", vm.toString(a[2] - b[2]), " vTokens"));
        uint256 moved = (a[1] - b[1]) + (a[2] - b[2]);
        console.log(string.concat("         SHARE Venus treasury ", _pct(a[1] - b[1], moved), "   claim contract ", _pct(a[2] - b[2], moved)));
        _check(a[0] == 0, "strategy emptied");
        _check(a[1] - b[1] == moved * 2_000 / 10_000 || a[1] - b[1] == moved * 2_000 / 10_000 + 1, "Venus gets exactly 20% of the vTokens");
    }

    /// One depositor claims; every token must land in that wallet, exactly its claimable.
    function _claimAndCheck(RakeDepositorsClaim claim, address w, uint256 n, address xvs) internal returns (bool) {
        address[] memory pay = new address[](n + 1);
        uint256[] memory want = new uint256[](n + 1);
        uint256[] memory b0 = new uint256[](n + 1);
        bool any;
        for (uint256 i; i <= n; ++i) {
            address t = i < n ? claim.tokens(i) : xvs;
            pay[i] = i < n ? claim.payoutToken(t) : xvs;
            want[i] = claim.claimable(w, t);
            b0[i] = IERC20Sim(pay[i]).balanceOf(w);
            if (want[i] > 0) any = true;
        }
        if (!any) return false;
        vm.prank(w);
        claim.claim();
        string memory line = string.concat("     MOVE  claim -> ", vm.toString(w), " :");
        for (uint256 i; i <= n; ++i) {
            uint256 got = IERC20Sim(pay[i]).balanceOf(w) - b0[i];
            _check(got == want[i], string.concat("depositor paid ", vm.toString(w)));
            if (got > 0) line = string.concat(line, " ", _sym(i, n), " ", _dec(got));
        }
        console.log(line);
        return true;
    }

    function _sym(uint256 i, uint256 n) internal pure returns (string memory) {
        return i < n ? RakeFrozenPositions.symbols()[i] : "XVS";
    }

    /// Sends one command as the Timelock and logs it.
    function _send(VenusRescueProposalCommands.Command memory cmd, uint256 i) internal returns (uint256 gasUsed) {
        uint256 g = gasleft();
        vm.prank(RakeFrozenPositions.VENUS_NORMAL_TIMELOCK);
        (bool ok, bytes memory ret) = cmd.target.call(cmd.callData());
        gasUsed = g - gasleft();
        if (!ok) {
            console.log(string.concat("   FAIL  #", vm.toString(i), " ", vm.toString(cmd.target), " ", cmd.signature));
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        console.log(string.concat("   OK  #", _pad(vm.toString(i), 3), vm.toString(cmd.target), "  ",
            _pad(cmd.signature, 42), "gas ", _thousands(gasUsed)));
    }

    function _saveProposal(VenusRescueProposalCommands.Command[] memory c) internal {
        address[] memory targets = new address[](c.length);
        uint256[] memory values = new uint256[](c.length);
        string[] memory signatures = new string[](c.length);
        bytes[] memory calldatas = new bytes[](c.length);
        for (uint256 i; i < c.length; ++i) {
            (targets[i], signatures[i], calldatas[i]) = (c[i].target, c[i].signature, c[i].params);
        }
        vm.serializeAddress("proposal", "targets", targets);
        vm.serializeUint("proposal", "values", values);
        vm.serializeString("proposal", "signatures", signatures);
        vm.writeJson(vm.serializeBytes("proposal", "calldatas", calldatas), "out/vip-proposal.json");
        console.log("propose() arrays saved to contracts/out/vip-proposal.json");
    }

    /// A fresh wallet each run (seeded by the clock), never one of the RAKE or Venus addresses.
    function _randomWallet(string memory label) internal returns (address) {
        return vm.addr(uint256(keccak256(abi.encode(vm.unixTime(), label))) % (2 ** 255) + 1);
    }

    /// x / total as a percentage with 4 decimals, e.g. "20.0000%".
    function _pct(uint256 x, uint256 total) internal pure returns (string memory) {
        uint256 p = x * 1e6 / total; // percent × 1e4
        uint256 f = p % 1e4;
        string memory pad = f < 10 ? "000" : f < 100 ? "00" : f < 1000 ? "0" : "";
        return string.concat(vm.toString(p / 1e4), ".", pad, vm.toString(f), "%");
    }

    /// x is `bps` of total, to within 0.01% (rounding and the vToken→underlying price).
    function _near(uint256 x, uint256 total, uint256 bps) internal pure returns (bool) {
        uint256 want = total * bps / 10_000;
        uint256 diff = x > want ? x - want : want - x;
        return diff * 10_000 <= total;
    }

    function _check(bool ok, string memory what) internal pure {
        require(ok, string.concat("CHECK FAILED: ", what));
    }

    function _pad(string memory s, uint256 w) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= w) return string.concat(s, " ");
        bytes memory sp = new bytes(w - b.length);
        for (uint256 i; i < sp.length; ++i) sp[i] = " ";
        return string.concat(s, string(sp));
    }

    function _thousands(uint256 x) internal pure returns (string memory) {
        if (x < 1000) return vm.toString(x);
        uint256 r = x % 1000;
        return string.concat(_thousands(x / 1000), ",", r < 10 ? "00" : r < 100 ? "0" : "", vm.toString(r));
    }

    /// 18-decimal fixed point to "1234.5678".
    function _dec(uint256 x) internal pure returns (string memory) {
        uint256 frac = x / 1e14 % 1e4;
        string memory pad = frac < 10 ? "000" : frac < 100 ? "00" : frac < 1000 ? "0" : "";
        return string.concat(vm.toString(x / 1e18), ".", pad, vm.toString(frac));
    }
}
