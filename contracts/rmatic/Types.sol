pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only

struct PoolInfo {
    uint256 bond;
    uint256 unbond;
    uint256 active;
}

struct UnstakeInfo {
    uint256 era;
    address pool;
    address receiver;
    uint256 amount;
}
