pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only
interface IParamSubscriber {
    function updateParam(string calldata key, bytes calldata value) external;
}