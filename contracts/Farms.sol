// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./dex/interfaces/IUniswapV2Pair.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IFarmBurnHandler.sol";
import "./interfaces/IStaging.sol";
import "./types/AccessControlled.sol";

contract FirmamentRewardPool is AccessControlled {
    using SafeERC20 for IERC20;

    IStaging public staging;
    bool enabledEmergencyWithdraw;
    uint public migrationStartTime;
    uint public fundsMigrationDelay = 4 days;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. Firmanent to distribute per block.
        uint256 lastRewardTime; // Last time that Firmanent distribution occurs.
        uint256 accFirmamentPerShare; // Accumulated Firmanent per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
    }

    IFarmBurnHandler burnHandler;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The time when firmament mining starts.
    uint256 public poolStartTime;

    // The time when firmament mining ends.
    uint256 public poolEndTime;

    uint256 public firmamentPerSecond = 0.0017 ether; // 54490 firmament / (370 days * 24h * 60min * 60s)
    uint256 public runningTime = 370 days; // 370 days
    uint256 public constant TOTAL_REWARDS = 59500 ether;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Staging(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event RewardPaid(address indexed user, uint256 amount);
    event EmergencyWithdrawEnabled();
    event ProposeRewardMigration();
    event RewardMigration();
    event UpdateStaging(IStaging _staging);
    event UpdateFirmament(uint);

    constructor(
        uint256 _poolStartTime,
        IAuthority _authority
    ) AccessControlled(_authority) {
        require(block.timestamp < _poolStartTime, "late");
        poolStartTime = _poolStartTime;
        poolEndTime = poolStartTime + runningTime;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(
                poolInfo[pid].token != _token,
                "FirmamentRewardPool: existing pool?"
            );
        }
    }

    // Add a new token to the pool. Can only be called by the controller.
    function add(
        uint256 _allocPoint,
        IERC20 _token,
        bool _withUpdate,
        uint256 _lastRewardTime
    ) public onlyController {
        checkPoolDuplicate(_token);
        if (_withUpdate) {
            massUpdatePools();
        }
        if (block.timestamp < poolStartTime) {
            if (_lastRewardTime == 0) {
                _lastRewardTime = poolStartTime;
            } else {
                if (_lastRewardTime < poolStartTime) {
                    _lastRewardTime = poolStartTime;
                }
            }
        } else {
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        bool _isStarted = (_lastRewardTime <= poolStartTime) ||
            (_lastRewardTime <= block.timestamp);
        poolInfo.push(
            PoolInfo({
                token: _token,
                allocPoint: _allocPoint,
                lastRewardTime: _lastRewardTime,
                accFirmamentPerShare: 0,
                isStarted: _isStarted
            })
        );
        if (_isStarted) {
            totalAllocPoint += _allocPoint;
        }
    }

    // Update the given pool's Firmament allocation point. Can only be called by the controller.
    function set(uint256 _pid, uint256 _allocPoint) public onlyController {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint - pool.allocPoint + _allocPoint;
        }
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(
        uint256 _fromTime,
        uint256 _toTime
    ) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime)
                return (poolEndTime - poolStartTime) * firmamentPerSecond;
            return (poolEndTime - _fromTime) * firmamentPerSecond;
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime)
                return (_toTime - poolStartTime) * firmamentPerSecond;
            return (_toTime - _fromTime) * firmamentPerSecond;
        }
    }

    function setFirmamentPerSecond(
        uint256 _firmamentPerSecond
    ) external onlyController {
        firmamentPerSecond = _firmamentPerSecond;
        emit UpdateFirmament(_firmamentPerSecond);
    }

    // View function to see pending FIRMAMENT on frontend.
    function pendingShare(
        uint256 _pid,
        address _user
    ) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accFirmamentPerShare = pool.accFirmamentPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(
                pool.lastRewardTime,
                block.timestamp
            );
            uint256 _firmReward = (_generatedReward * pool.allocPoint) /
                totalAllocPoint;
            accFirmamentPerShare += (_firmReward * 1e18) / tokenSupply;
        }
        return ((user.amount * accFirmamentPerShare) / 1e18) - user.rewardDebt;
    }

    // Update reward variables for all pools
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint += pool.allocPoint;
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(
                pool.lastRewardTime,
                block.timestamp
            );
            uint256 _firmamentReward = (_generatedReward * pool.allocPoint) /
                totalAllocPoint;
            pool.accFirmamentPerShare +=
                (_firmamentReward * 1e18) /
                tokenSupply;
        }
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit tokens
    function deposit(uint256 _pid, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = ((user.amount * pool.accFirmamentPerShare) /
                1e18) - user.rewardDebt;
            if (_pending > 0) {
                safeFirmamentTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);
            user.amount += _amount;
        }
        user.rewardDebt = (user.amount * pool.accFirmamentPerShare) / 1e18;
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw tokens.
    function withdraw(uint256 _pid, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = (user.amount * pool.accFirmamentPerShare) /
            1e18 -
            user.rewardDebt;
        if (_pending > 0) {
            safeFirmamentTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount -= _amount;
            pool.token.safeTransfer(address(staging), _amount);
            staging.deposit(_pid, _sender, _amount);
        }
        user.rewardDebt = (user.amount * pool.accFirmamentPerShare) / 1e18;
        emit Withdraw(_sender, _pid, _amount);
    }

    // // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        require(enabledEmergencyWithdraw, "emergency withdraw disabled");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe transfer function, just in case if rounding error causes pool to not have enough firmament
    function safeFirmamentTransfer(address _to, uint256 _amount) internal {
        IERC20 _firmament = IERC20(firmament());
        uint256 _firmamentBal = _firmament.balanceOf(address(this));
        if (_firmamentBal > 0) {
            if (_amount > _firmamentBal) {
                _firmament.safeTransfer(_to, _firmamentBal);
            } else {
                _firmament.safeTransfer(_to, _amount);
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 amount,
        address to
    ) external onlyController {
        if (block.timestamp < poolEndTime + 90 days) {
            // do not allow to drain core token (tSHARE or lps) if less than 90 days after pool ends
            require(address(_token) != firmament(), "firmament");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "pool.token");
            }
        }
        _token.safeTransfer(to, amount);
    }

    function proposeMigrateRewards() external onlyController {
        /// initiate migration of yield token
        migrationStartTime = block.timestamp;
        emit ProposeRewardMigration();
    }

    function setStaging(IStaging _staging) external onlyController {
        staging = _staging;
        emit UpdateStaging(_staging);
    }

    function migrateRewards(address _recipient) external onlyController {
        /// this allows the funds to be migrated after a delay on the event
        /// that a new yield strategy is approved by the community
        require(migrationStartTime != 0, "migration not initiated");
        require(
            migrationStartTime + 10 days < block.timestamp,
            "migration expired"
        );
        require(
            migrationStartTime + fundsMigrationDelay < block.timestamp,
            "delay not met yet"
        );
        migrationStartTime = block.timestamp;
        safeFirmamentTransfer(_recipient, type(uint).max);
        emit RewardMigration();
    }

    function setBurnHandler(IFarmBurnHandler _handler) external onlyController {
        burnHandler = _handler;
    }

    function enableEmergencyWithdraw(bool isEnabled) external onlyController {
        enabledEmergencyWithdraw = isEnabled;
        emit EmergencyWithdrawEnabled();
    }
}
