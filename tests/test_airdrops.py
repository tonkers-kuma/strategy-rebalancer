import brownie
from brownie import Contract
import pytest
import util


def test_airdrops(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer,
                  user, gov, setup, rando, transferToRando, chain, testSetup, reward, reward_whale,
                  whaleA, whaleB):
    beforeHarvestA = rebalancer.currentWeightA()
    beforeHarvestB = rebalancer.currentWeightB()

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    afterHarvestA = rebalancer.currentWeightA()
    afterHarvestB = rebalancer.currentWeightB()
    assert beforeHarvestA != afterHarvestA
    assert beforeHarvestB != afterHarvestB

    util.simulate_bal_reward(rebalancer, reward, reward_whale)

    ppsBeforeA = vaultA.pricePerShare()
    ppsBeforeB = vaultB.pricePerShare()

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    util.stateOfStrat("harvest after profit", rebalancer, providerA, providerB)

    chain.sleep(3600)
    chain.mine(1)

    assert vaultA.pricePerShare() > ppsBeforeA
    assert vaultB.pricePerShare() > ppsBeforeB

    # airdrops
    tokenA.transfer(rebalancer, 300000 * 1e6, {'from': whaleA})
    tokenB.transfer(rebalancer, 3 * 1e18, {'from': whaleB})

    tokenA.transfer(providerA, 300000 * 1e6, {'from': whaleA})
    tokenB.transfer(providerB, 3 * 1e18, {'from': whaleB})

    util.stateOfStrat("after airdrop", rebalancer, providerA, providerB)

    ppsBeforeA = vaultA.pricePerShare()
    ppsBeforeB = vaultB.pricePerShare()

    # puts the airdrops into the lp
    providerA.tend({"from": gov})

    # harvest the gains from airdrop
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    util.stateOfStrat("harvest after airdrop", rebalancer, providerA, providerB)

    chain.sleep(3600)
    chain.mine(1)

    assert vaultA.pricePerShare() > ppsBeforeA
    assert vaultB.pricePerShare() > ppsBeforeB
