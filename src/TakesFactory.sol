// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "openzeppelin-contracts/interfaces/IERC4626.sol";

import { ITakesFactory } from "./interfaces/ITakesFactory.sol";
import { TakesMarket } from "./TakesMarket.sol";

/// @title TakesFactory
/// @notice Looks up or deploys TakesMarket contracts addressed by question
///         hash. Holds the current default yield source for new markets.
///         Markets, once deployed, are wired to whatever yield source was
///         current at their creation — the factory's source rotation
///         affects only future deployments.
contract TakesFactory is ITakesFactory {
    /* ────────────────────────── State ──────────────────────────────── */

    IERC20 public immutable asset;
    IERC4626 public currentYieldSource;
    address public guardian;
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
    function getOrCreate(bytes32 questionHash, string calldata question)
        external
        returns (address market)
    {
        market = _markets[questionHash];
        if (market != address(0)) return market;

        require(!paused, "paused");
        require(bytes(question).length > 0, "empty question");

        TakesMarket newMarket = new TakesMarket(
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
    function transferGuardian(address newGuardian) external onlyGuardian {
        require(newGuardian != address(0), "zero");
        address prev = guardian;
        guardian = newGuardian;
        emit GuardianTransferred(prev, newGuardian);
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
