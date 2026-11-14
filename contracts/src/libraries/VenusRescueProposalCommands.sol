// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/console.sol";
import "./RakeFrozenPositions.sol";
import "../VenusMarketRescuePatch.sol";

/// The proposal's command list, shared by script/live/VenusRescueProposal.s.sol, script/simulation/SimulateVIP.s.sol and the
/// fork tests, so the commands the tests execute are byte-for-byte the commands Venus is asked to submit.
library VenusRescueProposalCommands {
    /// One Venus Timelock action: it calls `target` with selector(signature) ++ params.
    struct Command {
        address target;
        string signature;
        bytes params;
    }

    /// Number of commands before the first market (steps 0 to 2 below).
    uint256 internal constant SETUP_COMMANDS = 3;

    /// 0. patch.preflight(): reverts the VIP unless every market still runs the implementation the
    ///    patch was written for, the Comptroller's treasury is unchanged and each strategy is in its
    ///    own market only.
    /// 1. claim.captureBefore(): the claim records its vToken balances, so open() redeems only
    ///    what arrives in this transaction.
    /// 2. Settle the XVS index of the two vToken payees (claim contract, Venus treasury) on the
    ///    seven markets, so the vTokens they receive earn no back-dated XVS.
    ///    Uses the 4-argument claimVenus over an explicit market list: the 1-argument one walks
    ///    every market ever listed and reverts on a delisted one.
    /// 3. For each market: swap in the patch, call settleAndRescue() (accrues interest, retires the
    ///    strategy's debt from its own collateral, moves the net vTokens 20% to the Venus
    ///    treasury, 80% to the claim contract), restore the original implementation.
    /// 4. Grant the strategies' earned XVS to the claim contract. (seizeVenus would also clear the
    ///    strategies' venusAccrued, but it walks every market ever listed and reverts on a
    ///    delisted one; what stays accrued can only ever be paid to the strategies themselves.)
    /// 5. Last, claim.open(): redeems the vToken balance increase since captureBefore(), pays 10%
    ///    of the net from the underlying that came back, pools the 70% (and the granted XVS, less
    ///    10%) for depositors and starts the 90-day window. A market whose redeem fails is paid
    ///    out in its vTokens instead, so one market short of cash does not block the others.
    function build(address claim, address patch, bool includeXvsGrant) internal view returns (Command[] memory c) {
        address comptroller = RakeFrozenPositions.VENUS_COMPTROLLER;
        address[7] memory markets = RakeFrozenPositions.vTokens();
        address original = VenusMarketRescuePatch(patch).ORIGINAL_IMPL();

        c = new Command[](SETUP_COMMANDS + 3 * RakeFrozenPositions.COUNT + 1 + (includeXvsGrant ? 1 : 0));
        address[] memory holders = new address[](2);
        holders[0] = claim;
        holders[1] = RakeFrozenPositions.VENUS_TREASURY;
        uint256 n;
        c[n++] = Command(patch, "preflight()", "");
        c[n++] = Command(claim, "captureBefore()", "");
        c[n++] = Command(
            comptroller,
            "claimVenus(address[],address[],bool,bool)",
            abi.encode(holders, RakeFrozenPositions.vTokenList(), false, true)
        );
        for (uint256 i; i < RakeFrozenPositions.COUNT; ++i) {
            c[n++] = Command(markets[i], "_setImplementation(address,bool,bytes)", abi.encode(patch, false, ""));
            c[n++] = Command(markets[i], "settleAndRescue()", "");
            c[n++] = Command(markets[i], "_setImplementation(address,bool,bytes)", abi.encode(original, false, ""));
        }
        if (includeXvsGrant) {
            c[n++] = Command(
                comptroller, "_grantXVS(address,uint256)", abi.encode(claim, RakeFrozenPositions.XVS_GRANT)
            );
        }
        c[n++] = Command(claim, "open()", "");
    }

    /// The exact bytes the Timelock sends for a command.
    function callData(Command memory c) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes4(keccak256(bytes(c.signature))), c.params);
    }

    /// Sends the commands the way the Timelock does (`target.call(callData)`), logging each one
    /// and reverting with the failing command's own error. The caller must be the Timelock
    /// (tests: vm.startPrank).
    function execute(Command[] memory c) internal {
        console.log("VIP: executing commands as the Timelock:", c.length);
        for (uint256 i; i < c.length; ++i) {
            console.log("  command", i, c[i].target, c[i].signature);
            (bool ok, bytes memory ret) = c[i].target.call(callData(c[i]));
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}
