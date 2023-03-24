// SPDX-FileCopyrightText: 2023 StaFi <technical@stafi.io>

// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.7.6;

interface IrMATICRate {
    /**
     * @return Amount of MATIC for 1 rMATIC
     */
    function getRate() external view returns (uint256);
}
