pragma solidity >=0.7.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRToken is IERC20 {
    function mint(uint256 _amount, address _to) external;
    function burn(uint256 _amount, address _to) external;
}