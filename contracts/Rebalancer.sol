// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/IJointProvider.sol";
import "../interfaces/BalancerV2.sol";
import "../interfaces/Uniswap.sol";
import "../interfaces/Weth.sol";
import "../interfaces/ISymbol.sol";
import "./BalancerLib.sol";

/**
 * Maintains liquidity pool and dynamically rebalances pool weights to minimize impermanent loss
 */
contract Rebalancer {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint;

    IERC20 public reward;
    IERC20 public tokenA;
    IERC20 public tokenB;
    IJointProvider public providerA;
    IJointProvider public providerB;
    IUniswapV2Router02 public uniswap;
    IWETH9 private constant weth = IWETH9(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    ILiquidityBootstrappingPoolFactory public lbpFactory;
    ILiquidityBootstrappingPool public lbp;
    IBalancerVault public bVault;
    IAsset[] public assets;
    uint[] private minAmountsOut;

    uint constant private max = type(uint).max;
    bool internal isOriginal = true;
    bool internal initJoin;
    uint public tendBuffer;

    // publicSwap flips on and off depending on weight balance conditions.
    // This acts as a master switch to stay disabled during emergencies.
    bool public stayDisabled;

    uint public upperBound;
    uint public lowerBound;

    modifier toOnlyAllowed(address _to){
        require(
            _to == address(providerA) ||
            _to == address(providerB) ||
            providerA.isVaultManagers(_to), "!allowed");
        _;
    }

    modifier onlyAllowed{
        require(
            msg.sender == address(providerA) ||
            msg.sender == address(providerB) ||
            providerA.isVaultManagers(msg.sender), "!allowed");
        _;
    }

    modifier onlyVaultManagers{
        require(providerA.isVaultManagers(msg.sender), "!governance");
        _;
    }

    constructor(address _providerA, address _providerB, address _lbpFactory) public {
        _initialize(_providerA, _providerB, _lbpFactory);
    }

    function initialize(
        address _providerA,
        address _providerB,
        address _lbpFactory
    ) external {
        require(address(providerA) == address(0x0) && address(tokenA) == address(0x0), "Already initialized!");
        require(address(providerB) == address(0x0) && address(tokenB) == address(0x0), "Already initialized!");
        _initialize(_providerA, _providerB, _lbpFactory);
    }

    function _initialize(address _providerA, address _providerB, address _lbpFactory) internal {
        initJoin = true;
        uniswap = IUniswapV2Router02(address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
        reward = IERC20(address(0xba100000625a3754423978a60c9317c58a424e3D));
        reward.approve(address(uniswap), max);

        _setProviders(_providerA, _providerB);

        minAmountsOut = new uint[](2);
        tendBuffer = 0.001 * 1e18;

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        uint[] memory initialWeights = new uint[](2);
        initialWeights[0] = uint(0.5 * 1e18);
        initialWeights[1] = uint(0.5 * 1e18);

        upperBound = 0.98 * 1e18;
        lowerBound = 0.02 * 1e18;

        lbpFactory = ILiquidityBootstrappingPoolFactory(_lbpFactory);
        lbp = ILiquidityBootstrappingPool(
            lbpFactory.create(
                string(abi.encodePacked(name()[0], name()[1])),
                string(abi.encodePacked(name()[1], " yBPT")),
                tokens,
                initialWeights,
                0.01 * 1e18,
                address(this),
                true)
        );
        bVault = IBalancerVault(lbp.getVault());
        tokenA.approve(address(bVault), max);
        tokenB.approve(address(bVault), max);

        assets = [IAsset(address(tokenA)), IAsset(address(tokenB))];
    }

    event Cloned(address indexed clone);

    function cloneRebalancer(address _providerA, address _providerB, address _lbpFactory) external returns (address payable newStrategy) {
        require(isOriginal);

        bytes20 addressBytes = bytes20(address(this));

        assembly {
        // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        Rebalancer(newStrategy).initialize(_providerA, _providerB, _lbpFactory);

        emit Cloned(newStrategy);
    }

    function name() public view returns (string[] memory) {
        string[] memory names = new string[](2);
        names[0] = "Rebalancer ";
        names[1] = string(abi.encodePacked(ISymbol(address(tokenA)).symbol(), "-", ISymbol(address(tokenB)).symbol()));
        return names;
    }

    // collect profit from trading fees
    function collectTradingFees() public onlyAllowed {
        uint debtA = providerA.totalDebt();
        uint debtB = providerB.totalDebt();

        if (debtA == 0 || debtB == 0) return;

        uint pooledA = pooledBalanceA();
        uint pooledB = pooledBalanceB();

        // there's profit
        if (pooledA >= debtA && pooledB >= debtB) {
            uint gainA = pooledA.sub(debtA);
            uint gainB = pooledB.sub(debtB);
            uint looseABefore = looseBalanceA();
            uint looseBBefore = looseBalanceB();

            uint[] memory amountsOut = new uint[](2);
            amountsOut[0] = gainA;
            amountsOut[1] = gainB;
            _exitPool(abi.encode(IBalancerVault.ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT, amountsOut, balanceOfLbp()));

            if (gainA > 0) {
                tokenA.transfer(address(providerA), looseBalanceA().sub(looseABefore));
            }

            if (gainB > 0) {
                tokenB.transfer(address(providerB), looseBalanceB().sub(looseBBefore));
            }
        }
    }

    // sell reward and distribute evenly to each provider
    function sellRewards() public onlyAllowed {
        uint _rewards = balanceOfReward();
        if (_rewards > 0) {
            uint rewardsA = _rewards.mul(currentWeightA()).div(1e18);
            uint rewardsB = _rewards.sub(rewardsA);
            // TODO migrate to ySwapper when ready
            _swap(rewardsA, _getPath(reward, tokenA), address(providerA));
            _swap(rewardsB, _getPath(reward, tokenB), address(providerB));
        }
    }

    function shouldHarvest() public view returns (bool _shouldHarvest){
        uint debtA = providerA.totalDebt();
        uint debtB = providerB.totalDebt();
        uint totalA = totalBalanceOf(tokenA);
        uint totalB = totalBalanceOf(tokenB);
        return (totalA >= debtA && totalB > debtB) || (totalA > debtA && totalB >= debtB);
    }

    // If positive slippage caused by market movement is more than our swap fee, adjust position to erase positive slippage
    // since positive slippage for user = negative slippage for pool aka loss for strat
    function shouldTend() public view returns (bool _shouldTend){

        // 18 == decimals of USD
        uint debtAUsd = _adjustDecimals(providerA.totalDebt().mul(providerA.getPriceFeed()).div(10 ** providerA.getPriceFeedDecimals()), _decimals(tokenA), 18);
        uint debtBUsd = _adjustDecimals(providerB.totalDebt().mul(providerB.getPriceFeed()).div(10 ** providerB.getPriceFeedDecimals()), _decimals(tokenB), 18);
        uint debtTotalUsd = debtAUsd.add(debtBUsd);
        uint idealAUsd = debtTotalUsd.mul(currentWeightA()).div(1e18);
        uint idealBUsd = debtTotalUsd.sub(idealAUsd);
        uint weight = debtTotalUsd == 0 ? 0 : debtAUsd.mul(1e18).div(debtTotalUsd);

        // If it hits weight boundary, tend so that we can disable swaps. If already disabled, no need to tend again.
        if (weight >= upperBound || weight <= lowerBound) {
            return getPublicSwap();
        } else if (!getPublicSwap()) {
            // If it's not at weight boundary, it's safe again to enable swap
            return !stayDisabled;
        }

        uint amountIn;
        uint amountOutIfNoSlippage;
        uint amountOut;

        if (idealAUsd > debtAUsd) {
            amountIn = _adjustDecimals(idealAUsd.sub(debtAUsd).mul(10 ** providerA.getPriceFeedDecimals()).div(providerA.getPriceFeed()), 18, _decimals(tokenA));
            amountOutIfNoSlippage = _adjustDecimals(debtBUsd.sub(idealBUsd).mul(10 ** providerB.getPriceFeedDecimals()).div(providerB.getPriceFeed()), 18, _decimals(tokenB));
            amountOut = BalancerMathLib.calcOutGivenIn(pooledBalanceA(), currentWeightA(), pooledBalanceB(), currentWeightB(), amountIn, 0);
        } else {
            amountIn = _adjustDecimals(idealBUsd.sub(debtBUsd).mul(10 ** providerB.getPriceFeedDecimals()).div(providerB.getPriceFeed()), 18, _decimals(tokenB));
            amountOutIfNoSlippage = _adjustDecimals(debtAUsd.sub(idealAUsd).mul(10 ** providerA.getPriceFeedDecimals()).div(providerA.getPriceFeed()), 18, _decimals(tokenA));
            amountOut = BalancerMathLib.calcOutGivenIn(pooledBalanceB(), currentWeightB(), pooledBalanceA(), currentWeightA(), amountIn, 0);
        }

        // maximum positive slippage for arber. Evaluate that against our fees.
        if (amountOut > amountOutIfNoSlippage) {
            uint slippage = amountOut.sub(amountOutIfNoSlippage).mul(10 ** (idealAUsd > debtAUsd ? _decimals(tokenB) : _decimals(tokenA))).div(amountOutIfNoSlippage);
            return slippage > lbp.getSwapFeePercentage().sub(tendBuffer);
        } else {
            return false;
        }
    }

    // Pull from providers
    // @param _amountWithdrawn takes into account the difference that'll get subtracted to the debt after a withdraw.
    // This is a way to adjustPosition immediately after withdraw with that new totalDebt without waiting for keeper to adjustPosition in a future block.
    function adjustPosition(uint _amountWithdrawn, IERC20 _token) public onlyAllowed {
        require(_token == tokenA || _token == tokenB);
        uint totalDebtA = providerA.totalDebt() > _amountWithdrawn ? (_token == tokenA ? providerA.totalDebt().sub(_amountWithdrawn) : providerA.totalDebt()) : 0;
        uint totalDebtB = providerB.totalDebt() > _amountWithdrawn ? (_token == tokenB ? providerB.totalDebt().sub(_amountWithdrawn) : providerB.totalDebt()) : 0;

        // If adjustPosition is from a withdraw, don't pull funds back into rebalancer. Funds need to sit in providers to be pulled by vault
        if (_amountWithdrawn == 0) {
            tokenA.transferFrom(address(providerA), address(this), providerA.balanceOfWant());
            tokenB.transferFrom(address(providerB), address(this), providerB.balanceOfWant());
        }

        // exit entire position
        uint lbpBalance = balanceOfLbp();
        if (lbpBalance > 0) {
            _exitPool(abi.encode(IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT, lbpBalance));
        }

        // 18 == decimals of USD
        uint debtAUsd = _adjustDecimals(totalDebtA.mul(providerA.getPriceFeed()).div(10 ** providerA.getPriceFeedDecimals()), _decimals(tokenA), 18);
        uint debtBUsd = _adjustDecimals(totalDebtB.mul(providerB.getPriceFeed()).div(10 ** providerB.getPriceFeedDecimals()), _decimals(tokenB), 18);
        uint debtTotalUsd = debtAUsd.add(debtBUsd);

        if (debtTotalUsd == 0) {
            lbp.setSwapEnabled(false);
            return;
        }

        // update weights to their appropriate priced balances
        uint[] memory newWeights = new uint[](2);
        newWeights[0] = Math.max(Math.min(debtAUsd.mul(1e18).div(debtTotalUsd), upperBound), lowerBound);
        newWeights[1] = 1e18 - newWeights[0];

        // If adjustment hits weight boundary, turn off trades. Adjust debt ratio manually until it's not at boundary anymore.
        if (newWeights[0] == lowerBound || newWeights[1] == lowerBound) {
            lbp.setSwapEnabled(false);
            return;
        } else if (!getPublicSwap() && !stayDisabled) {
            lbp.setSwapEnabled(true);
        }

        lbp.updateWeightsGradually(now, now, newWeights);

        uint looseA = looseBalanceA();
        uint looseB = looseBalanceB();

        uint[] memory maxAmountsIn = new uint[](2);
        maxAmountsIn[0] = looseA;
        maxAmountsIn[1] = looseB;

        // Re-enter pool with max funds at the appropriate weights.
        uint[] memory amountsIn = new uint[](2);
        amountsIn[0] = looseA;
        amountsIn[1] = looseB;

        bytes memory userData;

        if (initJoin) {
            userData = abi.encode(IBalancerVault.JoinKind.INIT, amountsIn);
            initJoin = false;
        } else {
            userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, amountsIn, 0);
        }
        IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(assets, maxAmountsIn, userData, false);
        bVault.joinPool(lbp.getPoolId(), address(this), address(this), request);
    }

    function liquidatePosition(uint _amountNeeded, IERC20 _token, address _to) public toOnlyAllowed(_to) onlyAllowed returns (uint _liquidated, uint _short){
        uint index = tokenIndex(_token);
        uint loose = _token.balanceOf(address(this));

        if (_amountNeeded > loose) {
            uint _pooled = pooledBalance(index);
            uint _amountNeededMore = Math.min(_amountNeeded.sub(loose), _pooled);

            uint[] memory amountsOut = new uint[](2);
            amountsOut[index] = _amountNeededMore;
            _exitPool(abi.encode(IBalancerVault.ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT, amountsOut, balanceOfLbp()));
            _liquidated = Math.min(_amountNeeded, _token.balanceOf(address(this)));
        } else {
            _liquidated = _amountNeeded;
        }

        if (_liquidated > 0) {
            _token.transfer(_to, _liquidated);
        }
        _short = _amountNeeded.sub(_liquidated);
    }

    function liquidateAllPositions(IERC20 _token, address _to) public toOnlyAllowed(_to) onlyAllowed returns (uint _liquidatedAmount){
        uint lbpBalance = balanceOfLbp();
        if (lbpBalance > 0) {
            // exit entire position
            _exitPool(abi.encode(IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT, lbpBalance));
            evenOut();
        }
        _liquidatedAmount = _token.balanceOf(address(this));
        _token.transfer(_to, _liquidatedAmount);
    }

    // only applicable when pool is skewed and strat wants to completely pull out. Sells one token for another
    function evenOut() public onlyAllowed {
        uint looseA = looseBalanceA();
        uint looseB = looseBalanceB();
        uint debtA = providerA.totalDebt();
        uint debtB = providerB.totalDebt();
        uint amount;
        address[] memory path;

        if (looseA > debtA && looseB < debtB) {
            // we have more A than B, sell some A
            amount = looseA.sub(debtA);
            path = _getPath(tokenA, tokenB);
        } else if (looseB > debtB && looseA < debtA) {
            // we have more B than A, sell some B
            amount = looseB.sub(debtB);
            path = _getPath(tokenB, tokenA);
        }
        if (amount > 0) {
            _swap(amount, path, address(this));
        }
    }


    // Helpers //
    function _swap(uint _amount, address[] memory _path, address _to) internal {
        uint decIn = ERC20(_path[0]).decimals();
        uint decOut = ERC20(_path[_path.length - 1]).decimals();
        uint decDelta = decIn > decOut ? decIn.sub(decOut) : 0;
        if (_amount > 10 ** decDelta) {
            uniswap.swapExactTokensForTokens(_amount, 0, _path, _to, now);
        }
    }

    function _exitPool(bytes memory _userData) internal {
        IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets, minAmountsOut, _userData, false);
        bVault.exitPool(lbp.getPoolId(), address(this), address(this), request);
    }

    function _setProviders(address _providerA, address _providerB) internal {
        providerA = IJointProvider(_providerA);
        providerB = IJointProvider(_providerB);
        tokenA = providerA.want();
        tokenB = providerB.want();
        require(tokenA != tokenB);
        tokenA.approve(address(uniswap), max);
        tokenB.approve(address(uniswap), max);
    }

    function setReward(address _reward) public onlyVaultManagers {
        reward.approve(address(uniswap), 0);
        reward = IERC20(_reward);
        reward.approve(address(uniswap), max);
    }

    function _getPath(IERC20 _in, IERC20 _out) internal pure returns (address[] memory _path){
        bool isWeth = address(_in) == address(weth) || address(_out) == address(weth);
        _path = new address[](isWeth ? 2 : 3);
        _path[0] = address(_in);
        if (isWeth) {
            _path[1] = address(_out);
        } else {
            _path[1] = address(weth);
            _path[2] = address(_out);
        }
        return _path;
    }

    function setSwapFee(uint _fee) external onlyVaultManagers {
        lbp.setSwapFeePercentage(_fee);
    }

    function setPublicSwap(bool _isPublic) external onlyVaultManagers {
        lbp.setSwapEnabled(_isPublic);
    }

    function setTendBuffer(uint _newBuffer) external onlyVaultManagers {
        require(_newBuffer < lbp.getSwapFeePercentage());
        tendBuffer = _newBuffer;
    }

    //  called by providers
    function migrateProvider(address _newProvider) external onlyAllowed {
        IJointProvider newProvider = IJointProvider(_newProvider);
        if (newProvider.want() == tokenA) {
            providerA = newProvider;
        } else if (newProvider.want() == tokenB) {
            providerB = newProvider;
        } else {
            revert("Unsupported token");
        }
    }

    // TODO switch to ySwapper when ready
    function ethToWant(address _want, uint _amtInWei) external view returns (uint _wantAmount){
        if (_amtInWei > 0) {
            address[] memory path = new address[](2);
            if (_want == address(weth)) {
                return _amtInWei;
            } else {
                path[0] = address(weth);
                path[1] = _want;
            }
            return uniswap.getAmountsOut(_amtInWei, path)[1];
        } else {
            return 0;
        }
    }

    function balanceOfReward() public view returns (uint){
        return reward.balanceOf(address(this));
    }

    function balanceOfLbp() public view returns (uint) {
        return lbp.balanceOf(address(this));
    }

    function looseBalanceA() public view returns (uint) {
        return tokenA.balanceOf(address(this));
    }

    function looseBalanceB() public view returns (uint) {
        return tokenB.balanceOf(address(this));
    }

    function pooledBalanceA() public view returns (uint) {
        return pooledBalance(0);
    }

    function pooledBalanceB() public view returns (uint) {
        return pooledBalance(1);
    }

    function pooledBalance(uint index) public view returns (uint) {
        (, uint[] memory balances,) = bVault.getPoolTokens(lbp.getPoolId());
        return balances[index];
    }

    function totalBalanceOf(IERC20 _token) public view returns (uint){
        uint pooled = pooledBalance(tokenIndex(_token));
        uint loose = _token.balanceOf(address(this));
        return pooled.add(loose);
    }

    function currentWeightA() public view returns (uint) {
        return lbp.getNormalizedWeights()[0];
    }

    function currentWeightB() public view returns (uint) {
        return lbp.getNormalizedWeights()[1];
    }

    function _decimals(IERC20 _token) internal view returns (uint){
        return ERC20(address(_token)).decimals();
    }

    function tokenIndex(IERC20 _token) public view returns (uint _tokenIndex){
        (IERC20[] memory t,,) = bVault.getPoolTokens(lbp.getPoolId());
        if (t[0] == _token) {
            _tokenIndex = 0;
        } else if (t[1] == _token) {
            _tokenIndex = 1;
        } else {
            revert();
        }
        return _tokenIndex;
    }

    function _adjustDecimals(uint _amount, uint _decimalsFrom, uint _decimalsTo) internal pure returns (uint){
        if (_decimalsFrom > _decimalsTo) {
            return _amount.div(10 ** _decimalsFrom.sub(_decimalsTo));
        } else {
            return _amount.mul(10 ** _decimalsTo.sub(_decimalsFrom));
        }
    }

    function getPublicSwap() public view returns (bool){
        return lbp.getSwapEnabled();
    }

    // false = public swap will automatically be enabled when conditions are good
    // true = public swap will stay disabled until this is flipped to true
    function setStayDisabled(bool _disable) public onlyVaultManagers {
        stayDisabled = _disable;
    }

    function setWeightBounds(uint _upper, uint _lower) public onlyVaultManagers {
        require(_upper < .99 * 1e18);
        require(_lower > .01 * 1e18);
        require(_upper + lowerBound == 1 * 1e18);
        upperBound = _upper;
        lowerBound = _lower;
    }

    receive() external payable {}
}

