import { expect } from 'chai';
import { BigNumber, Contract } from 'ethers';
import {
  WEEK,
  DAY,
  MINUTE,
  advanceToTimestamp,
  currentTimestamp,
  receiptTimestamp,
} from '@balancer-labs/v2-helpers/src/time';
import { BigNumberish, bn, fp } from '@balancer-labs/v2-helpers/src/numbers';
import * as expectEvent from '@balancer-labs/v2-helpers/src/test/expectEvent';
import { deploy, getArtifact } from '@balancer-labs/v2-helpers/src/contract';
import { Interface } from '@ethersproject/abi';

describe('ManagedPoolSwapFeesLib', function () {
  let pool: Contract;
  let libInterface: Interface;

  const MIN_SWAP_FEE = fp(0.000001);
  const MAX_SWAP_FEE = fp(0.8);

  const INITIAL_SWAP_FEE = MIN_SWAP_FEE.add(1);
  const VALID_SWAP_FEE = MIN_SWAP_FEE.add(MAX_SWAP_FEE).div(2);
  const TOO_LOW_SWAP_FEE = MIN_SWAP_FEE.sub(1);
  const TOO_HIGH_SWAP_FEE = MAX_SWAP_FEE.add(1);

  sharedBeforeEach('deploy MockManagedPoolSwapFeesLib and initialize', async () => {
    pool = await deploy('MockManagedPoolSwapFeesLib');
    libInterface = new Interface((await getArtifact('ManagedPoolSwapFeesLib')).abi);

    await pool.setSwapFeePercentage(INITIAL_SWAP_FEE);
  });

  describe('swap fee validation', () => {
    it('rejects swap fees above maximum', async () => {
      await expect(pool.validateSwapFeePercentage(TOO_HIGH_SWAP_FEE)).to.be.revertedWith('MAX_SWAP_FEE_PERCENTAGE');
    });

    it('rejects swap fee below minimum', async () => {
      await expect(pool.validateSwapFeePercentage(TOO_LOW_SWAP_FEE)).to.be.revertedWith('MIN_SWAP_FEE_PERCENTAGE');
    });

    it('accepts valid swap fees', async () => {
      await expect(pool.validateSwapFeePercentage(VALID_SWAP_FEE)).to.be.not.be.reverted;
    });
  });

  describe('setSwapFeePercentage', () => {
    it('cannot set swap fee above maximum', async () => {
      await expect(pool.setSwapFeePercentage(TOO_HIGH_SWAP_FEE)).to.be.revertedWith('MAX_SWAP_FEE_PERCENTAGE');
    });

    it('cannot set swap fee below minimum', async () => {
      await expect(pool.setSwapFeePercentage(TOO_LOW_SWAP_FEE)).to.be.revertedWith('MIN_SWAP_FEE_PERCENTAGE');
    });

    it('emits a SwapFeePercentageChanged event', async () => {
      const tx = await pool.setSwapFeePercentage(VALID_SWAP_FEE);
      expectEvent.inIndirectReceipt(await tx.wait(), libInterface, 'SwapFeePercentageChanged', {
        swapFeePercentage: VALID_SWAP_FEE,
      });
    });

    it('updates the swap fee', async () => {
      expect(await pool.getSwapFeePercentage()).to.be.eq(INITIAL_SWAP_FEE);
      await pool.setSwapFeePercentage(VALID_SWAP_FEE);
      expect(await pool.getSwapFeePercentage()).to.be.eq(VALID_SWAP_FEE);
    });
  });
});
