// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.7.6;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/TransparentUpgradeableProxy.sol";

contract MultisigProxy is TransparentUpgradeableProxy {
    constructor(
        address _proxyTo,
        address admin_,
        bytes memory _data
    ) TransparentUpgradeableProxy(_proxyTo, admin_, _data) {}
}
