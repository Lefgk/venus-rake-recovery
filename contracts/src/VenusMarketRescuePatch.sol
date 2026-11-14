// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @title VenusMarketRescuePatch — self-funded rescue: settle the borrow from the collateral,
///        then move only the net equity.
///
/// @notice A temporary vToken implementation, installed and removed inside ONE Venus VIP
///         transaction. It needs no outside capital: the stuck positions are over-collateralised,
///         and every affected strategy supplies and borrows the SAME underlying asset, so the
///         collateral retires the debt directly. No router, no oracle, no price assumption.
///
/// WHAT IT DOES, PER MARKET
///   1. reads the strategy's live borrow;
///   2. burns exactly enough of the strategy's OWN vTokens to cover it;
///   3. zeroes the strategy's borrow and decrements totalBorrows by the same amount;
///   4. decrements totalSupply by the burned amount; and
///   5. splits the remaining vTokens: VENUS_BPS (20%) to TREASURY, the rest (80%) to OWNER (the
///      claim contract). The VIP's last command, claim.open(), redeems the claim's 80% to underlying
///      in the same transaction and pays the 10% recovery cost from it.
///
/// WHY NO OTHER SUPPLIER LOSES ANYTHING
///   exchangeRate = (cash + totalBorrows - totalReserves) * 1e18 / totalSupply
///   Cancelling borrow `d` and burning `d * 1e18 / exchangeRate` of supply gives
///       (N - d) * 1e18 / (TS - d*1e18/ER) == N * 1e18 / TS == ER
///   so the exchange rate is unchanged. `cash` is never touched, so the market's liquidity is
///   unchanged too. The burn is rounded UP, which can only move the rate in the market's
///   favour — the contract asserts it never decreases.
///
/// SEQUENCING
///   Interest must be current, because the exchange rate and the live borrow are both read from
///   stored state. `settleAndRescue()` first runs the market's own `accrueInterest()` (delegatecall
///   to the original implementation), then checks `accrualBlockNumber == block.number`.
///
/// Runs via delegatecall in the vToken delegator's storage context, so it reads and writes the
/// PROXY's storage. It changes totalSupply and totalBorrows (it retires debt); `cash`,
/// `totalReserves`, `borrowIndex` and the exchange rate are not changed.
///
/// All reads (exchange rate, borrow balance) delegatecall the market's original implementation,
/// so Venus's own arithmetic is authoritative on every market — including vUSDT and vUSDC,
/// where getCash() != underlying.balanceOf(vToken).
interface IVenusMarketPreflight {
    function implementation() external view returns (address);
}

interface IVenusComptrollerPreflight {
    function treasuryAddress() external view returns (address);
    function getAssetsIn(address account) external view returns (address[] memory);
}

