pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only
interface ICrossChain {
    /**
     * @dev Send package to Binance Chain
     */
    function sendSynPackage(uint8 channelId, bytes calldata msgBytes, uint256 relayFee) external;
}
