// SPDX-FileCopyrightText: 2023 StaFi <technical@stafi.io>

// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.7.6;

interface IrETH {
    /**
     * @return Amount of ETH for 1 rETH
     */
    function getExchangeRate() external view returns (uint256);
}