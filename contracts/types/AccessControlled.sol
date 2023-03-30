// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import "../interfaces/IAuthority.sol";

abstract contract AccessControlled {
    /* ========== EVENTS ========== */
    event AuthorityUpdated(IAuthority indexed authority);
    string UNAUTHORIZED = "UNAUTHORIZED"; // save gas

    /* ========== STATE VARIABLES ========== */
    IAuthority public authority;

    /* ========== Constructor ========== */

    constructor(IAuthority _authority) {
        authority = _authority;
        emit AuthorityUpdated(_authority);
    }

    /* ========== MODIFIERS ========== */

    modifier onlyTreasury() {
        require(msg.sender == authority.treasury(), UNAUTHORIZED);
        _;
    }

    modifier onlyController() {
        require(msg.sender == authority.controller(), UNAUTHORIZED);
        _;
    }

    modifier onlyEmpyrealMinter() {
        require(authority.empyrealMinters(msg.sender), UNAUTHORIZED);
        _;
    }

    modifier onlyFirmamentMinter() {
        require(authority.firmamentMinters(msg.sender), UNAUTHORIZED);
        _;
    }

    /* ========== GOV ONLY ========== */

    function setAuthority(IAuthority _newAuthority) external onlyController {
        authority = _newAuthority;
        emit AuthorityUpdated(_newAuthority);
    }

    function empyreal() public view returns (address) {
        return authority.empyreal();
    }

    function firmament() public view returns (address) {
        return authority.firmament();
    }

    function horizon() public view returns (address) {
        return authority.horizon();
    }

    function treasury() public view returns (address) {
        return authority.treasury();
    }
}
