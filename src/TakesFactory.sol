// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "openzeppelin-contracts/interfaces/IERC4626.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

import { ITakesFactory } from "./interfaces/ITakesFactory.sol";
import { TakesMarket } from "./TakesMarket.sol";

/// @title TakesFactory
/// @notice Looks up or deploys TakesMarket contracts addressed by question
///         hash. Holds the current default yield source for new markets.
///         Markets, once deployed, are wired to whatever yield source was
///         current at their creation — the factory's source rotation
///         affects only future deployments.
contract TakesFactory is ITakesFactory, ReentrancyGuard {
    /* ────────────────────────── State ──────────────────────────────── */

    IERC20 public immutable asset;
    IERC4626 public currentYieldSource;
    address public guardian;
    /// @notice Nominee for guardian role. Cleared on `acceptGuardian` or
    ///         when current guardian calls `transferGuardian(address(0))`.
    address public pendingGuardian;
    bool public paused;
    mapping(bytes32 => address) private _markets;

    /* ──────────────────────── Construction ─────────────────────────── */

    constructor(IERC20 _asset, IERC4626 _initialYieldSource, address _guardian) {
        require(address(_asset) != address(0), "asset zero");
        require(address(_initialYieldSource) != address(0), "source zero");
        require(_guardian != address(0), "guardian zero");
        require(_initialYieldSource.asset() == address(_asset), "asset mismatch");
        asset = _asset;
        currentYieldSource = _initialYieldSource;
        guardian = _guardian;
    }

    /* ──────────────────────── Modifiers ────────────────────────────── */

    modifier onlyGuardian() {
        require(msg.sender == guardian, "not guardian");
        _;
    }

    /* ──────────────────────── User actions ─────────────────────────── */

    /// @inheritdoc ITakesFactory
    /// @dev `nonReentrant` blocks a malicious yield source's `asset()`
    ///      callback from re-entering during `new TakesMarket(...)` and
    ///      deploying a duplicate market under the same hash.
    function getOrCreate(bytes32 questionHash, string calldata question)
        external
        nonReentrant
        returns (address market)
    {
        market = _markets[questionHash];
        if (market != address(0)) return market;

        require(!paused, "paused");
        require(questionHash != bytes32(0), "zero hash");
        require(bytes(question).length > 0, "empty question");
        // On-chain integrity: the stored / emitted text must hash to the key.
        // Off-chain canonicalization (whitespace, casing) is the producer's
        // responsibility; the contract just enforces consistency.
        require(
            keccak256(bytes(question)) == questionHash,
            "hash/text mismatch"
        );

        // CREATE2 with salt = questionHash. Address is deterministic in
        // (factory, questionHash, question, asset, currentYieldSource).
        // The early-return above means we never hit a CREATE2 collision —
        // a second call for the same hash returns the cached market.
        TakesMarket newMarket = new TakesMarket{salt: questionHash}(
            questionHash,
            question,
            asset,
            currentYieldSource
        );
        market = address(newMarket);
        _markets[questionHash] = market;

        emit MarketCreated(
            questionHash,
            market,
            address(currentYieldSource),
            question,
            msg.sender
        );
    }

    /* ─────────────────────────── Views ─────────────────────────────── */

    /// @inheritdoc ITakesFactory
    function getMarket(bytes32 questionHash) external view returns (address) {
        return _markets[questionHash];
    }

    /// @inheritdoc ITakesFactory
    function predictMarket(bytes32 questionHash, string calldata question)
        external
        view
        returns (address)
    {
        bytes memory initCode = abi.encodePacked(
            type(TakesMarket).creationCode,
            abi.encode(questionHash, question, asset, currentYieldSource)
        );
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                questionHash,
                keccak256(initCode)
            )
        );
        return address(uint160(uint256(hash)));
    }

    /* ──────────────────────── Admin ────────────────────────────────── */

    /// @inheritdoc ITakesFactory
    function setYieldSource(IERC4626 newSource) external onlyGuardian {
        require(address(newSource) != address(0), "source zero");
        require(newSource.asset() == address(asset), "asset mismatch");
        IERC4626 prev = currentYieldSource;
        currentYieldSource = newSource;
        emit YieldSourceUpdated(address(prev), address(newSource));
    }

    /// @inheritdoc ITakesFactory
    /// @dev Zero address is allowed and intentional — it cancels any pending
    ///      transfer.
    // slither-disable-next-line missing-zero-check
    function transferGuardian(address newGuardian) external onlyGuardian {
        pendingGuardian = newGuardian;
        emit GuardianTransferStarted(guardian, newGuardian);
    }

    /// @inheritdoc ITakesFactory
    function acceptGuardian() external {
        address pending = pendingGuardian;
        require(pending != address(0), "no pending");
        require(msg.sender == pending, "not pending");
        address prev = guardian;
        guardian = pending;
        pendingGuardian = address(0);
        emit GuardianTransferred(prev, pending);
    }

    /// @inheritdoc ITakesFactory
    function pause() external onlyGuardian {
        require(!paused, "already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc ITakesFactory
    function unpause() external onlyGuardian {
        require(paused, "not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }
}
