// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./types/AccessControlled.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IFarmBurnHandler.sol";

contract Staging is AccessControlled {
    using SafeERC20 for IERC20;

    event UpdateTaxFloor(uint floor);
    event UpdateBurnHandler(IFarmBurnHandler _handler);

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
    }
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 withdrawTime;
    }
    struct PoolPegTax {
        bool isTaxable;
        bool isToken0;
        uint multiplier; // 100 is 1%
    }

    IFarmBurnHandler public burnHandler;
    uint public taxFloor = 1e18;
    mapping(uint => PoolPegTax) public poolPegTax;
    uint public lockupTime = 3 days;
    address public farm;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // max of 10 pools, should be nowhere near that limit
    PoolInfo[10] public poolInfo;

    uint public unlockTime;
    uint public unlockDelay = 7 days;

    constructor(
        address _farm,
        IAuthority _authority
    ) AccessControlled(_authority) {
        farm = _farm;
    }

    function deposit(uint _pid, address recipient, uint amount) external {
        require(msg.sender == farm, "only farm");
        userInfo[_pid][recipient].amount += amount;
        userInfo[_pid][recipient].withdrawTime = block.timestamp;
    }

    function claim(uint _pid, uint _amount) external {
        address _sender = msg.sender;

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(
            user.withdrawTime + lockupTime < block.timestamp,
            "still locked up"
        );
        require(_amount > 0, "claiming 0");
        require(_amount <= user.amount, "claiming more than balance");
        uint currentPrice = ITreasury(treasury()).getEmpyrealPrice();

        if (currentPrice > taxFloor || !poolPegTax[_pid].isTaxable) {
            user.amount -= _amount;
            pool.token.safeTransfer(_sender, _amount);
        } else {
            user.amount -= _amount;
            pool.token.safeTransfer(address(burnHandler), _amount);
            burnHandler.handleWithdraw(
                address(pool.token),
                currentPrice,
                msg.sender,
                poolPegTax[_pid].multiplier,
                poolPegTax[_pid].isToken0
            );
        }
    }

    function updateLockupTime(uint newTime) external onlyController {
        lockupTime = newTime;
    }

    function addPool(uint _pid, IERC20 _token) external onlyController {
        poolInfo[_pid] = PoolInfo({token: _token});
    }

    function setFarm(address _farm) external onlyController {
        farm = _farm;
    }

    function setTaxFloor(uint _taxFloor) external onlyController {
        taxFloor = _taxFloor;
        emit UpdateTaxFloor(taxFloor);
    }

    function setIsTaxablePair(
        uint pid,
        PoolPegTax memory _pegTax
    ) external onlyController {
        poolPegTax[pid] = _pegTax;
    }

    function setBurnHandler(IFarmBurnHandler _handler) external onlyController {
        burnHandler = _handler;
        emit UpdateBurnHandler(_handler);
    }

    function setUnlock() external onlyController {
        unlockTime = block.timestamp;
    }

    function unlock(IERC20 _token, uint _amount) external onlyController {
        require(unlockTime + unlockDelay < block.timestamp, "not ready yet");
        _token.transfer(authority.controller(), _amount);
    }
}
