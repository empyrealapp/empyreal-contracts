// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/ITreasury.sol";
import "./types/AccessControlled.sol";

abstract contract ShareWrapper is AccessControlled {
    using SafeERC20 for IERC20;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function stakeFor(
        address _receiver,
        uint256 amount
    ) public virtual onlyController {
        _totalSupply += amount;
        _balances[_receiver] += amount;
        IERC20(firmament()).safeTransferFrom(msg.sender, address(this), amount);
    }

    function stake(uint256 amount) public virtual {
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        IERC20(firmament()).safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public virtual {
        uint256 memberShare = _balances[msg.sender];
        require(
            memberShare >= amount,
            "Horizon: withdraw request greater than staked amount"
        );
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        IERC20(firmament()).safeTransfer(msg.sender, amount);
    }
}

contract Horizon is ShareWrapper, ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    /* ========== DATA STRUCTURES ========== */

    struct PassengerSeat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct HorizonSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========== STATE VARIABLES ========== */

    // flags
    bool public initialized = false;

    mapping(address => PassengerSeat) public members;
    HorizonSnapshot[] public horizonHistory;

    uint256 public withdrawLockupEpochs;
    uint256 public rewardLockupEpochs;

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);

    /* ========== Modifiers =============== */

    modifier memberExists() {
        require(
            balanceOf(msg.sender) > 0,
            "Horizon: The member does not exist"
        );
        _;
    }

    modifier updateReward(address member) {
        if (member != address(0)) {
            PassengerSeat memory seat = members[member];
            seat.rewardEarned = earned(member);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            members[member] = seat;
        }
        _;
    }

    modifier notInitialized() {
        require(!initialized, "Horizon: already initialized");
        _;
    }

    constructor(address _authority) AccessControlled(IAuthority(_authority)) {}

    /* ========== GOVERNANCE ========== */

    function initialize() public notInitialized {
        HorizonSnapshot memory genesisSnapshot = HorizonSnapshot({
            time: block.number,
            rewardReceived: 0,
            rewardPerShare: 0
        });
        horizonHistory.push(genesisSnapshot);

        withdrawLockupEpochs = 6; // Lock for 6 epochs (48h) before release withdraw
        rewardLockupEpochs = 3; // Lock for 3 epochs (24h) before release claimReward

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    function setLockUp(
        uint256 _withdrawLockupEpochs,
        uint256 _rewardLockupEpochs
    ) external onlyController {
        require(
            _withdrawLockupEpochs >= _rewardLockupEpochs &&
                _withdrawLockupEpochs <= 56,
            "_withdrawLockupEpochs: out of range"
        ); // <= 2 week
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters

    function latestSnapshotIndex() public view returns (uint256) {
        return horizonHistory.length - 1;
    }

    function getLatestSnapshot()
        internal
        view
        returns (HorizonSnapshot memory)
    {
        return horizonHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(
        address member
    ) public view returns (uint256) {
        return members[member].lastSnapshotIndex;
    }

    function getLastSnapshotOf(
        address member
    ) internal view returns (HorizonSnapshot memory) {
        return horizonHistory[getLastSnapshotIndexOf(member)];
    }

    function canWithdraw(address member) external view returns (bool) {
        return
            members[member].epochTimerStart + withdrawLockupEpochs <= epoch();
    }

    function canClaimReward(address member) external view returns (bool) {
        return members[member].epochTimerStart + rewardLockupEpochs <= epoch();
    }

    function epoch() public view returns (uint256) {
        return ITreasury(treasury()).epoch();
    }

    function nextEpochPoint() external view returns (uint256) {
        return ITreasury(treasury()).nextEpochPoint();
    }

    function getEmpyrealPrice() external view returns (uint256) {
        return ITreasury(treasury()).getEmpyrealPrice();
    }

    // =========== Member getters

    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address member) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(member).rewardPerShare;

        return
            balanceOf(member) *
            (((latestRPS - storedRPS) / 1e18) + members[member].rewardEarned);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(
        uint256 amount
    ) public override onlyOneBlock updateReward(msg.sender) {
        require(amount > 0, "Horizon: Cannot stake 0");
        super.stake(amount);
        members[msg.sender].epochTimerStart = epoch(); // reset timer
        emit Staked(msg.sender, amount);
    }

    function stakeFor(
        address _recipient,
        uint256 amount
    ) public override onlyOneBlock onlyController updateReward(msg.sender) {
        require(amount > 0, "Horizon: Cannot stake 0");
        super.stakeFor(_recipient, amount);
        members[_recipient].epochTimerStart = epoch(); // reset timer
        emit Staked(_recipient, amount);
    }

    function withdraw(
        uint256 amount
    ) public override onlyOneBlock memberExists updateReward(msg.sender) {
        require(amount > 0, "Horizon: Cannot withdraw 0");
        require(
            members[msg.sender].epochTimerStart + withdrawLockupEpochs <=
                epoch(),
            "Horizon: still in withdraw lockup"
        );
        claimReward();
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
    }

    function claimReward() public updateReward(msg.sender) {
        uint256 reward = members[msg.sender].rewardEarned;
        if (reward > 0) {
            require(
                members[msg.sender].epochTimerStart + rewardLockupEpochs <=
                    epoch(),
                "Horizon: still in reward lockup"
            );
            members[msg.sender].epochTimerStart = epoch(); // reset timer
            members[msg.sender].rewardEarned = 0;
            IERC20(empyreal()).safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function allocateSeigniorage(uint256 amount) external onlyOneBlock {
        require(msg.sender == treasury(), "only treasury");

        require(amount > 0, "Horizon: Cannot allocate 0");
        require(
            totalSupply() > 0,
            "Horizon: Cannot allocate when totalSupply is 0"
        );

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS + ((amount * 1e18) / totalSupply());

        HorizonSnapshot memory newSnapshot = HorizonSnapshot({
            time: block.number,
            rewardReceived: amount,
            rewardPerShare: nextRPS
        });
        horizonHistory.push(newSnapshot);

        IERC20(empyreal()).safeTransferFrom(msg.sender, address(this), amount);
        emit RewardAdded(msg.sender, amount);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyController {
        // do not allow to drain core tokens
        require(address(_token) != empyreal(), "empyreal");
        require(address(_token) != firmament(), "firmament");
        _token.safeTransfer(_to, _amount);
    }
}
