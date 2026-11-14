// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../src/RakeDepositorsClaim.sol";

/// Implemented by the test that deploys a RakeDepositorsClaimHarness.
interface IClaimCfg {
    function cfgFarm() external view returns (address);
    function cfgVTokens() external view returns (address[] memory);
    function cfgPids() external view returns (uint256[] memory);
    function cfgWallets() external view returns (address[] memory);
    function cfgXvs() external view returns (address);
    function cfgXvsWeights() external view returns (uint256[] memory);
}

/// Test-only: RakeDepositorsClaim with farm, pools, vTokens and wallets read from the deployer,
/// so the claim logic can run against a mock farm or another pool.
contract RakeDepositorsClaimHarness is RakeDepositorsClaim {
    function _farm() internal view override returns (address) {
        return IClaimCfg(msg.sender).cfgFarm();
    }

    function _pids() internal view override returns (uint256[] memory) {
        return IClaimCfg(msg.sender).cfgPids();
    }

    function _wallets() internal view override returns (address[] memory) {
        return IClaimCfg(msg.sender).cfgWallets();
    }

    /// Mock farms: read every pool.
    function _poolMasks() internal pure override returns (bytes memory) {}

    function _xvs() internal view override returns (address) {
        return IClaimCfg(msg.sender).cfgXvs();
    }

    function _xvsWeights() internal view override returns (uint256[] memory) {
        return IClaimCfg(msg.sender).cfgXvsWeights();
    }

    /// Mock 1:1 vTokens, or none to fund a pool with the underlying directly.
    function _vTokens() internal view override returns (address[] memory) {
        return IClaimCfg(msg.sender).cfgVTokens();
    }
}
