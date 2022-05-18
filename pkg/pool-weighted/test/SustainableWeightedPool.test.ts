import { ethers } from 'hardhat';
import { expect } from 'chai';
import { BigNumber, Contract } from 'ethers';
import { deploy } from '@balancer-labs/v2-helpers/src/contract';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';
import { actionId } from '@balancer-labs/v2-helpers/src/models/misc/actions';
import { fp, bn, fromFp } from '@balancer-labs/v2-helpers/src/numbers';
import { ZERO_ADDRESS } from '@balancer-labs/v2-helpers/src/constants';
import { MINUTE, advanceTime, currentTimestamp } from '@balancer-labs/v2-helpers/src/time';

import Token from '@balancer-labs/v2-helpers/src/models/tokens/Token';
import TokenList from '@balancer-labs/v2-helpers/src/models/tokens/TokenList';
import WeightedPool from '@balancer-labs/v2-helpers/src/models/pools/weighted/WeightedPool';
import { WeightedPoolType } from '@balancer-labs/v2-helpers/src/models/pools/weighted/types';

import * as expectEvent from '@balancer-labs/v2-helpers/src/test/expectEvent';

const scaleRate = (rate: BigNumber, token: Token) => rate.mul(bn(10).pow(18 - token.decimals));

describe('SustainableWeightedPool', function () {
  let trader: SignerWithAddress, admin: SignerWithAddress, other: SignerWithAddress, lp: SignerWithAddress;

  before('setup signers', async () => {
    [, lp, trader, other, admin] = await ethers.getSigners();
  });

  let tokens: TokenList;

  sharedBeforeEach('deploy tokens', async () => {
    // Setting varyDecimals to true will create one with 18 and one with 17 decimals
    tokens = await TokenList.create(['MKR', 'DAI'], { sorted: true, varyDecimals: true });
    // mintScaled will compute the correct scaled initial balance, from a raw number of tokens
    await tokens.mintScaled({ to: [lp, trader], amount: 100 });
  });

  let pool: WeightedPool;
  let rateProviders: Contract[];
  let tokenRateCacheDurations: number[];
  let scalingFactors: BigNumber[];
  const weights = [fp(30), fp(70)];

  describe('weights', () => {
    sharedBeforeEach('deploy pool', async () => {
      tokenRateCacheDurations = [MINUTE, MINUTE * 2];
      const rateProviderAddresses = new Array(tokens.addresses.length).fill(ZERO_ADDRESS);
      const params = {
        poolType: WeightedPoolType.SUSTAINABLE_WEIGHTED_POOL,
        tokens,
        weights,
        rateProviders: rateProviderAddresses,
        tokenRateCacheDurations,
      };
      pool = await WeightedPool.create(params);
      // Get the scaling factors from the pool, so that we can adjust incoming balances
      // The WeightedPool.ts computation methods expect all tokens to be 18 decimals, like the Vault
      scalingFactors = await pool.getScalingFactors();
      scalingFactors = scalingFactors.map((f) => bn(fromFp(f)));
    });

    it('sets token weights', async () => {
      const normalizedWeights = await pool.getNormalizedWeights();

      expect(normalizedWeights).to.equalWithError(pool.normalizedWeights, 0.0000001);
    });
  });

  describe('price rates', () => {
    let oldTokenRate0: BigNumber, oldTokenRate1: BigNumber;

    context('with rate providers', () => {
      const createPoolWithInitialRates = (delta: number) => {
        sharedBeforeEach('mock price rates and deploy pool', async () => {
          tokens = await TokenList.create(['MKR', 'DAI'], { sorted: true, varyDecimals: true });

          rateProviders = await Promise.all(tokens.addresses.map(() => deploy('v2-pool-utils/MockRateProvider')));
          const rateProviderAddresses = rateProviders.map((rp) => rp.address);

          tokenRateCacheDurations = [MINUTE, MINUTE * 2];
          await rateProviders[0].mockRate(fp(1).add(fp(delta)));
          await rateProviders[1].mockRate(fp(1).add(fp(delta * 2)));

          const params = {
            poolType: WeightedPoolType.SUSTAINABLE_WEIGHTED_POOL,
            tokens,
            weights,
            rateProviders: rateProviderAddresses,
            tokenRateCacheDurations,
          };
          pool = await WeightedPool.create(params);
          // Get the scaling factors from the pool, so that we can adjust incoming balances
          // The WeightedPool.ts computation methods expect all tokens to be 18 decimals, like the Vault
          scalingFactors = await pool.getScalingFactors();
        });
      };

      const mockNewRatesAndAdvanceTime = (seconds: number) => {
        sharedBeforeEach('advance time', async () => {
          oldTokenRate0 = (await pool.instance.getTokenRateCache(tokens.first.address)).rate;
          oldTokenRate1 = (await pool.instance.getTokenRateCache(tokens.second.address)).rate;

          await rateProviders[0].mockRate(fp(1.1));
          await rateProviders[1].mockRate(fp(1.2));

          await advanceTime(seconds);
          await pool.instance.mockCacheTokenRatesIfNecessary();
        });
      };

      const itAdaptsTheScalingFactorsCorrectly = () => {
        it('adapt the scaling factors with the price rate', async () => {
          const priceRates = await Promise.all(rateProviders.map((provider) => provider.getRate()));
          priceRates[0] = scaleRate(priceRates[0], tokens.first);
          priceRates[1] = scaleRate(priceRates[1], tokens.second);

          const scalingFactors = await pool.instance.getScalingFactors();
          expect(scalingFactors[0]).to.be.equal(priceRates[0]);
          expect(scalingFactors[1]).to.be.equal(priceRates[1]);

          expect(await pool.instance.getScalingFactor(tokens.first.address)).to.be.equal(priceRates[0]);
          expect(await pool.instance.getScalingFactor(tokens.second.address)).to.be.equal(priceRates[1]);
        });
      };

      const forceManualUpdate = () => {
        sharedBeforeEach('force update', async () => {
          const priceRates = await Promise.all(rateProviders.map((provider) => provider.getRate()));

          const firstReceipt = await pool.updateTokenRateCache(tokens.first);
          expectEvent.inIndirectReceipt(await firstReceipt.wait(), pool.instance.interface, 'TokenRateCacheUpdated', {
            token: tokens.first.address,
            rate: priceRates[0],
          });

          const secondReceipt = await pool.updateTokenRateCache(tokens.second);
          expectEvent.inIndirectReceipt(await secondReceipt.wait(), pool.instance.interface, 'TokenRateCacheUpdated', {
            token: tokens.second.address,
            rate: priceRates[1],
          });
        });
      };

      describe('update', () => {
        context('initially', () => {
          tokenRateCacheDurations = [MINUTE, MINUTE * 2];
          context('with a price rate above 1', () => {
            createPoolWithInitialRates(0.1);
            itAdaptsTheScalingFactorsCorrectly();

            it('initializes correctly', async () => {
              const cache0 = await pool.instance.getTokenRateCache(tokens.first.address);
              expect(cache0.duration).to.be.equal(tokenRateCacheDurations[0]);

              const cache1 = await pool.instance.getTokenRateCache(tokens.second.address);
              expect(cache1.duration).to.be.equal(tokenRateCacheDurations[1]);

              const providers = await pool.instance.getRateProviders();
              expect(providers[0]).to.be.equal(rateProviders[0].address);
              expect(providers[1]).to.be.equal(rateProviders[1].address);
            });
          });

          context('with a price rate equal to 1', () => {
            createPoolWithInitialRates(0);
            itAdaptsTheScalingFactorsCorrectly();
          });

          context('with a price rate below 1', () => {
            createPoolWithInitialRates(-0.1);
            itAdaptsTheScalingFactorsCorrectly();
          });
        });

        context('after some time', () => {
          createPoolWithInitialRates(0);

          context('before the first cache expires', () => {
            mockNewRatesAndAdvanceTime(tokenRateCacheDurations[0] / 2);

            context('when not forced', () => {
              it('does not update any cache', async () => {
                const { rate: newTokenRate0 } = await pool.instance.getTokenRateCache(tokens.first.address);
                const { rate: newTokenRate1 } = await pool.instance.getTokenRateCache(tokens.second.address);

                expect(newTokenRate0).to.be.equal(oldTokenRate0);
                expect(newTokenRate1).to.be.equal(oldTokenRate1);

                const scalingFactors = await pool.instance.getScalingFactors();
                expect(scalingFactors[0]).to.be.equal(scaleRate(oldTokenRate0, tokens.first));
                expect(scalingFactors[1]).to.be.equal(scaleRate(oldTokenRate1, tokens.second));
              });
            });

            context('when forced', () => {
              forceManualUpdate();
              itAdaptsTheScalingFactorsCorrectly();
            });
          });

          context('after the first cache expired but before the second does', () => {
            mockNewRatesAndAdvanceTime(tokenRateCacheDurations[0] + 1);

            context('when not forced', () => {
              it('updates only the first cache', async () => {
                const { rate: newTokenRate0 } = await pool.instance.getTokenRateCache(tokens.first.address);
                const { rate: newTokenRate1 } = await pool.instance.getTokenRateCache(tokens.second.address);

                expect(newTokenRate0).to.be.gt(oldTokenRate0);
                expect(newTokenRate1).to.be.equal(oldTokenRate1);

                const scalingFactors = await pool.instance.getScalingFactors();
                expect(scalingFactors[0]).to.be.equal(scaleRate(newTokenRate0, tokens.first));
                expect(scalingFactors[1]).to.be.equal(scaleRate(oldTokenRate1, tokens.second));
              });
            });

            context('when forced', () => {
              forceManualUpdate();
              itAdaptsTheScalingFactorsCorrectly();
            });
          });

          context('after both caches expired', () => {
            mockNewRatesAndAdvanceTime(tokenRateCacheDurations[1] + 1);

            context('when not forced', () => {
              it('updates both caches', async () => {
                const { rate: newTokenRate0 } = await pool.instance.getTokenRateCache(tokens.first.address);
                const { rate: newTokenRate1 } = await pool.instance.getTokenRateCache(tokens.second.address);

                expect(newTokenRate0).to.be.gt(oldTokenRate0);
                expect(newTokenRate1).to.be.gt(oldTokenRate1);

                const scalingFactors = await pool.instance.getScalingFactors();
                expect(scalingFactors[0]).to.be.equal(scaleRate(newTokenRate0, tokens.first));
                expect(scalingFactors[1]).to.be.equal(scaleRate(newTokenRate1, tokens.second));
              });
            });

            context('when forced', () => {
              forceManualUpdate();
              itAdaptsTheScalingFactorsCorrectly();
            });
          });
        });
      });

      describe('setting', () => {
        createPoolWithInitialRates(0);

        sharedBeforeEach('grant role to admin', async () => {
          const action = await actionId(pool.instance, 'setTokenRateCacheDuration');
          await pool.vault.grantPermissionsGlobally([action], admin);
        });

        const setNewTokenRateCache = () => {
          let forceUpdateAt: BigNumber;
          const newDuration = MINUTE * 10;

          sharedBeforeEach('update price rate cache', async () => {
            forceUpdateAt = await currentTimestamp();

            const firstReceipt = await pool.setTokenRateCacheDuration(tokens.first, newDuration, admin);
            expectEvent.inReceipt(await firstReceipt.wait(), 'TokenRateProviderSet', {
              token: tokens.first.address,
              provider: rateProviders[0].address,
              cacheDuration: newDuration,
            });

            const secondReceipt = await pool.setTokenRateCacheDuration(tokens.second, newDuration, admin);
            expectEvent.inReceipt(await secondReceipt.wait(), 'TokenRateProviderSet', {
              token: tokens.second.address,
              provider: rateProviders[1].address,
              cacheDuration: newDuration,
            });
          });

          it('updates the cache duration', async () => {
            const cache0 = await pool.instance.getTokenRateCache(tokens.first.address);
            expect(cache0.duration).to.be.equal(newDuration);
            expect(cache0.expires).to.be.at.least(forceUpdateAt.add(newDuration));

            const cache1 = await pool.instance.getTokenRateCache(tokens.second.address);
            expect(cache1.duration).to.be.equal(newDuration);
            expect(cache1.expires).to.be.at.least(forceUpdateAt.add(newDuration));
          });
        };

        context('when it is requested by the admin', () => {
          context('when it did not pass the previous duration', async () => {
            mockNewRatesAndAdvanceTime(MINUTE / 2);
            setNewTokenRateCache();
            const { rate: newTokenRate0 } = await pool.instance.getTokenRateCache(tokens.first.address);
            const { rate: newTokenRate1 } = await pool.instance.getTokenRateCache(tokens.second.address);
            expect(newTokenRate0).to.be.equal(oldTokenRate0);
            expect(newTokenRate1).to.be.equal(oldTokenRate1);
          });

          context('when it passed the previous duration', () => {
            mockNewRatesAndAdvanceTime(MINUTE * 2);
            setNewTokenRateCache();
            itAdaptsTheScalingFactorsCorrectly();
          });
        });

        context('when it is not requested by the admin', () => {
          it('reverts', async () => {
            await expect(pool.setTokenRateCacheDuration(tokens.first, MINUTE * 10, other)).to.be.revertedWith(
              'SENDER_NOT_ALLOWED'
            );
          });
        });
      });
    });

    context('with no providers', () => {
      it('reverts', async () => {
        const rateProviderAddresses: string[] = [];
        const params = {
          poolType: WeightedPoolType.SUSTAINABLE_WEIGHTED_POOL,
          tokens,
          weights,
          rateProviders: rateProviderAddresses,
          tokenRateCacheDurations,
        };
        await expect(WeightedPool.create(params)).to.be.revertedWith('INPUT_LENGTH_MISMATCH');
      });
    });
  });
});
