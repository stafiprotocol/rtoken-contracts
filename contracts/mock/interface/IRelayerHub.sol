pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only
interface IRelayerHub {
  function isRelayer(address sender) external view returns (bool);
}


