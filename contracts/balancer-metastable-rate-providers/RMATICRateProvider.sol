// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.7.6;

import "./interfaces/IRateProvider.sol";
import "./interfaces/IrMATICRate.sol";

/**
 * @title rMATIC Rate Provider
 * @notice Returns the value of MATIC in terms of rMATIC
 */
contract RMATICRateProvider is IRateProvider {
    IrMATICRate public immutable rMATICRate;

    constructor(IrMATICRate _rMATICRate) {
        rMATICRate = _rMATICRate;
    }

    /**
     * @return the value of MATIC in terms of rMATIC
     */
    function getRate() external view override returns (uint256) {
        return rMATICRate.getRate();
    }
}
