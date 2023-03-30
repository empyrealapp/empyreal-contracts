// SPDX-License-Identifier: MIT
pragma solidity ^0.8.1;

import "./interfaces/IAuthority.sol";
import "./types/AccessControlled.sol";

contract Authority is IAuthority {
    /* ========== EVENTS ========== */
    event TreasuryPushed(address indexed from, address indexed to);
    event ControllerPushed(
        address indexed from,
        address indexed to,
        bool _effectiveImmediately
    );
    event FirmamentSet(address);
    event EmpyrealSet(address);
    event ControllerPulled(address indexed from, address indexed to);
    event Renounced();

    /* ========== STATE VARIABLES ========== */

    address public controller;
    address public newController;
    address public treasury;
    address public firmament;
    address public empyreal;
    address public horizon;

    mapping(address => bool) _empyrealMinters;
    mapping(address => bool) _firmamentMinters;

    /* ========== Constructor ========== */

    constructor(address _controller) {
        controller = _controller;
    }

    /* ========== CONTROLLER ONLY ========== */

    function setFirmament(address _firmament) external {
        require(msg.sender == controller, "only controller");
        firmament = _firmament;
        emit FirmamentSet(_firmament);
    }

    function setHorizon(address _horizon) external {
        require(msg.sender == controller, "only controller");
        horizon = _horizon;
    }

    function setEmpyreal(address _empyreal) external {
        require(msg.sender == controller, "only controller");
        empyreal = _empyreal;
        emit EmpyrealSet(_empyreal);
    }

    function setTreasury(address _newTreasury) external {
        require(msg.sender == controller, "only controller");
        treasury = _newTreasury;
        _empyrealMinters[treasury] = true;
        emit TreasuryPushed(treasury, _newTreasury);
    }

    function setEmpyrealMinter(address _minterAddress, bool isMinter) external {
        require(msg.sender == controller, "only controller");
        _empyrealMinters[_minterAddress] = isMinter;
    }

    function setFirmamentMinter(
        address _minterAddress,
        bool isMinter
    ) external {
        require(msg.sender == controller, "only controller");
        _firmamentMinters[_minterAddress] = isMinter;
    }

    function pushController(
        address _newController,
        bool _effectiveImmediately
    ) external {
        require(msg.sender == controller, "only controller");

        if (_effectiveImmediately) controller = _newController;
        newController = _newController;
        emit ControllerPushed(controller, newController, _effectiveImmediately);
    }

    /* ========== PENDING ROLE ONLY ========== */

    function pullController() external {
        require(msg.sender == newController, "!newController");
        emit ControllerPulled(controller, newController);
        controller = newController;
    }

    /* ========= VIEW ======== */

    function empyrealMinters(address _minter) external view returns (bool) {
        return _empyrealMinters[_minter];
    }

    function firmamentMinters(address _minter) external view returns (bool) {
        return _firmamentMinters[_minter];
    }
}
