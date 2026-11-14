// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./RakeFrozenPositions.sol";
import "../VenusMarketRescuePatch.sol";
import "../RakeDepositorsClaim.sol";

interface IVTokenImplementation {
    function implementation() external view returns (address);
}

/// How the contracts are deployed, shared by the two deploy scripts and the tests, so both
/// deploy the same way.
library RescueContractsDeployment {
    /// RAKE deploys this (script/live/Deploy.s.sol). The hardcoded RAKE owner is the claim
    /// contract's fee recipient (fee and leftovers), whoever deploys; its constructor snapshots all 103
    /// depositors' farm shares.
    function deployClaim() internal returns (RakeDepositorsClaim) {
        return new RakeDepositorsClaim();
    }

    /// RAKE deploys this (script/live/Deploy.s.sol): ONE VenusMarketRescuePatch for
    /// all seven markets, which share one implementation. It is bound to the claim contract only:
    /// it sends 20% of each market's net vTokens to the Venus treasury and 80% to the claim, whose
    /// open() takes the 10% fee. The implementation (which the proposal restores) is a constant,
    /// checked here and again by the VIP's preflight(); it finds each market's strategy itself. The deployer gets no power over it:
    /// only the market admin can call settleAndRescue().
    function deployRescuePatch(address claim) internal returns (address) {
        address[7] memory markets = RakeFrozenPositions.vTokens();
        for (uint256 i; i < RakeFrozenPositions.COUNT; ++i) {
            require(
                IVTokenImplementation(markets[i]).implementation()
                    == RakeFrozenPositions.VBEP20_DELEGATE_IMPLEMENTATION,
                "market implementation changed"
            );
        }
        return address(
new VenusMarketRescuePatch(claim)
        );
    }
}
