// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.7.6;

import "../proxy/TransparentUpgradeableProxy.sol";

contract StakePortalProxy is TransparentUpgradeableProxy {
    constructor(address _proxyTo, address admin_, bytes memory _data) TransparentUpgradeableProxy(_proxyTo, admin_, _data) {}
}
