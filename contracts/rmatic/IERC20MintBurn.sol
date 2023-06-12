pragma solidity 0.7.6;

// SPDX-License-Identifier: GPL-3.0-only

interface IERC20MintBurn {
    function mint(address to, uint256 amount) external;

    function burnFrom(address account, uint256 amount) external;
}
