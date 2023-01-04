pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only
interface ILightClient {

  function isHeaderSynced(uint64 height) external view returns (bool);

  function getAppHash(uint64 height) external view returns (bytes32);

  function getSubmitter(uint64 height) external view returns (address payable);

}