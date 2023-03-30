// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./utils/Operator.sol";
import "./types/Printer.sol";

contract Firmament is Printer {
    /// SUPPLY = 60,000 FIRM
    /// governance can mint more tokens at a later date if the community wants to

    uint256 public constant FARMING_POOL_REWARD_ALLOCATION = 54_490 ether;
    uint256 public constant ENRICHMENT_FUND_POOL_ALLOCATION = 5_500 ether;
    uint256 public constant INITIAL_LIQUIDITY = 10 ether;

    uint256 public constant VESTING_DURATION = 365 days;
    uint256 public startTime;
    uint256 public endTime;

    uint256 public enrichmentFundRewardRate;
    address public enrichmentFund;
    uint256 public enrichmentFundLastClaimed;

    bool public rewardPoolDistributed = false;

    constructor(
        address _enrichmentFund,
        address _usdc,
        address _router,
        IAuthority _authority
    ) ERC20("Firmament", "FIRM") Printer(_usdc, _authority) {
        require(
            FARMING_POOL_REWARD_ALLOCATION +
                ENRICHMENT_FUND_POOL_ALLOCATION +
                INITIAL_LIQUIDITY ==
                60_000 ether,
            "Invalid Total Supply"
        );
        _mint(msg.sender, INITIAL_LIQUIDITY);

        startTime = block.timestamp + 4 hours;
        endTime = startTime + VESTING_DURATION;

        enrichmentFundLastClaimed = startTime;
        enrichmentFundRewardRate =
            ENRICHMENT_FUND_POOL_ALLOCATION /
            VESTING_DURATION;

        require(_enrichmentFund != address(0), "Address cannot be 0");
        enrichmentFund = _enrichmentFund;
    }

    function setEnrichmentFund(address _devFund) external {
        require(msg.sender == enrichmentFund, "!enrichment");
        require(_devFund != address(0), "zero");
        enrichmentFund = _devFund;
    }

    function unclaimedEnrichmentFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (enrichmentFundLastClaimed >= _now) return 0;
        _pending =
            (_now - enrichmentFundLastClaimed) *
            enrichmentFundRewardRate;
    }

    /**
     * @notice Claim pending rewards to enrichment fund
     */
    function claimRewards() external {
        uint256 _pending = unclaimedEnrichmentFund();
        if (_pending > 0 && enrichmentFund != address(0)) {
            _mint(enrichmentFund, _pending);
            enrichmentFundLastClaimed = block.timestamp;
        }
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(
        address _farmingIncentiveFund
    ) external onlyController {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_farmingIncentiveFund != address(0), "!_farmingIncentiveFund");
        rewardPoolDistributed = true;
        _mint(_farmingIncentiveFund, FARMING_POOL_REWARD_ALLOCATION);
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function mint(address account, uint256 amount) public onlyFirmamentMinter {
        _mint(account, amount);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyController {
        _token.transfer(_to, _amount);
    }
}
