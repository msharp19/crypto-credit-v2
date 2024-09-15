// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.21.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IKaijuFinanceLiquidStakingToken is IERC20 {
    function mint(address user, uint256 amount) external;
    function burn(address from, uint256 value) external;
}