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

import "@balancer-labs/v2-solidity-utils/contracts/math/FixedPoint.sol";
import "@balancer-labs/v2-solidity-utils/contracts/helpers/InputHelpers.sol";
import "@balancer-labs/v2-solidity-utils/contracts/helpers/WordCodec.sol";

import "@balancer-labs/v2-pool-utils/contracts/BaseGeneralPool.sol";

import "./StableMath.sol";
import "./StablePoolUserDataHelpers.sol";

contract StablePool is BaseGeneralPool, StableMath {
    using FixedPoint for uint256;
    using StablePoolUserDataHelpers for bytes;
    using WordCodec for bytes32;

    // This contract uses timestamps to slowly update its Amplification parameter over time. These changes must occur
    // over a minimum time period much larger than the blocktime, making timestamp manipulation a non-issue.
    // solhint-disable not-rely-on-time

    // Amplication factor changes must happen over a minimum period of one day, and can at most divide or multiple the
    // current value by 10.
    uint256 private constant _MIN_UPDATE_TIME = 1 days;
    uint256 private constant _MAX_AMP_UPDATE_FACTOR = 10;

    bytes32 private _packedAmplificationData;

    event AmpUpdateStarted(uint256 startValue, uint256 endValue, uint256 startTime, uint256 endTime);
    event AmpUpdateStopped(uint256 currentValue);

    uint256 private _lastInvariant;

    enum JoinKind { INIT, EXACT_TOKENS_IN_FOR_BPT_OUT, TOKEN_IN_FOR_EXACT_BPT_OUT }
    enum ExitKind { EXACT_BPT_IN_FOR_ONE_TOKEN_OUT, EXACT_BPT_IN_FOR_TOKENS_OUT, BPT_IN_FOR_EXACT_TOKENS_OUT }

    constructor(
        IVault vault,
        string memory name,
        string memory symbol,
        IERC20[] memory tokens,
        uint256 amplificationParameter,
        uint256 swapFeePercentage,
        uint256 pauseWindowDuration,
        uint256 bufferPeriodDuration,
        address owner
    )
        BaseGeneralPool(
            vault,
            name,
            symbol,
            tokens,
            new address[](tokens.length),
            swapFeePercentage,
            pauseWindowDuration,
            bufferPeriodDuration,
            owner
        )
    {
        _require(amplificationParameter >= _MIN_AMP, Errors.MIN_AMP);
        _require(amplificationParameter <= _MAX_AMP, Errors.MAX_AMP);

        _require(tokens.length <= _MAX_STABLE_TOKENS, Errors.MAX_STABLE_TOKENS);

        _setAmplificationData(
            uint64(amplificationParameter),
            uint64(amplificationParameter),
            uint64(block.timestamp),
            uint64(block.timestamp)
        );
    }

    // Base Pool handlers

    // Swap

    function _onSwapGivenIn(
        SwapRequest memory swapRequest,
        uint256[] memory balances,
        uint256 indexIn,
        uint256 indexOut
    ) internal view virtual override whenNotPaused returns (uint256) {
        (uint256 currentAmp, ) = getAmplificationParameter();

        uint256 amountOut = StableMath._calcOutGivenIn(currentAmp, balances, indexIn, indexOut, swapRequest.amount);

        return amountOut;
    }

    function _onSwapGivenOut(
        SwapRequest memory swapRequest,
        uint256[] memory balances,
        uint256 indexIn,
        uint256 indexOut
    ) internal view virtual override whenNotPaused returns (uint256) {
        (uint256 currentAmp, ) = getAmplificationParameter();
        uint256 amountIn = StableMath._calcInGivenOut(currentAmp, balances, indexIn, indexOut, swapRequest.amount);

        return amountIn;
    }

    // Initialize

    function _onInitializePool(
        bytes32,
        address,
        address,
        bytes memory userData
    ) internal virtual override whenNotPaused returns (uint256, uint256[] memory) {
        // It would be strange for the Pool to be paused before it is initialized, but for consistency we prevent
        // initialization in this case.

        StablePool.JoinKind kind = userData.joinKind();
        _require(kind == StablePool.JoinKind.INIT, Errors.UNINITIALIZED);

        uint256[] memory amountsIn = userData.initialAmountsIn();
        InputHelpers.ensureInputLengthMatch(amountsIn.length, _getTotalTokens());
        _upscaleArray(amountsIn, _scalingFactors());

        (uint256 currentAmp, ) = getAmplificationParameter();
        uint256 invariantAfterJoin = StableMath._calculateInvariant(currentAmp, amountsIn, true);

        // Set the initial BPT to the value of the invariant.
        uint256 bptAmountOut = invariantAfterJoin;

        _lastInvariant = invariantAfterJoin;

        return (bptAmountOut, amountsIn);
    }

    // Join

    function _onJoinPool(
        bytes32,
        address,
        address,
        uint256[] memory balances,
        uint256,
        uint256 protocolSwapFeePercentage,
        bytes memory userData
    )
        internal
        virtual
        override
        whenNotPaused
        returns (
            uint256,
            uint256[] memory,
            uint256[] memory
        )
    {
        // Due protocol swap fee amounts are computed by measuring the growth of the invariant between the previous join
        // or exit event and now - the invariant's growth is due exclusively to swap fees. This avoids spending gas to
        // calculate the fee amounts during each individual swap.
        uint256[] memory dueProtocolFeeAmounts = _getDueProtocolFeeAmounts(
            balances,
            _lastInvariant,
            protocolSwapFeePercentage
        );

        // Update current balances by subtracting the protocol fee amounts
        _mutateAmounts(balances, dueProtocolFeeAmounts, FixedPoint.sub);
        (uint256 bptAmountOut, uint256[] memory amountsIn) = _doJoin(balances, userData);

        // Update the invariant with the balances the Pool will have after the join, in order to compute the
        // protocol swap fee amounts due in future joins and exits.
        _lastInvariant = _invariantAfterJoin(balances, amountsIn);

        return (bptAmountOut, amountsIn, dueProtocolFeeAmounts);
    }

    function _doJoin(uint256[] memory balances, bytes memory userData)
        private
        view
        returns (uint256, uint256[] memory)
    {
        JoinKind kind = userData.joinKind();

        if (kind == JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT) {
            return _joinExactTokensInForBPTOut(balances, userData);
        } else if (kind == JoinKind.TOKEN_IN_FOR_EXACT_BPT_OUT) {
            return _joinTokenInForExactBPTOut(balances, userData);
        } else {
            _revert(Errors.UNHANDLED_JOIN_KIND);
        }
    }

    function _joinExactTokensInForBPTOut(uint256[] memory balances, bytes memory userData)
        private
        view
        returns (uint256, uint256[] memory)
    {
        (uint256[] memory amountsIn, uint256 minBPTAmountOut) = userData.exactTokensInForBptOut();
        InputHelpers.ensureInputLengthMatch(_getTotalTokens(), amountsIn.length);

        _upscaleArray(amountsIn, _scalingFactors());

        (uint256 currentAmp, ) = getAmplificationParameter();
        uint256 bptAmountOut = StableMath._calcBptOutGivenExactTokensIn(
            currentAmp,
            balances,
            amountsIn,
            totalSupply(),
            _swapFeePercentage
        );

        _require(bptAmountOut >= minBPTAmountOut, Errors.BPT_OUT_MIN_AMOUNT);

        return (bptAmountOut, amountsIn);
    }

    function _joinTokenInForExactBPTOut(uint256[] memory balances, bytes memory userData)
        private
        view
        returns (uint256, uint256[] memory)
    {
        (uint256 bptAmountOut, uint256 tokenIndex) = userData.tokenInForExactBptOut();
        // Note that there is no maximum amountIn parameter: this is handled by `IVault.joinPool`.

        _require(tokenIndex < _getTotalTokens(), Errors.OUT_OF_BOUNDS);

        uint256[] memory amountsIn = new uint256[](_getTotalTokens());
        (uint256 currentAmp, ) = getAmplificationParameter();
        amountsIn[tokenIndex] = StableMath._calcTokenInGivenExactBptOut(
            currentAmp,
            balances,
            tokenIndex,
            bptAmountOut,
            totalSupply(),
            _swapFeePercentage
        );

        return (bptAmountOut, amountsIn);
    }

    // Exit

    function _onExitPool(
        bytes32,
        address,
        address,
        uint256[] memory balances,
        uint256,
        uint256 protocolSwapFeePercentage,
        bytes memory userData
    )
        internal
        virtual
        override
        returns (
            uint256 bptAmountIn,
            uint256[] memory amountsOut,
            uint256[] memory dueProtocolFeeAmounts
        )
    {
        // Exits are not completely disabled while the contract is paused: proportional exits (exact BPT in for tokens
        // out) remain functional.

        if (_isNotPaused()) {
            // Due protocol swap fee amounts are computed by measuring the growth of the invariant between the previous
            // join or exit event and now - the invariant's growth is due exclusively to swap fees. This avoids
            // spending gas calculating fee amounts during each individual swap
            dueProtocolFeeAmounts = _getDueProtocolFeeAmounts(balances, _lastInvariant, protocolSwapFeePercentage);

            // Update current balances by subtracting the protocol fee amounts
            _mutateAmounts(balances, dueProtocolFeeAmounts, FixedPoint.sub);
        } else {
            // If the contract is paused, swap protocol fee amounts are not charged to avoid extra calculations and
            // reduce the potential for errors.
            dueProtocolFeeAmounts = new uint256[](_getTotalTokens());
        }

        (bptAmountIn, amountsOut) = _doExit(balances, userData);

        // Update the invariant with the balances the Pool will have after the exit, in order to compute the
        // protocol swap fee amounts due in future joins and exits.
        _lastInvariant = _invariantAfterExit(balances, amountsOut);

        return (bptAmountIn, amountsOut, dueProtocolFeeAmounts);
    }

    function _doExit(uint256[] memory balances, bytes memory userData)
        private
        view
        returns (uint256, uint256[] memory)
    {
        ExitKind kind = userData.exitKind();

        if (kind == ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT) {
            return _exitExactBPTInForTokenOut(balances, userData);
        } else if (kind == ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT) {
            return _exitExactBPTInForTokensOut(balances, userData);
        } else {
            // ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT
            return _exitBPTInForExactTokensOut(balances, userData);
        }
    }

    function _exitExactBPTInForTokenOut(uint256[] memory balances, bytes memory userData)
        private
        view
        whenNotPaused
        returns (uint256, uint256[] memory)
    {
        // This exit function is disabled if the contract is paused.

        (uint256 bptAmountIn, uint256 tokenIndex) = userData.exactBptInForTokenOut();
        // Note that there is no minimum amountOut parameter: this is handled by `IVault.exitPool`.

        _require(tokenIndex < _getTotalTokens(), Errors.OUT_OF_BOUNDS);

        // We exit in a single token, so initialize amountsOut with zeros
        uint256[] memory amountsOut = new uint256[](_getTotalTokens());

        // And then assign the result to the selected token
        (uint256 currentAmp, ) = getAmplificationParameter();
        amountsOut[tokenIndex] = StableMath._calcTokenOutGivenExactBptIn(
            currentAmp,
            balances,
            tokenIndex,
            bptAmountIn,
            totalSupply(),
            _swapFeePercentage
        );

        return (bptAmountIn, amountsOut);
    }

    function _exitExactBPTInForTokensOut(uint256[] memory balances, bytes memory userData)
        private
        view
        returns (uint256, uint256[] memory)
    {
        // This exit function is the only one that is not disabled if the contract is paused: it remains unrestricted
        // in an attempt to provide users with a mechanism to retrieve their tokens in case of an emergency.
        // This particular exit function is the only one that remains available because it is the simplest one, and
        // therefore the one with the lowest likelihood of errors.

        uint256 bptAmountIn = userData.exactBptInForTokensOut();
        // Note that there is no minimum amountOut parameter: this is handled by `IVault.exitPool`.

        uint256[] memory amountsOut = StableMath._calcTokensOutGivenExactBptIn(balances, bptAmountIn, totalSupply());
        return (bptAmountIn, amountsOut);
    }

    function _exitBPTInForExactTokensOut(uint256[] memory balances, bytes memory userData)
        private
        view
        whenNotPaused
        returns (uint256, uint256[] memory)
    {
        // This exit function is disabled if the contract is paused.

        (uint256[] memory amountsOut, uint256 maxBPTAmountIn) = userData.bptInForExactTokensOut();
        InputHelpers.ensureInputLengthMatch(amountsOut.length, _getTotalTokens());
        _upscaleArray(amountsOut, _scalingFactors());

        (uint256 currentAmp, ) = getAmplificationParameter();
        uint256 bptAmountIn = StableMath._calcBptInGivenExactTokensOut(
            currentAmp,
            balances,
            amountsOut,
            totalSupply(),
            _swapFeePercentage
        );
        _require(bptAmountIn <= maxBPTAmountIn, Errors.BPT_IN_MAX_AMOUNT);

        return (bptAmountIn, amountsOut);
    }

    // Helpers

    function _getDueProtocolFeeAmounts(
        uint256[] memory balances,
        uint256 previousInvariant,
        uint256 protocolSwapFeePercentage
    ) private view returns (uint256[] memory) {
        // Initialize with zeros
        uint256[] memory dueProtocolFeeAmounts = new uint256[](_getTotalTokens());

        // Early return if the protocol swap fee percentage is zero, saving gas.
        if (protocolSwapFeePercentage == 0) {
            return dueProtocolFeeAmounts;
        }

        // Instead of paying the protocol swap fee in all tokens proportionally, we will pay it in a single one. This
        // will reduce gas costs for single asset joins and exits, as at most only two Pool balances will change (the
        // token joined/exited, and the token in which fees will be paid).

        // The protocol fee is charged using the token with the highest balance in the pool.
        uint256 chosenTokenIndex = 0;
        uint256 maxBalance = balances[0];
        for (uint256 i = 1; i < _getTotalTokens(); ++i) {
            uint256 currentBalance = balances[i];
            if (currentBalance > maxBalance) {
                chosenTokenIndex = i;
                maxBalance = currentBalance;
            }
        }

        (uint256 currentAmp, ) = getAmplificationParameter();
        // Set the fee amount to pay in the selected token
        dueProtocolFeeAmounts[chosenTokenIndex] = StableMath._calcDueTokenProtocolSwapFeeAmount(
            currentAmp,
            balances,
            previousInvariant,
            chosenTokenIndex,
            protocolSwapFeePercentage
        );

        return dueProtocolFeeAmounts;
    }

    function _invariantAfterJoin(uint256[] memory balances, uint256[] memory amountsIn) private view returns (uint256) {
        _mutateAmounts(balances, amountsIn, FixedPoint.add);
        // This invariant is used only to compute the final balance when calculating the protocol fees. These are
        // rounded down, so we round the invariant up.
        (uint256 currentAmp, ) = getAmplificationParameter();
        return StableMath._calculateInvariant(currentAmp, balances, true);
    }

    function _invariantAfterExit(uint256[] memory balances, uint256[] memory amountsOut)
        private
        view
        returns (uint256)
    {
        _mutateAmounts(balances, amountsOut, FixedPoint.sub);
        // This invariant is used only to compute the final balance when calculating the protocol fees. These are
        // rounded down, so we round the invariant up.
        (uint256 currentAmp, ) = getAmplificationParameter();
        return StableMath._calculateInvariant(currentAmp, balances, true);
    }

    /**
     * @dev Mutates `amounts` by applying `mutation` with each entry in `arguments`.
     *
     * Equivalent to `amounts = amounts.map(mutation)`.
     */
    function _mutateAmounts(
        uint256[] memory toMutate,
        uint256[] memory arguments,
        function(uint256, uint256) pure returns (uint256) mutation
    ) private view {
        for (uint256 i = 0; i < _getTotalTokens(); ++i) {
            toMutate[i] = mutation(toMutate[i], arguments[i]);
        }
    }

    /**
     * @dev This function returns the appreciation of one BPT relative to the
     * underlying tokens. This starts at 1 when the pool is created and grows over time
     */
    function getRate() public view returns (uint256) {
        (, uint256[] memory balances, ) = getVault().getPoolTokens(getPoolId());

        // When calculating the current BPT rate, we may not have paid the protocol fees, therefore
        // the invariant should be smaller than its current value. Then, we round down overall.
        (uint256 currentAmp, ) = getAmplificationParameter();
        uint256 invariant = StableMath._calculateInvariant(currentAmp, balances, false);
        return invariant.divDown(totalSupply());
    }

    // Amplification

    function startAmplificationParameterUpdate(uint256 endValue, uint256 endTime) external authenticate {
        _require(endValue >= _MIN_AMP, Errors.MIN_AMP);
        _require(endValue <= _MAX_AMP, Errors.MAX_AMP);

        _require(endTime >= block.timestamp + _MIN_UPDATE_TIME, Errors.AMP_END_TIME_TOO_CLOSE);

        (uint256 currentValue, bool isUpdating) = getAmplificationParameter();
        _require(!isUpdating, Errors.AMP_ONGOING_UPDATE);

        if (endValue > currentValue) {
            _require(endValue <= currentValue * _MAX_AMP_UPDATE_FACTOR, Errors.AMP_FACTOR);
        } else {
            _require(endValue >= currentValue / _MAX_AMP_UPDATE_FACTOR, Errors.AMP_FACTOR);
        }

        _setAmplificationData(uint64(currentValue), uint64(endValue), uint64(block.timestamp), uint64(endTime));

        emit AmpUpdateStarted(currentValue, endValue, block.timestamp, endTime);
    }

    function stopAmplificationParameterUpdate() external authenticate {
        (uint256 currentValue, bool isUpdating) = getAmplificationParameter();
        _require(isUpdating, Errors.AMP_NO_ONGOING_UPDATE);

        _setAmplificationData(
            uint64(currentValue),
            uint64(currentValue),
            uint64(block.timestamp),
            uint64(block.timestamp)
        );
        emit AmpUpdateStopped(currentValue);
    }

    function _isOwnerOnlyAction(bytes32 actionId) internal view virtual override returns (bool) {
        return
            (actionId == getActionId(StablePool.startAmplificationParameterUpdate.selector)) ||
            (actionId == getActionId(StablePool.stopAmplificationParameterUpdate.selector)) ||
            super._isOwnerOnlyAction(actionId);
    }

    function getAmplificationParameter() public view returns (uint256 value, bool isUpdating) {
        (uint256 startValue, uint256 endValue, uint256 startTime, uint256 endTime) = _getAmplificationData();

        // Note that block.timestamp >= startTime, since startTime is set to the current time when an update starts

        if (block.timestamp < endTime) {
            isUpdating = true;
            if (endValue > startValue) {
                value = startValue + ((endValue - startValue) * (block.timestamp - startTime)) / (endTime - startTime);
            } else {
                value = startValue - ((startValue - endValue) * (block.timestamp - startTime)) / (endTime - startTime);
            }
        } else {
            isUpdating = false;
            value = endValue;
        }
    }

    function _setAmplificationData(
        uint64 startValue,
        uint64 endValue,
        uint64 startTime,
        uint64 endTime
    ) private {
        _packedAmplificationData =
            WordCodec.encodeUint(startValue, 0) |
            WordCodec.encodeUint(endValue, 64) |
            WordCodec.encodeUint(startTime, 64 * 2) |
            WordCodec.encodeUint(endTime, 64 * 3);
    }

    function _getAmplificationData()
        private
        view
        returns (
            uint256 startValue,
            uint256 endValue,
            uint256 startTime,
            uint256 endTime
        )
    {
        startValue = _packedAmplificationData.decodeUint64(0);
        endValue = _packedAmplificationData.decodeUint64(64);
        startTime = _packedAmplificationData.decodeUint64(64 * 2);
        endTime = _packedAmplificationData.decodeUint64(64 * 3);
    }
}