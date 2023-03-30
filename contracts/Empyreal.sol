// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./dex/interfaces/IUniswapV2Pair.sol";
import "./utils/Operator.sol";
import "./interfaces/ITransferHandler.sol";
import "./types/AccessControlled.sol";

contract Empyreal is ERC20Burnable, AccessControlled {
    // Distribution for initial offering
    uint256 public constant INITIAL_OFFERING_DISTRIBUTION = 33_333 ether;
    bool public initialOfferingDistributed = false;

    address private _operator;
    ITransferHandler public transferHandler;

    // exclude from fees and max transaction amount
    mapping(address => bool) internal _isExcludedFromFees;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping(address => bool) public automatedMarketMakerPairs;
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event ExcludeFromFees(address account, bool excluded);

    /**
     * @notice Constructs the ERC-20 contract.
     * @param _transferHandler address of the transfer extension
     */
    constructor(
        ITransferHandler _transferHandler,
        IAuthority _authority
    ) ERC20("Empyreal", "EMP") AccessControlled(_authority) {
        _mint(msg.sender, 1 ether);
        transferHandler = _transferHandler;
    }

    /**
     * @notice distribute tokens for the initial offering (only once)
     */
    function distributeInitialOffering(
        address _offeringContract
    ) external onlyController {
        require(_offeringContract != address(0), "!_offeringContract");
        require(!initialOfferingDistributed, "only distribute once");
        _mint(_offeringContract, INITIAL_OFFERING_DISTRIBUTION);
        initialOfferingDistributed = true;
    }

    /**
     * @notice Operator mints to a recipient
     * @param account The address of the recipient
     * @param amount The amount to mint
     */
    function mint(address account, uint256 amount) public onlyEmpyrealMinter {
        _mint(account, amount);
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function burnFrom(
        address account,
        uint256 amount
    ) public override onlyController {
        super.burnFrom(account, amount);
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        uint256 currentAllowance = allowance(sender, _msgSender());
        require(
            currentAllowance >= amount,
            "ERC20: transfer amount exceeds allowance"
        );
        _approve(sender, _msgSender(), currentAllowance - amount);
        _transfer(sender, recipient, amount);
        return true;
    }

    /**
     * @notice this overrides the _transfer function to check for taxation
     * @notice the contract has an external calculator for the burn amount, but it is permanently set to burn the tax
     *         The way the tax is calculated can be modified, but it will always be burned.
     */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        if (!(_isExcludedFromFees[from] || _isExcludedFromFees[to])) {
            // take fee
            uint fees;
            uint _buyFees = transferHandler.buyFees();
            uint _sellFees = transferHandler.sellFees();

            // additional limitations on transfers
            transferHandler.checkTransfer(from, to, amount);

            if (automatedMarketMakerPairs[to] && _sellFees > 0) {
                fees += (amount * _sellFees) / 1000;
            } else if (automatedMarketMakerPairs[from] && _buyFees > 0) {
                fees += (amount * _buyFees) / 1000;
            }

            if (fees > 0) {
                (bool success, bytes memory _data) = address(transferHandler)
                    .delegatecall(
                        abi.encodeWithSignature(
                            "handleFees(address,address,uint256)",
                            from,
                            to,
                            amount
                        )
                    );
                require(success, "failed to handle fees");
            }
            amount -= fees;
        }
        super._transfer(from, to, amount);
    }

    function updateTransferHandler(
        ITransferHandler _transferHandler
    ) external onlyController {
        transferHandler = _transferHandler;
    }

    function setAutomatedMarketMakerPair(
        address pair,
        bool value
    ) public onlyController {
        automatedMarketMakerPairs[pair] = value;
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function excludeFromFees(
        address account,
        bool excluded
    ) public onlyController {
        _isExcludedFromFees[account] = excluded;
        emit ExcludeFromFees(account, excluded);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyController {
        _token.transfer(_to, _amount);
    }
}
