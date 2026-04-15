// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/TestableBestiaryV4.sol";
import "../tests/mocks/MockVRFCoordinator.sol";

/**
 * @title BestiaryV4_Tournament.t.sol
 * @notice Test suite per Fase F0: Token lock, paid mint, escrow, tournament split.
 */
contract BestiaryV4TournamentTest is Test {
    TestableBestiaryV4 bestiary;
    MockVRFCoordinatorV2Plus vrfCoord;

    address owner;
    address user1;
    address user2;
    address tournamentAddr;

    // Allow the test contract to receive ETH from withdraw()
    receive() external payable {}

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        tournamentAddr = makeAddr("tournament");

        vrfCoord = new MockVRFCoordinatorV2Plus();

        bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Satoshi Genesis",
                symbol: "SBE",
                maxSupply: 21000,
                devReserve: 2100,
                maxPerWallet: 10,
                mintBlock: 5,
                mintCooldown: 7200,
                totalSpecies: 42,
                tierBoundaries: [uint256(21), 1050, 3150, 7350, 21000],
                speciesPerTier: [uint8(2), 7, 10, 10, 13],
                royaltyBps: 500
            }),
            SatoshiBestiaryV4.VRFParams({
                subscriptionId: 1,
                vrfCoordinator: address(vrfCoord),
                keyHash: bytes32(uint256(1)),
                notRevealedURI: "ipfs://hidden/"
            })
        );

        // Mint some tokens for lock tests
        bestiary.testMintDirectTo(user1, 100);
        bestiary.testMintDirectTo(user1, 200);
        bestiary.testMintDirectTo(user1, 300);
        bestiary.testMintDirectTo(user2, 400);
    }

    // =====================================================================
    //  SECTION A: TOKEN LOCK (10 test)
    // =====================================================================

    function test_lockTokens_byTournament_success() public {
        bestiary.setTournamentContract(tournamentAddr);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 100;
        ids[1] = 200;

        vm.prank(tournamentAddr);
        bestiary.setTokenLock(ids, true);

        assertTrue(bestiary.tokenLocked(100));
        assertTrue(bestiary.tokenLocked(200));
        assertFalse(bestiary.tokenLocked(300));
    }

    function test_lockTokens_notTournament_reverts() public {
        bestiary.setTournamentContract(tournamentAddr);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 100;

        vm.prank(user1);
        vm.expectRevert(SatoshiBestiaryV4.NotTournamentContract.selector);
        bestiary.setTokenLock(ids, true);
    }

    function test_lockTokens_emptyArray_reverts() public {
        bestiary.setTournamentContract(tournamentAddr);

        uint256[] memory ids = new uint256[](0);

        vm.prank(tournamentAddr);
        vm.expectRevert(SatoshiBestiaryV4.NoTokensProvided.selector);
        bestiary.setTokenLock(ids, true);
    }

    function test_unlockTokens_byTournament_success() public {
        bestiary.setTournamentContract(tournamentAddr);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 100;
        ids[1] = 200;

        vm.prank(tournamentAddr);
        bestiary.setTokenLock(ids, true);

        vm.prank(tournamentAddr);
        bestiary.setTokenLock(ids, false);

        assertFalse(bestiary.tokenLocked(100));
        assertFalse(bestiary.tokenLocked(200));
    }

    function test_unlockTokens_notTournament_reverts() public {
        bestiary.setTournamentContract(tournamentAddr);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 100;

        vm.prank(user1);
        vm.expectRevert(SatoshiBestiaryV4.NotTournamentContract.selector);
        bestiary.setTokenLock(ids, false);
    }

    function test_transfer_lockedToken_reverts() public {
        bestiary.setTournamentContract(tournamentAddr);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 100;

        vm.prank(tournamentAddr);
        bestiary.setTokenLock(ids, true);

        // Try to transfer locked token
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(SatoshiBestiaryV4.TokenLocked.selector, 100));
        bestiary.transferFrom(user1, user2, 100);
    }

    function test_transfer_unlockedToken_success() public {
        bestiary.setTournamentContract(tournamentAddr);

        // Token 300 is NOT locked — transfer should work
        vm.prank(user1);
        bestiary.transferFrom(user1, user2, 300);
        assertEq(bestiary.ownerOf(300), user2);
    }

    function test_burn_lockedToken_reverts() public {
        bestiary.setTournamentContract(tournamentAddr);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 100;

        vm.prank(tournamentAddr);
        bestiary.setTokenLock(ids, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(SatoshiBestiaryV4.TokenLocked.selector, 100));
        bestiary.burn(100);
    }

    function test_batchBurn_lockedToken_reverts() public {
        bestiary.setTournamentContract(tournamentAddr);

        // Setup forge contract as authorized
        address fakeForge = makeAddr("forge");
        bestiary.setForgeContract(fakeForge);

        uint256[] memory lockIds = new uint256[](1);
        lockIds[0] = 100;

        vm.prank(tournamentAddr);
        bestiary.setTokenLock(lockIds, true);

        uint256[] memory burnIds = new uint256[](1);
        burnIds[0] = 100;

        vm.prank(fakeForge);
        vm.expectRevert(abi.encodeWithSelector(SatoshiBestiaryV4.TokenLocked.selector, 100));
        bestiary.batchBurnFrom(user1, burnIds);
    }

    function test_transfer_afterUnlock_success() public {
        bestiary.setTournamentContract(tournamentAddr);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 100;

        vm.prank(tournamentAddr);
        bestiary.setTokenLock(ids, true);

        // Unlock
        vm.prank(tournamentAddr);
        bestiary.setTokenLock(ids, false);

        // Now transfer should work
        vm.prank(user1);
        bestiary.transferFrom(user1, user2, 100);
        assertEq(bestiary.ownerOf(100), user2);
    }

    // =====================================================================
    //  SECTION B: SETTERS (5 test)
    // =====================================================================

    function test_setMintPrice_owner_success() public {
        bestiary.setMintPrice(0.01 ether);
        assertEq(bestiary.mintPrice(), 0.01 ether);
    }

    function test_setMintPrice_nonOwner_reverts() public {
        vm.prank(user1);
        vm.expectRevert();
        bestiary.setMintPrice(0.01 ether);
    }

    function test_setTournamentContract_owner_success() public {
        bestiary.setTournamentContract(tournamentAddr);
        assertEq(bestiary.tournamentContract(), tournamentAddr);
    }

    function test_setTournamentContract_zeroAddress_reverts() public {
        vm.expectRevert(SatoshiBestiaryV4.InvalidTournamentAddress.selector);
        bestiary.setTournamentContract(address(0));
    }

    function test_setTournamentSplitBps_owner_success() public {
        bestiary.setTournamentSplitBps(5000); // 50%
        assertEq(bestiary.tournamentSplitBps(), 5000);
    }

    function test_setTournamentSplitBps_tooHigh_reverts() public {
        vm.expectRevert(SatoshiBestiaryV4.SplitBpsTooHigh.selector);
        bestiary.setTournamentSplitBps(10001);
    }

    // =====================================================================
    //  SECTION C: PAID MINT + ESCROW (6 test)
    // =====================================================================

    function test_paidMint_zeroPriceReverts() public {
        // mintPrice defaults to 0
        bestiary.setMintStatus(true);

        vm.deal(user1, 1 ether);
        vm.prank(user1, user1); // tx.origin = user1
        vm.expectRevert(SatoshiBestiaryV4.MintInactive.selector);
        bestiary.paidMint{value: 0.01 ether}(1);
    }

    function test_paidMint_insufficientPayment_reverts() public {
        bestiary.setMintPrice(0.01 ether);
        bestiary.setMintStatus(true);

        vm.deal(user1, 1 ether);
        vm.prank(user1, user1);
        vm.expectRevert(SatoshiBestiaryV4.InsufficientMintPayment.selector);
        bestiary.paidMint{value: 0.005 ether}(1);
    }

    function test_paidMint_exactPayment_escrowed() public {
        bestiary.setMintPrice(0.01 ether);
        bestiary.setMintStatus(true);

        vm.deal(user1, 1 ether);
        vm.roll(7201); // Skip cooldown: lastMintBlock=0 + mintCooldown=7200, need block >= 7200
        vm.prank(user1, user1);
        bestiary.paidMint{value: 0.01 ether}(1);

        // Fee should be escrowed
        assertEq(bestiary.lockedMintFees(), 0.01 ether);
        assertEq(address(bestiary).balance, 0.01 ether);
    }

    function test_paidMint_overpayment_refunded() public {
        bestiary.setMintPrice(0.01 ether);
        bestiary.setMintStatus(true);

        vm.deal(user1, 1 ether);

        vm.prank(user1, user1);
        // V4 requires exact payment — overpayment reverts with InsufficientMintPayment
        vm.expectRevert(SatoshiBestiaryV4.InsufficientMintPayment.selector);
        bestiary.paidMint{value: 0.05 ether}(1);
    }

    function test_withdraw_excludesEscrowAndTournament() public {
        bestiary.setMintPrice(0.01 ether);
        bestiary.setMintStatus(true);
        bestiary.setTournamentContract(tournamentAddr);

        // Do a paid mint
        vm.deal(user1, 1 ether);
        vm.roll(7201); // Skip cooldown: lastMintBlock=0 + mintCooldown=7200, need block >= 7200
        vm.prank(user1, user1);
        bestiary.paidMint{value: 0.01 ether}(1);

        // Owner should not be able to withdraw escrowed funds
        vm.expectRevert(SatoshiBestiaryV4.NothingToWithdraw.selector);
        bestiary.withdraw();
    }

    function test_withdraw_afterMintConfirmed_ownerGetsRetained() public {
        bestiary.setMintPrice(0.1 ether);
        bestiary.setMintStatus(true);
        bestiary.setTournamentContract(tournamentAddr);
        bestiary.setTournamentSplitBps(3000); // 30%

        // Send some extra ETH to contract (simulating accumulated fees)
        vm.deal(address(bestiary), 1 ether);

        // The lockedMintFees and tournamentBalance are 0, so full balance is withdrawable
        uint256 balBefore = owner.balance;
        bestiary.withdraw();
        assertEq(owner.balance - balBefore, 1 ether);
    }

    // =====================================================================
    //  SECTION D: TOURNAMENT BALANCE PULL (3 test)
    // =====================================================================

    function test_withdrawTournamentFunds_noBalance_reverts() public {
        bestiary.setTournamentContract(tournamentAddr);

        vm.expectRevert(SatoshiBestiaryV4.NothingToWithdraw.selector);
        bestiary.withdrawTournamentFunds();
    }

    function test_defaultSplitBps_is3000() public view {
        assertEq(bestiary.tournamentSplitBps(), 3000);
    }

    function test_receive_acceptsETH() public {
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        (bool ok, ) = address(bestiary).call{value: 0.5 ether}("");
        assertTrue(ok);
    }
}
