import pytest
import util
import brownie


def test_set_government(rebalancer, gov, setup, rando):
    with brownie.reverts():
        rebalancer.setGovernance(rando, {'from': rando})
    rebalancer.setGovernance(rando, {'from': gov})


def test_set_rebalancer(providerA, providerB, rebalancer, gov, setup):
    with brownie.reverts("Rebalancer already set"):
        providerA.setRebalancer(rebalancer, {'from': gov})
    with brownie.reverts("Rebalancer already set"):
        providerB.setRebalancer(rebalancer, {'from': gov})


def test_set_reward(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer, user, gov,
                    setup, RELATIVE_APPROX, testSetup, crv, crv_whale, chain):
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    assert providerA.balanceOfWant() == 0
    assert providerB.balanceOfWant() == 0

    rebalancer.setReward(crv, {'from': gov})
    crv.transfer(rebalancer, 10000 * 1e18, {'from': crv_whale})

    ppsBeforeA = vaultA.pricePerShare()
    ppsBeforeB = vaultA.pricePerShare()

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    chain.sleep(3600)
    chain.mine(1)

    assert vaultA.pricePerShare() > ppsBeforeA
    assert vaultB.pricePerShare() > ppsBeforeB


def test_set_controller(rebalancer, gov, setup, RELATIVE_APPROX, testSetup, rando):

    with brownie.reverts():
        rebalancer.setController(rebalancer, {'from': gov})

    with brownie.reverts():
        rebalancer.setSwapFee(0.003 * 1e18, {'from': gov})

    with brownie.reverts():
        rebalancer.setPublicSwap(False, {'from': gov})

    with brownie.reverts():
        rebalancer.whitelistLiquidityProvider(rando, {'from': gov})

    with brownie.reverts():
        rebalancer.removeWhitelistedLiquidityProvider(rando, {'from': gov})
