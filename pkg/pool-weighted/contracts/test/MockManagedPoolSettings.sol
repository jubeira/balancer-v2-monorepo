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

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "../managed/ManagedPoolSettings.sol";

contract MockManagedPoolSettings is ManagedPoolSettings {
    constructor(
        NewPoolParams memory params,
        IProtocolFeePercentagesProvider protocolFeeProvider,
    ) ManagedPoolSettings(params, protocolFeeProvider) {
        // solhint-disable-previous-line no-empty-blocks
    }

    // Helpers to decode Pool state

    function getSwapFeePercentage() external view returns (uint256) {
        return ManagedPoolStorageLib.getSwapFeePercentage(_getPoolState());
    }

    function getGradualSwapFeeUpdateParams()
        external
        view
        returns (
            uint256 startTime,
            uint256 endTime,
            uint256 startSwapFeePercentage,
            uint256 endSwapFeePercentage
        )
    {
        return ManagedPoolStorageLib.getSwapFeeFields(_getPoolState());
    }

    // Mocked Functions

    function validateSwapFeePercentage(uint256 swapFeePercentage) external pure {
        _validateSwapFeePercentage(swapFeePercentage);
    }
}
