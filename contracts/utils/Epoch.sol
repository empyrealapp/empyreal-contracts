// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Operator.sol";

contract Epoch is Operator {
    uint256 internal period;
    uint256 internal startTime_;
    uint256 internal lastEpochTime;
    uint256 internal epoch;

    /* ========== CONSTRUCTOR ========== */

    constructor(uint256 _period, uint256 _startTime, uint256 _startEpoch) {
        period = _period;
        startTime_ = _startTime;
        epoch = _startEpoch;
        lastEpochTime = startTime_ - period;
    }

    /* ========== Modifier ========== */

    modifier checkStartTime() {
        require(block.timestamp >= startTime_, "Epoch: not started yet");

        _;
    }

    modifier checkEpoch() {
        uint256 _nextEpochPoint = nextEpochPoint();
        if (block.timestamp < _nextEpochPoint) {
            require(
                msg.sender == operator(),
                "Epoch: only operator allowed for pre-epoch"
            );
            _;
        } else {
            _;

            for (;;) {
                lastEpochTime = _nextEpochPoint;
                ++epoch;
                _nextEpochPoint = nextEpochPoint();
                if (block.timestamp < _nextEpochPoint) break;
            }
        }
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getCurrentEpoch() public view returns (uint256) {
        return epoch;
    }

    function getPeriod() public view returns (uint256) {
        return period;
    }

    function getStartTime() public view returns (uint256) {
        return startTime_;
    }

    function getLastEpochTime() public view returns (uint256) {
        return lastEpochTime;
    }

    function nextEpochPoint() public view returns (uint256) {
        return lastEpochTime + period;
    }

    /* ========== GOVERNANCE ========== */

    function setPeriod(uint256 _period) external onlyOperator {
        require(
            _period >= 1 hours && _period <= 48 hours,
            "_period: out of range"
        );
        period = _period;
    }

    function setEpoch(uint256 _epoch) external onlyOperator {
        epoch = _epoch;
    }
}
