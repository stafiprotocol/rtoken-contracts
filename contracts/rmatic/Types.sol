pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only

struct UnstakeInfo {
    address pool;
    uint256 validator;
    address receiver;
    uint256 amount;
    uint256 nonce;
}
