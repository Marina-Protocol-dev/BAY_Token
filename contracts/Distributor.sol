// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Distributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20  public immutable token;
    uint256 public globalCap;        // 0 = unlimited
    uint256 public distributedTotal;

    address public distributor;

    mapping(address => uint256) public paid;

    event Distributed(uint256 indexed index, address indexed to, uint256 amount);
    event DistributedBatch(uint256 count, uint256 totalAmount);
    event CapUpdated(uint256 oldCap, uint256 newCap);
    event EmergencySweep(address indexed to, uint256 amount);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event DistributorChanged(address indexed previousDistributor, address indexed newDistributor);

    modifier onlyDistributor() {
        require(msg.sender == distributor, "not distributor");
        _;
    }

    constructor(address _token, address admin, address _distributor, uint256 _globalCap) {
        require(_token != address(0) && admin != address(0), "zero addr");
        require(_distributor != address(0), "zero distributor");

        token = IERC20(_token);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        distributor = _distributor;
        emit DistributorChanged(address(0), _distributor);

        globalCap = _globalCap;
    }

    function setGlobalCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newCap == 0 || newCap >= distributedTotal, "cap < distributed");
        emit CapUpdated(globalCap, newCap);
        globalCap = newCap;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    function sweep(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "bad to");
        token.safeTransfer(to, amount);
        emit EmergencySweep(to, amount);
    }

    function transferAdminOnly(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAdmin != address(0) && newAdmin != msg.sender, "bad admin");
        address prev = msg.sender;
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        _revokeRole(DEFAULT_ADMIN_ROLE, prev);
        emit AdminTransferred(prev, newAdmin);
    }

    function setDistributor(address newDistributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newDistributor != address(0), "zero distributor");
        address prev = distributor;
        require(newDistributor != prev, "same distributor");
        distributor = newDistributor;
        emit DistributorChanged(prev, newDistributor);
    }

    function remainingCap() external view returns (uint256) { return _remainingCap(); }
    function remainingBalance() external view returns (uint256) { return token.balanceOf(address(this)); }

    function _checkCap(uint256 addAmount) internal view {
        if (globalCap > 0) {
            require(distributedTotal + addAmount <= globalCap, "cap exceeded");
        }
    }

    function _remainingCap() internal view returns (uint256) {
        if (globalCap == 0) return type(uint256).max;
        if (distributedTotal >= globalCap) return 0;
        return globalCap - distributedTotal;
    }

    function distribute(address to, uint256 amount)
        public
        nonReentrant
        onlyDistributor
        whenNotPaused
    {
        require(to != address(0), "bad to");
        require(amount > 0, "zero amount");

        _checkCap(amount);
        require(token.balanceOf(address(this)) >= amount, "insufficient balance");

        distributedTotal += amount;
        paid[to] += amount;

        token.safeTransfer(to, amount);
        emit Distributed(0, to, amount);
    }

    function distributeBatch(address[] calldata tos, uint256[] calldata amounts)
        external
        nonReentrant
        onlyDistributor
        whenNotPaused
    {
        uint256 n = tos.length;
        require(n > 0 && n == amounts.length, "len");

        uint256 total;
        unchecked {
            for (uint256 i; i < n; ++i) {
                address to = tos[i];
                uint256 amt = amounts[i];
                require(to != address(0), "bad to");
                require(amt > 0, "zero amount");
                total += amt;
            }
        }

        _checkCap(total);
        require(token.balanceOf(address(this)) >= total, "insufficient balance");

        unchecked {
            for (uint256 i; i < n; ++i) {
                address to = tos[i];
                uint256 amt = amounts[i];

                distributedTotal += amt;
                paid[to] += amt;

                token.safeTransfer(to, amt);
                emit Distributed(i, to, amt);
            }
        }

        emit DistributedBatch(n, total);
    }
}
