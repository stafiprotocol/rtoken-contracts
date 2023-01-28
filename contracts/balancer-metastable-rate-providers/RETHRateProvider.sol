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
import "./interfaces/IrETH.sol";

/**
 * @title rETH Rate Provider
 * @notice Returns the value of ETH in terms of rETH
 */
contract WstETHRateProvider is IRateProvider {
    IrETH public immutable rETH;

    constructor(IrETH _rETH) {
        rETH = _rETH;
    }

    /**
     * @return the value of ETH in terms of rETH
     */
    function getRate() external view override returns (uint256) {
        return rETH.getExchangeRate();
    }
}
