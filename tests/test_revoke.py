import pytest
import util


def test_revoke_strategy_from_strategy(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB,
                                       rebalancer, user, gov, setup, rando, transferToRando, chain,
                                       testSetup, RELATIVE_APPROX):
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})
    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountA
    assert pytest.approx(providerB.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountB

    chain.sleep(3600)
    chain.mine(1)

    vaultA.revokeStrategy(providerA.address, {"from": gov})
    vaultB.revokeStrategy(providerB.address, {"from": gov})

    chain.sleep(1)
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    assert pytest.approx(tokenA.balanceOf(vaultA.address), rel=RELATIVE_APPROX) == amountA
    assert pytest.approx(tokenB.balanceOf(vaultB.address), rel=RELATIVE_APPROX) == amountB


def test_revoke_strategy_from_vault(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB,
                                    rebalancer,
                                    user, gov, setup, rando, transferToRando, chain, testSetup, RELATIVE_APPROX):
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})
    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountA
    assert pytest.approx(providerB.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountB

    chain.sleep(3600)
    chain.mine(1)

    providerA.setEmergencyExit({"from": gov})
    providerB.setEmergencyExit({"from": gov})

    chain.sleep(1)
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    assert pytest.approx(tokenA.balanceOf(vaultA.address), rel=RELATIVE_APPROX) == amountA
    assert pytest.approx(tokenB.balanceOf(vaultB.address), rel=RELATIVE_APPROX) == amountB

