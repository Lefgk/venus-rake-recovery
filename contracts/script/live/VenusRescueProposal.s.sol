// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../../src/libraries/VenusRescueProposalCommands.sol";
import "../../src/libraries/AddressesJson.sol";

/// Step 4 (APPENDIX A2), for Venus: prints the proposal, as the four arrays GovernorBravo.propose() takes:
/// targets, values (all 0), signatures, calldatas (ABI-encoded params, without the selector).
/// Reads the claim contract and the rescue patch from addresses.json, so run
/// Deploy first. Read-only: sends nothing.
///
///   forge script script/live/VenusRescueProposal.s.sol --fork-url $BSC_RPC_URL
contract VenusRescueProposal is Script {
    function run() external {
        address claim = AddressesJson.deployed(".deployed.claimContract", "Deploy");
        address patch = AddressesJson.deployed(".deployed.rescuePatch", "Deploy");
        VenusRescueProposalCommands.Command[] memory c =
            VenusRescueProposalCommands.build(claim, patch, true);

        address[] memory targets = new address[](c.length);
        uint256[] memory values = new uint256[](c.length);
        string[] memory signatures = new string[](c.length);
        bytes[] memory calldatas = new bytes[](c.length);
        for (uint256 i; i < c.length; ++i) {
            (targets[i], signatures[i], calldatas[i]) = (c[i].target, c[i].signature, c[i].params);
            console.log(string.concat(vm.toString(i), " ", vm.toString(c[i].target), " ", c[i].signature));
        }
        vm.serializeAddress("proposal", "targets", targets);
        vm.serializeUint("proposal", "values", values);
        vm.serializeString("proposal", "signatures", signatures);
        console.log(vm.serializeBytes("proposal", "calldatas", calldatas));
    }
}
