// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../../src/libraries/RescueContractsDeployment.sol";
import "../../src/libraries/AddressesJson.sol";

/// Steps 1-2 (APPENDIX A2), run by RAKE, one script: deploys the claim contract, then the ONE
/// VenusMarketRescuePatch (all seven markets share an implementation) bound to it (20% of the net
/// vTokens to the Venus treasury, 80% to the claim), and records both in addresses.json
/// (.deployed.claimContract, .deployed.rescuePatch). The key is read from $PRIVATE_KEY; the fee
/// recipient (fee and leftovers) is the hardcoded RAKE owner, whoever deploys, and the deployer gets no
/// power over either contract. Only the Venus timelock can call open(), once, as the VIP's last command.
///
///   forge script script/live/Deploy.s.sol --fork-url $BSC_RPC_URL                 # dry run
///   forge script script/live/Deploy.s.sol --rpc-url $BSC_MEV_RPC_URL --broadcast   # deploy, MEV-protected RPC
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        RakeDepositorsClaim claim = RescueContractsDeployment.deployClaim();
        address patch = RescueContractsDeployment.deployRescuePatch(address(claim));
        vm.stopBroadcast();

        console.log("claim contract", address(claim));
        console.log("fee recipient", claim.FEE_RECIPIENT());
        console.log("rescue patch", patch);
        AddressesJson.record(".deployed.claimContract", address(claim));
        AddressesJson.record(".deployed.rescuePatch", patch);
    }
}
