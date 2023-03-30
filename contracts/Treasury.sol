// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IOracle.sol";
import "./interfaces/IHorizon.sol";
import "./interfaces/ISeigniorageCalculator.sol";
import "./lib/Babylonian.sol";
import "./types/AccessControlled.sol";
import "./utils/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";

contract Treasury is ContractGuard, AccessControlled {
    using SafeERC20 for IERC20;
    using Address for address;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 8 hours;

    /* ========== STATE VARIABLES ========== */

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;

    // core components
    IOracle public empyrealOracle;
    IOracle public firmamentOracle;

    // price
    uint256 public empyrealPriceOne;
    uint256 public empyrealPriceCeiling;

    // 28 first epochs (1 week) with 4.5% expansion regardless of EMP price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochEmpyrealPrice;
    uint256 public previousEpochFirmamentPrice;

    address public enrichmentFund;
    uint256 public enrichmentFundPercent;
    ISeigniorageCalculator seigniorageCalculator;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event EnrichmentFundFunded(uint256 timestamp, uint256 seigniorage);
    event HorizonFunded(uint256 timestamp, uint256 _amount);

    /* =================== Modifier =================== */

    modifier checkCondition() {
        require(block.timestamp >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch() {
        require(
            block.timestamp >= nextEpochPoint(),
            "Treasury: not opened yet"
        );

        _;

        epoch += 1;
    }

    modifier notInitialized() {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime + (epoch * PERIOD);
    }

    // oracle
    function getEmpyrealPrice() public view returns (uint256 empyrealPrice) {
        try IOracle(empyrealOracle).consult(empyreal(), 1e18) returns (
            uint144 price
        ) {
            return uint256(price);
        } catch {
            revert(
                "Treasury: failed to consult EMPYREAL price from the oracle"
            );
        }
    }

    function getFirmamentPrice() public view returns (uint256 firmamentPrice) {
        try IOracle(firmamentOracle).consult(firmament(), 1e18) returns (
            uint144 price
        ) {
            return uint256(price);
        } catch {
            revert(
                "Treasury: failed to consult FIRMAMENT price from the oracle"
            );
        }
    }

    function getEmpyrealUpdatedPrice()
        public
        view
        returns (uint256 _empyrealPrice)
    {
        try IOracle(empyrealOracle).twap(empyreal(), 1e18) returns (
            uint144 price
        ) {
            return uint256(price);
        } catch {
            revert(
                "Treasury: failed to consult EMPYREAL price from the oracle"
            );
        }
    }

    function getFirmamentUpdatedPrice()
        public
        view
        returns (uint256 _firmamentPrice)
    {
        try IOracle(firmamentOracle).twap(firmament(), 1e18) returns (
            uint144 price
        ) {
            return uint256(price);
        } catch {
            revert(
                "Treasury: failed to consult FIRMAMENT price from the oracle"
            );
        }
    }

    /* ========== GOVERNANCE ========== */

    constructor(IAuthority _authority) AccessControlled(_authority) {}

    function initialize(
        IOracle _empyrealOracle,
        IOracle _firmamentOracle,
        uint256 _startTime,
        ISeigniorageCalculator _calculator
    ) public onlyController notInitialized {
        empyrealOracle = _empyrealOracle;
        firmamentOracle = _firmamentOracle;
        startTime = _startTime;

        empyrealPriceOne = 10 ** 18;
        empyrealPriceCeiling = (empyrealPriceOne * 101) / 100;
        seigniorageCalculator = _calculator;

        // First 18 epochs with 2.5% expansion
        bootstrapEpochs = 15;
        bootstrapSupplyExpansionPercent = 250;

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    function updateSeigniorageCalculator(
        ISeigniorageCalculator _calc
    ) external onlyController {
        seigniorageCalculator = _calc;
    }

    function setOracles(
        IOracle _empyrealOracle,
        IOracle _firmamentOracle
    ) external onlyController {
        empyrealOracle = _empyrealOracle;
        firmamentOracle = _firmamentOracle;
    }

    function setBootstrap(
        uint256 _bootstrapEpochs,
        uint256 _bootstrapSupplyExpansionPercent
    ) external onlyController {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(
            _bootstrapSupplyExpansionPercent >= 100 &&
                _bootstrapSupplyExpansionPercent <= 1000,
            "_bootstrapSupplyExpansionPercent: out of range"
        ); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setEnrichmentFund(
        address _enrichmentFund,
        uint256 _enrichmentFundSharedPercent
    ) external onlyController {
        require(_enrichmentFund != address(0), "zero");
        require(_enrichmentFundSharedPercent <= 1500, "out of range"); // <= 15%
        enrichmentFund = _enrichmentFund;
        enrichmentFundPercent = _enrichmentFundSharedPercent;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updatePrices() internal {
        try IOracle(empyrealOracle).update() {} catch {}
        try IOracle(firmamentOracle).update() {} catch {}
    }

    function getEmpyrealCirculatingSupply() public view returns (uint256) {
        IERC20 empyrealErc20 = IERC20(empyreal());
        return empyrealErc20.totalSupply();
    }

    function _sendToHorizon(uint256 _amount) internal {
        address _empyreal = empyreal();
        address _horizon = horizon();

        IBasisAsset(_empyreal).mint(address(this), _amount);

        uint256 _enrichmentFundSharedAmount = 0;
        if (enrichmentFundPercent > 0) {
            _enrichmentFundSharedAmount =
                (_amount * enrichmentFundPercent) /
                10000;
            IERC20(_empyreal).transfer(
                enrichmentFund,
                _enrichmentFundSharedAmount
            );
            emit EnrichmentFundFunded(
                block.timestamp,
                _enrichmentFundSharedAmount
            );
        }
        _amount -= _enrichmentFundSharedAmount;

        IERC20(_empyreal).safeApprove(_horizon, 0);
        IERC20(_empyreal).safeApprove(_horizon, _amount);
        IHorizon(_empyreal).allocateSeigniorage(_amount);

        emit HorizonFunded(block.timestamp, _amount);
    }

    function allocateSeigniorage()
        external
        onlyOneBlock
        checkCondition
        checkEpoch
    {
        _updatePrices();
        previousEpochEmpyrealPrice = getEmpyrealPrice();
        previousEpochFirmamentPrice = getFirmamentPrice();
        uint256 empyrealSupply = getEmpyrealCirculatingSupply();
        if (epoch < bootstrapEpochs) {
            _sendToHorizon(
                (empyrealSupply * bootstrapSupplyExpansionPercent) / 10000
            );
        } else {
            _sendToHorizon(
                seigniorageCalculator.calculateSeigniorage(
                    previousEpochEmpyrealPrice,
                    previousEpochFirmamentPrice,
                    empyrealSupply,
                    epoch
                )
            );
        }
    }

    function horizonAllocateSeigniorage(
        uint256 amount
    ) external onlyController {
        IHorizon(horizon()).allocateSeigniorage(amount);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyController {
        // do not allow to drain core tokens
        require(address(_token) != address(empyreal()), "empyreal");
        require(address(_token) != address(firmament()), "firmament");
        _token.safeTransfer(_to, _amount);
    }
}
