// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "./types/AccessControlled.sol";

interface IDelegate {
    function delegate(address delegatee) external;
}

contract EmpyrealGovernanceArbitrum is AccessControlled, ERC20Burnable {
    //  0x912CE59144191C1204E64559FE8253a0e49E6548
    IERC20 public arbitrum;

    constructor(
        IAuthority _authority,
        IERC20 _arbitrum
    )
        AccessControlled(_authority)
        ERC20("Empyreal Governance Arbitrum", "egARB")
    {
        arbitrum = _arbitrum;
    }

    function deposit(uint amount) external {
        arbitrum.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
    }

    function withdraw(uint amount) external {
        _burn(msg.sender, amount);
        arbitrum.transfer(msg.sender, amount);
    }

    function delegateVotingAuthority() external {
        IDelegate(address(arbitrum)).delegate(authority.controller());
    }
}