contract VenusMarketRescuePatch {
    /// Storage slots on the shared Venus VBep20Delegate, checked against the public getters
    /// (slot value == getter return, exact) on all seven markets:
    ///   slot 10 borrowIndex   slot 11 totalBorrows   slot 13 totalSupply
    ///   slot 14 accountTokens slot 16 accountBorrows slot  9 accrualBlockNumber
    /// Only WRITES rely on these; all reads go through the original implementation. Re-check
    /// them per market at the VIP's filing block.
    uint256 internal constant BORROW_INDEX_SLOT = 10;
    uint256 internal constant TOTAL_BORROWS_SLOT = 11;
    uint256 internal constant TOTAL_SUPPLY_SLOT = 13;
    uint256 internal constant ACCOUNT_TOKENS_SLOT = 14;
    uint256 internal constant ACCOUNT_BORROWS_SLOT = 16;
    uint256 internal constant ACCRUAL_BLOCK_SLOT = 9;

    /// Immutables live in CODE, not storage, so they cannot collide with the proxy's layout.
    address public immutable OWNER;

    /// Venus treasury (`Comptroller.treasuryAddress()`).
    address public constant TREASURY = 0xF322942f644A996A617BD29c16bd7d231d9F35E9;
    uint256 public constant VENUS_BPS = 2_000;

    /// The market's ORIGINAL implementation. The delegate delegatecalls it for every READ
    /// (exchange rate, borrow balance) so those figures come from Venus's own code rather than
    /// from a reimplementation. This matters: on vUSDT and vUSDC, getCash() does NOT equal
    /// underlying.balanceOf(vToken), so a hand-rolled exchangeRateStored() is wrong for those
    /// two markets. Delegatecalling the real implementation is correct for all seven by
    /// construction, and shrinks the audit surface to the WRITES alone.
    address public constant ORIGINAL_IMPL = 0xCDfea50f7CECCB24Fe804657DB8E6c93b689941e;

    /// Venus Core Pool Comptroller (Unitroller), read by preflight().
    address public constant COMPTROLLER = 0xfD36E2c2a6789Db23113685031d7F16329158384;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event DebtSettledFromCollateral(address indexed strategy, uint256 debtRetired, uint256 vTokensBurned);

    /// Only the claim contract is passed in: it is deployed first, so its address is not known
    /// when this is compiled. Everything else (treasury, split, markets, strategies, the
    /// original implementation) is a constant.
    constructor(address owner_) {
        require(owner_ != address(0), "zero addr");
        require(ORIGINAL_IMPL.code.length > 0, "impl not a contract");
        OWNER = owner_;
    }

    // The delegator calls these on the incoming/outgoing implementation during a swap.
    function _becomeImplementation(bytes memory) external {}
    function _resignImplementation() external {}

    /// @notice The RAKE strategy stuck in `market`. One patch serves all seven markets (they
    ///         share one implementation); while delegatecalled, `address(this)` is the market.
    function strategyOf(address market) public pure returns (address) {
        if (market == 0x95c78222B3D6e262426483D42CfA53685A67Ab9D) return 0xDF3df3EE9Fb6D5c9B4fdcF80A92D25d2285A859C; // vBUSD
        if (market == 0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B) return 0xB3bCA2C1c2C4DF2C903BE3F341C96732Ac8b3c12; // vBTC
        if (market == 0xf508fCD89b8bd15579dc79A6827cB4686A3592c8) return 0x9E3e8878B53c5762Ec6F461701f02ee6d1D9d19C; // vETH
        if (market == 0x650b940a1033B8A1b1873f78730FcFC73ec11f1f) return 0x0b09Efc9458c00354414D2A560aA6EDa19490169; // vLINK
        if (market == 0xfD5840Cd36d94D7229439859C0112a4185BC0255) return 0xc6f470dA6C284D16647CEE2230522a85b0818f6D; // vUSDT
        if (market == 0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8) return 0x7485704d8B6cEBd1411F5AAfEB063e6f2816069A; // vUSDC
        if (market == 0x1610bc33319e9398de5f57B33a5b184c806aD217) return 0x568254EAAC1476faf9A908e577faa3Ab96029801; // vDOT
        return address(0);
    }

    /// The seven rescued markets, in strategyOf order.
    function markets() public pure returns (address[7] memory) {
        return [
            0x95c78222B3D6e262426483D42CfA53685A67Ab9D,
            0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B,
            0xf508fCD89b8bd15579dc79A6827cB4686A3592c8,
            0x650b940a1033B8A1b1873f78730FcFC73ec11f1f,
            0xfD5840Cd36d94D7229439859C0112a4185BC0255,
            0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8,
            0x1610bc33319e9398de5f57B33a5b184c806aD217
        ];
    }

    /// The VIP's first command (called on this contract, not through a market). Reverts the whole
    /// VIP unless, at execution time: every market still runs ORIGINAL_IMPL (the slot layout this
    /// patch writes, and the implementation the VIP restores); the Comptroller's treasury is still
    /// TREASURY; and each strategy is entered in its own market only, so moving its vTokens
    /// removes no collateral backing a borrow anywhere else.
    function preflight() external view {
        address[7] memory m = markets();
        require(IVenusComptrollerPreflight(COMPTROLLER).treasuryAddress() == TREASURY, "treasury changed");
        for (uint256 i; i < m.length; ++i) {
            require(IVenusMarketPreflight(m[i]).implementation() == ORIGINAL_IMPL, "market implementation changed");
            address[] memory assetsIn = IVenusComptrollerPreflight(COMPTROLLER).getAssetsIn(strategyOf(m[i]));
            require(assetsIn.length == 1 && assetsIn[0] == m[i], "strategy in another market");
        }
    }

    function _strategy() internal view returns (address s) {
        s = strategyOf(address(this));
        require(s != address(0), "not a rescued market");
    }

    /// @notice Live borrow balance of the scoped strategy, per Venus's OWN implementation.
    function scopedBorrowBalance() public returns (uint256) {
        return _readUint(abi.encodeWithSignature("borrowBalanceStored(address)", _strategy()));
    }

    /// @notice Stored exchange rate, per Venus's OWN implementation.
    /// @dev Delegatecalled into this proxy's storage, so it sees the live (and, after the
    ///      writes below, the updated) state — exactly what Venus itself would report.
    function scopedExchangeRate() public returns (uint256) {
        return _readUint(abi.encodeWithSignature("exchangeRateStored()"));
    }

    /// Delegatecall the original implementation and decode a single uint. Reverts loudly
    /// rather than silently returning zero, which would mis-size the burn.
    function _readUint(bytes memory callData) internal returns (uint256 out) {
        (bool ok, bytes memory ret) = ORIGINAL_IMPL.delegatecall(callData);
        require(ok && ret.length >= 32, "impl read failed");
        out = abi.decode(ret, (uint256));
    }

    /// @notice Retire the strategy's borrow against its own collateral, then split the net.
    /// @return debtRetired   underlying units of borrow cancelled
    /// @return burned        vTokens burned to cover it
    /// @return moved         vTokens split between TREASURY and OWNER
    function settleAndRescue() external returns (uint256 debtRetired, uint256 burned, uint256 moved) {
        // Only the market's own admin (read live, so whichever timelock Venus uses). msg.sender
        // is preserved through the delegator's delegatecall.
        require(msg.sender == address(uint160(_readUint(abi.encodeWithSignature("admin()")))), "only admin");

        // Accrue interest first (Venus's own accrueInterest, run on this market's storage), or the
        // borrow and the exchange rate are both stale and the settlement would under-retire the
        // debt. Done here, so the command works on its own, in any block.
        require(_readUint(abi.encodeWithSignature("accrueInterest()")) == 0, "accrue failed");
        uint256 accrualBlock;
        assembly {
            accrualBlock := sload(ACCRUAL_BLOCK_SLOT)
        }
        require(accrualBlock == block.number, "interest not accrued");

        address strategy = _strategy();
        bytes32 fromSlot = keccak256(abi.encode(strategy, ACCOUNT_TOKENS_SLOT));

        uint256 stratTokens;
        uint256 totalSupply_;
        uint256 totalBorrows_;
        assembly {
            stratTokens := sload(fromSlot)
            totalSupply_ := sload(TOTAL_SUPPLY_SLOT)
            totalBorrows_ := sload(TOTAL_BORROWS_SLOT)
        }
        // ONE-SHOT: the first run zeroes this, so a second finds nothing.
        require(stratTokens > 0, "nothing to move");

        uint256 erBefore = scopedExchangeRate();
        debtRetired = scopedBorrowBalance();

        if (debtRetired > 0) {
            // Round UP so the market is never short. Any dust accrues to the remaining
            // suppliers as a marginally higher exchange rate, never a lower one.
            burned = (debtRetired * 1e18 + erBefore - 1) / erBefore;
            // The position must be able to cover its own debt from its own collateral.
            require(burned <= stratTokens, "collateral below debt");
            require(debtRetired <= totalBorrows_, "debt exceeds market borrows");
            require(burned < totalSupply_, "burn exceeds supply");

            bytes32 borrowBase = keccak256(abi.encode(strategy, ACCOUNT_BORROWS_SLOT));
            uint256 bIndex;
            assembly {
                bIndex := sload(BORROW_INDEX_SLOT)
            }

            uint256 newTotalBorrows = totalBorrows_ - debtRetired;
            uint256 newTotalSupply = totalSupply_ - burned;
            uint256 remaining = stratTokens - burned;

            assembly {
                // Strategy's borrow is fully retired. interestIndex is set to the current
                // borrowIndex so the snapshot stays well-formed for any later read.
                sstore(borrowBase, 0)
                sstore(add(borrowBase, 1), bIndex)
                sstore(TOTAL_BORROWS_SLOT, newTotalBorrows)
                sstore(TOTAL_SUPPLY_SLOT, newTotalSupply)
                sstore(fromSlot, remaining)
            }

            stratTokens = remaining;
            emit Transfer(strategy, address(0), burned);
            emit DebtSettledFromCollateral(strategy, debtRetired, burned);
        }

        // The exchange rate must not have fallen. Equality is the expected outcome; the
        // rounding-up of `burned` can only raise it by dust.
        require(scopedExchangeRate() >= erBefore, "exchange rate fell");

        moved = stratTokens;
        require(moved > 0, "nothing left after settlement");

        assembly {
            sstore(fromSlot, 0)
        }
        uint256 toVenus = moved * VENUS_BPS / 10_000;
        _credit(strategy, TREASURY, toVenus);
        _credit(strategy, OWNER, moved - toVenus);
    }

    /// Add `amount` to `to`'s vToken balance. Read-modify-write per payee, so payees that are
    /// the same address still add up.
    function _credit(address from, address to, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(to, ACCOUNT_TOKENS_SLOT));
        uint256 bal;
        assembly {
            bal := sload(slot)
        }
        uint256 newBal = bal + amount; // checked outside assembly
        assembly {
            sstore(slot, newBal)
        }
        emit Transfer(from, to, amount);
    }

}
