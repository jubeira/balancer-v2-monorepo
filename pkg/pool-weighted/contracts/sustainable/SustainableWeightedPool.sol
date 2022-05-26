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

import "../BaseWeightedPool.sol";
import "../InvariantGrowthProtocolFeesWithYield.sol";
import "@balancer-labs/v2-pool-utils/contracts/rates/PriceRateCache.sol";
import "@balancer-labs/v2-pool-utils/contracts/interfaces/IRateProvider.sol";
import "hardhat/console.sol";


/**
* @dev SustainableWeightedPool is a special type of weighted pool that
* accomodates interest bearing tokens by incorporating rate providers
* into a weighted pool invariant
*/
contract SustainableWeightedPool is BaseWeightedPool, InvariantGrowthProtocolFeesWithYield {
    using FixedPoint for uint256;
    using PriceRateCache for bytes32;

    uint256 private constant _MAX_TOKENS = 20;
    mapping(IERC20 => bytes32) private _tokenRateCaches;

    IRateProvider internal immutable _rateProvider0;
    IRateProvider internal immutable _rateProvider1;
    IRateProvider internal immutable _rateProvider2;
    IRateProvider internal immutable _rateProvider3;
    IRateProvider internal immutable _rateProvider4;

    uint256 private immutable _totalTokens;

    IERC20 internal immutable _token0;
    IERC20 internal immutable _token1;
    IERC20 internal immutable _token2;
    IERC20 internal immutable _token3;
    IERC20 internal immutable _token4;

    uint256 internal immutable _scalingFactor0;
    uint256 internal immutable _scalingFactor1;
    uint256 internal immutable _scalingFactor2;
    uint256 internal immutable _scalingFactor3;
    uint256 internal immutable _scalingFactor4;

    uint256 internal immutable _normalizedWeight0;
    uint256 internal immutable _normalizedWeight1;
    uint256 internal immutable _normalizedWeight2;
    uint256 internal immutable _normalizedWeight3;
    uint256 internal immutable _normalizedWeight4;

    event TokenRateCacheUpdated(IERC20 indexed token, uint256 rate);
    event TokenRateProviderSet(IERC20 indexed token, IRateProvider indexed provider, uint256 cacheDuration);

    struct NewPoolParams {
        IVault vault;
        string name;
        string symbol;
        IERC20[] tokens;
        uint256[] normalizedWeights;
        address[] assetManagers;
        IRateProvider[] rateProviders;
        uint256[] tokenRateCacheDurations;
        uint256 swapFeePercentage;
        uint256 pauseWindowDuration;
        uint256 bufferPeriodDuration;
        address owner;
    }

    constructor(
      NewPoolParams memory params
    )
        BaseWeightedPool(
          params.vault,
          params.name,
          params.symbol,
          params.tokens,
          params.assetManagers,
          params.swapFeePercentage,
          params.pauseWindowDuration,
          params.bufferPeriodDuration,
          params.owner
       )
       {

        uint256 numTokens = params.tokens.length;

        InputHelpers.ensureInputLengthMatch(
            numTokens,
            params.rateProviders.length,
            params.tokenRateCacheDurations.length
        );

        _totalTokens = numTokens;


        // Ensure each normalized weight is above the minimum
        uint256 normalizedSum = 0;
        for (uint8 i = 0; i < numTokens; i++) {
            uint256 normalizedWeight = params.normalizedWeights[i];

            _require(normalizedWeight >= WeightedMath._MIN_WEIGHT, Errors.MIN_WEIGHT);
            normalizedSum = normalizedSum.add(normalizedWeight);
        }
        // Ensure that the normalized weights sum to ONE
        _require(normalizedSum == FixedPoint.ONE, Errors.NORMALIZED_WEIGHT_INVARIANT);

        _normalizedWeight0 = params.normalizedWeights[0];
        _normalizedWeight1 = params.normalizedWeights[1];
        _normalizedWeight2 = numTokens > 2 ? params.normalizedWeights[2] : 0;
        _normalizedWeight3 = numTokens > 3 ? params.normalizedWeights[3] : 0;
        _normalizedWeight4 = numTokens > 4 ? params.normalizedWeights[4] : 0;

        // Immutable variables cannot be initialized inside an if statement, so we must do conditional assignments
        _token0 = params.tokens[0];
        _token1 = params.tokens[1];
        _token2 = numTokens > 2 ? params.tokens[2] : IERC20(0);
        _token3 = numTokens > 3 ? params.tokens[3] : IERC20(0);
        _token4 = numTokens > 4 ? params.tokens[4] : IERC20(0);

        _scalingFactor0 = _computeScalingFactor(params.tokens[0]);
        _scalingFactor1 = _computeScalingFactor(params.tokens[1]);
        _scalingFactor2 = numTokens > 2 ? _computeScalingFactor(params.tokens[2]) : 0;
        _scalingFactor3 = numTokens > 3 ? _computeScalingFactor(params.tokens[3]) : 0;
        _scalingFactor4 = numTokens > 4 ? _computeScalingFactor(params.tokens[4]) : 0;

        for (uint256 i = 0; i < params.tokens.length; i++) {
            if (params.rateProviders[i] != IRateProvider(0)) {
                _updateTokenRateCache(params.tokens[i], params.rateProviders[i], params.tokenRateCacheDurations[i]);
                emit TokenRateProviderSet(params.tokens[i], params.rateProviders[i], params.tokenRateCacheDurations[i]);
            }
        }


        // The rate providers are stored as immutable state variables, and for simplicity when accessing those we'll
        // reference them by token index in the full base tokens

        IRateProvider[] memory tokensAndBPTRateProviders = new IRateProvider[](params.tokens.length);
        for (uint256 i = 0; i < tokensAndBPTRateProviders.length; ++i) {
            tokensAndBPTRateProviders[i] = params.rateProviders[i];
        }

        // Immutable variables cannot be initialized inside an if statement, so we must do conditional assignments
        _rateProvider0 = (tokensAndBPTRateProviders.length > 0) ? tokensAndBPTRateProviders[0] : IRateProvider(0);
        _rateProvider1 = (tokensAndBPTRateProviders.length > 1) ? tokensAndBPTRateProviders[1] : IRateProvider(0);
        _rateProvider2 = (tokensAndBPTRateProviders.length > 2) ? tokensAndBPTRateProviders[2] : IRateProvider(0);
        _rateProvider3 = (tokensAndBPTRateProviders.length > 3) ? tokensAndBPTRateProviders[3] : IRateProvider(0);
        _rateProvider4 = (tokensAndBPTRateProviders.length > 4) ? tokensAndBPTRateProviders[4] : IRateProvider(0);
     }

     function updateAllTokenRateCaches() internal {
        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(getPoolId());
        for (uint256 i = 0; i < tokens.length; i++) {
          updateTokenRateCache(tokens[i]);
        }
     }

    /**
     * @dev Forces a rate cache hit for a token.
     * It will revert if the requested token does not have an associated rate provider.
     */
    function updateTokenRateCache(IERC20 token) public {
        IRateProvider provider = _getRateProvider(token);
        _require(address(provider) != address(0), Errors.TOKEN_DOES_NOT_HAVE_RATE_PROVIDER);
        uint256 duration = _tokenRateCaches[token].getDuration();
        _updateTokenRateCache(token, provider, duration);
    }

    /**
     * @dev Caches token rates if necessary
     */
    function _cacheTokenRatesIfNecessary() internal {
        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(getPoolId());
        for (uint256 i = 0; i < tokens.length; i++) {
          _cacheTokenRateIfNecessary(tokens[i]);
        }
    }

    /**
     * @dev Caches the rate for a token if necessary. It ignores the call if there is no provider set.
     */
    function _cacheTokenRateIfNecessary(IERC20 token) internal {
        bytes32 cache = _tokenRateCaches[token];
        if (cache != bytes32(0)) {
            (uint256 duration, uint256 expires) = _tokenRateCaches[token].getTimestamps();
            if (block.timestamp > expires) {
                // solhint-disable-previous-line not-rely-on-time
                _updateTokenRateCache(token, _getRateProvider(token), duration);
            }
        }
    }

    /**
     * @dev Internal function to update a token rate cache for a known provider and duration.
     * It trusts the given values, and does not perform any checks.
     */
    function _updateTokenRateCache(
        IERC20 token,
        IRateProvider provider,
        uint256 duration
    ) private {
        uint256 rate = provider.getRate();

        bytes32 cache = PriceRateCache.encode(rate, duration);
        _tokenRateCaches[token] = cache;
        emit TokenRateCacheUpdated(token, rate);
    }

    /**
     * @dev Returns the cached value for token's rate
     */
    function getTokenRateCache(IERC20 token)
        external
        view
        returns (
            uint256 rate,
            uint256 duration,
            uint256 expires
        )
    {
        bytes32 cache = _tokenRateCaches[token];
        return PriceRateCache.decode(cache);
    }

    /**
     * @dev Sets a new duration for a token price rate cache. It reverts if there was no rate provider set initially.
     * Note this function also updates the current cached value.
     * @param duration Number of seconds until the current rate of token price is fetched again.
     */
    function setTokenRateCacheDuration(IERC20 token, uint256 duration) external authenticate {
        bytes32 cache = _tokenRateCaches[token];

        IRateProvider rateProvider = _getRateProvider(token);
        if (rateProvider == IRateProvider(address(0))) {
          _revert(Errors.INVALID_TOKEN);
        }

        (uint256 rate, , ) = PriceRateCache.decode(cache);

        bytes32 newCache = PriceRateCache.encode(rate, duration);
        _tokenRateCaches[token] = newCache;

        emit TokenRateProviderSet(token, _getRateProvider(token), duration);
    }

    /**
     * @dev Update cached total supply and invariant using the results after the join
     * Note that this function relies on the base class to perform any safety checks on joins.
     */
    function _onJoinPool(
        bytes32 poolId,
        address sender,
        address recipient,
        uint256[] memory balances,
        uint256 lastChangeBlock,
        uint256 protocolSwapFeePercentage,
        uint256[] memory scalingFactors,
        bytes memory userData
    ) internal virtual override returns (uint256 bptAmountOut, uint256[] memory amountsIn) {
        _cacheTokenRatesIfNecessary();

        (bptAmountOut, amountsIn) = super._onJoinPool(
            poolId,
            sender,
            recipient,
            balances,
            lastChangeBlock,
            protocolSwapFeePercentage,
            scalingFactors,
            userData
        );

        //_cacheInvariantAndSupply();

        return (bptAmountOut, amountsIn);
    }


    function _onExitPool(
        bytes32 poolId,
        address sender,
        address recipient,
        uint256[] memory balances,
        uint256 lastChangedBlock,
        uint256 protocolSwapFeePercentage,
        uint256[] memory scalingFactors,
        bytes memory userData
    ) internal virtual override returns (uint256 amountIn, uint256[] memory amountsOut) {
        _cacheTokenRatesIfNecessary();

        (amountIn, amountsOut) = super._onExitPool(
            poolId,
            sender,
            recipient,
            balances,
            lastChangedBlock,
            protocolSwapFeePercentage,
            scalingFactors,
            userData
        );

        //if (_isNotPaused()) {
            //_cacheInvariantAndSupply();
        //}
        return (amountIn, amountsOut);
    }

    function _getMaxTokens() internal pure virtual override returns (uint256) {
        return _MAX_TOKENS;
    }

    function _getTotalTokens() internal view virtual override returns (uint256) {
        return _totalTokens;
    }

    /**
     * @dev Returns the scaling factor for one of the Pool's tokens. Reverts if `token` is not a token registered by the
     * Pool.
     */
    function _scalingFactor(IERC20 token) internal view virtual override returns (uint256) {
        uint256 priceRate = _priceRate(token);

        // prettier-ignore
        if (token == _token0) { return _scalingFactor0.mulDown(priceRate); }
        else if (token == _token1) { return _scalingFactor1.mulDown(priceRate); }
        else if (token == _token2) { return _scalingFactor2.mulDown(priceRate); }
        else if (token == _token3) { return _scalingFactor3.mulDown(priceRate); }
        else if (token == _token4) { return _scalingFactor4.mulDown(priceRate); }
        else {
            _revert(Errors.INVALID_TOKEN);
        }
    }

    function _scalingFactors() internal view virtual override returns (uint256[] memory) {
        uint256 totalTokens = _getTotalTokens();
        uint256[] memory scalingFactors = new uint256[](totalTokens);


        // prettier-ignore
        {
            uint256 priceRate0 = _priceRate(_token0);
            uint256 priceRate1 = _priceRate(_token1);

            scalingFactors[0] = _scalingFactor0.mulDown(priceRate0);
            scalingFactors[1] = _scalingFactor1.mulDown(priceRate1);
            if (totalTokens > 2) {
              uint256 priceRate2 = _priceRate(_token2);
              scalingFactors[2] = _scalingFactor2.mulDown(priceRate2);
            } else {
              return scalingFactors;
            }
            if (totalTokens > 3) {
              uint256 priceRate3 = _priceRate(_token3);
              scalingFactors[3] = _scalingFactor3.mulDown(priceRate3);
            } else {
              return scalingFactors;
            }
            if (totalTokens > 4) {
              uint256 priceRate4 = _priceRate(_token4);
              scalingFactors[4] = _scalingFactor4.mulDown(priceRate4);
            } else {
              return scalingFactors;
            }
        }

        return scalingFactors;
    }


    function _getNormalizedWeight(IERC20 token) internal view virtual override returns (uint256) {
        // prettier-ignore
        if (token == _token0) { return _normalizedWeight0; }
        else if (token == _token1) { return _normalizedWeight1; }
        else if (token == _token2) { return _normalizedWeight2; }
        else if (token == _token3) { return _normalizedWeight3; }
        else if (token == _token4) { return _normalizedWeight4; }
        else {
            _revert(Errors.INVALID_TOKEN);
        }
    }

    function _getNormalizedWeights() internal view virtual override returns (uint256[] memory) {
        uint256 totalTokens = _getTotalTokens();
        uint256[] memory normalizedWeights = new uint256[](totalTokens);

        // prettier-ignore
        {
            normalizedWeights[0] = _normalizedWeight0;
            normalizedWeights[1] = _normalizedWeight1;
            if (totalTokens > 2) { normalizedWeights[2] = _normalizedWeight2; } else { return normalizedWeights; }
            if (totalTokens > 3) { normalizedWeights[3] = _normalizedWeight3; } else { return normalizedWeights; }
            if (totalTokens > 4) { normalizedWeights[4] = _normalizedWeight4; } else { return normalizedWeights; }
        }

        return normalizedWeights;
    }

    /**
     * @dev Returns the current value of the invariant.
     */
    //function getInvariant() public view returns (uint256) {
        //(address[] memory tokens, uint256[] memory balances, ) = getVault().getPoolTokens(getPoolId());

        //// Since the Pool hooks always work with upscaled balances, we manually
        //// upscale here for consistency
        //_upscaleArray(balances, _scalingFactors());

        //uint256[] memory normalizedWeights = _getNormalizedWeights();
        //return _calculateInvariantWithRates(tokens, normalizedWeights, balances);
    //}

    function _getRateProvider(IERC20 token) internal view returns (IRateProvider) {
        // prettier-ignore
        if (token == _token0) { return _rateProvider0; }
        else if (token == _token1) { return _rateProvider1; }
        else if (token == _token2) { return _rateProvider2; }
        else if (token == _token3) { return _rateProvider3; }
        else if (token == _token4) { return _rateProvider4; }
        else {
            _revert(Errors.INVALID_TOKEN);
        }
    }

    /**
     * @dev Returns the price rate for token. All price rates are fixed-point values with 18 decimals.
     * In case there is no rate provider for the provided token it returns 1e18.
     */
    function _priceRate(IERC20 token) internal view virtual returns (uint256) {
        // Given that this function is only used by `onSwap` which can only be called by the vault in the case of a
        // Meta Stable Pool, we can be sure the vault will not forward a call with an invalid `token` param.
        IRateProvider rateProvider = _getRateProvider(token);
        if (rateProvider != IRateProvider(address(0))) {
            return _tokenRateCaches[token].getRate();
        } else {
            return FixedPoint.ONE;
        }
    }

    /**
     * @dev Returns the rates.
     */
    function getRates() public view returns (uint256[] memory rates) {
        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(getPoolId());

        rates = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; ++i) {
          rates[i] = _priceRate(tokens[i]);
        }

        return rates;
    }

    function _beforeJoinExit(
        uint256[] memory preBalances,
        uint256[] memory normalizedWeights,
        uint256 protocolSwapFeePercentage
    //) internal virtual override(BaseWeightedPool, InvariantGrowthProtocolFeesWithYield) {
    ) internal virtual override {
        InvariantGrowthProtocolFeesWithYield._beforeJoinExit(preBalances, getRates(), normalizedWeights, protocolSwapFeePercentage);
    }

    function _afterJoinExit(
        bool isJoin,
        uint256[] memory preBalances,
        uint256[] memory balanceDeltas,
        uint256[] memory normalizedWeights
    //) internal virtual override(BaseWeightedPool, InvariantGrowthProtocolFeesWithYield) {
    ) internal virtual override {
        InvariantGrowthProtocolFeesWithYield._afterJoinExit(isJoin, preBalances, balanceDeltas, getRates(), normalizedWeights);
    }


    /**
     * @dev Returns the rate providers configured for each token (in the same order as registered).
     */
    function getRateProviders() external view returns (IRateProvider[] memory providers) {
        providers = new IRateProvider[](_totalTokens);

        providers[0] = _rateProvider0;
        providers[1] = _rateProvider1;
        if (_totalTokens > 2) {
          providers[2] = _rateProvider2;
        }
        if (_totalTokens > 3) {
          providers[3] = _rateProvider3;
        }
        if (_totalTokens > 4) {
          providers[4] = _rateProvider4;
        }
    }

    function _getScalingFactor0() internal view returns (uint256) {
        return _scalingFactor0;
    }

    function _getScalingFactor1() internal view returns (uint256) {
        return _scalingFactor1;
    }

    function _getScalingFactor2() internal view returns (uint256) {
        return _scalingFactor2;
    }

    function _getScalingFactor3() internal view returns (uint256) {
        return _scalingFactor3;
    }

    function _getScalingFactor4() internal view returns (uint256) {
        return _scalingFactor4;
    }

    function getScalingFactor(IERC20 token) external view returns (uint256) {
        return _scalingFactor(token);
    }
}
