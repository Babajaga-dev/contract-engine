// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SatoshiTournament.sol";
import "./mocks/MockERC721.sol";
import "./mocks/MockBestiaryV4.sol";

/**
 * @title SatoshiTournament_AuditFixes.t.sol
 * @notice Dedicated test suite for all audit findings (H-01, H-02, M-01, M-02, M-03, M-04).
 *         Each section tests one specific fix with positive AND negative cases.
 *
 *         Sections:
 *         A. H-01: Auto-unlock in claimPrize (3 test)
 *         B. H-02: Atomic allocateNftPrize + withdrawNFT protection (4 test)
 *         C. M-01: Duplicate winners in submitResults (3 test)
 *         D. M-02: prizeSplitBps covers placementCount (3 test)
 *         E. M-03: uint16 placement in PrizeClaimed event (2 test)
 *         F. M-04: resultsDeadline enforcement (5 test)
 *
 *         Total: 20 test
 */
contract SatoshiTournamentAuditFixesTest is Test {
    SatoshiTournament tournament;
    MockERC721 nft1;
    MockBestiaryV4 bestiary;

    address admin;
    address organizer;
    address arbiter;
    address user1;
    address user2;
    address user3;

    function setUp() public {
        admin = makeAddr("admin");
        organizer = makeAddr("organizer");
        arbiter = makeAddr("arbiter");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        tournament = new SatoshiTournament(admin, organizer);
        nft1 = new MockERC721("NFT1", "N1");
        bestiary = new MockBestiaryV4();
        bestiary.setTournamentContract(address(tournament));

        // Grant arbiter role
        vm.prank(admin);
        tournament.grantRole(keccak256("ARBITER_ROLE"), arbiter);

        // Fund organizer
        vm.deal(organizer, 100 ether);
    }

    // =====================================================================
    //  HELPERS
    // =====================================================================

    function _arenaConfig() internal view returns (SatoshiTournament.TournamentConfig memory) {
        return SatoshiTournament.TournamentConfig({
            name: "Audit Test Arena",
            format: SatoshiTournament.TournamentFormat.ARENA_APERTA,
            structure: SatoshiTournament.BracketStructure.SWISS_BRACKET,
            bestOf: 3,
            maxPlayers: 0,
            arbiter: arbiter,
            bestiaryContract: address(0)
        });
    }

    function _conquistaConfig() internal view returns (SatoshiTournament.TournamentConfig memory) {
        return SatoshiTournament.TournamentConfig({
            name: "Audit Test Conquista",
            format: SatoshiTournament.TournamentFormat.CONQUISTA,
            structure: SatoshiTournament.BracketStructure.SINGLE_ELIM,
            bestOf: 3,
            maxPlayers: 0,
            arbiter: arbiter,
            bestiaryContract: address(bestiary)
        });
    }

    /// @dev Mint 10 cards to a user for Conquista lock
    function _mint10Cards(address to) internal returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; i++) {
            ids[i] = bestiary.mintTo(to);
        }
        return ids;
    }

    /// @dev Full cycle: create Arena, fund, register 2 users, start, submit, enableClaims
    function _fullCycleArena() internal returns (uint256 tid) {
        vm.prank(organizer);
        tournament.depositToTreasury{value: 5 ether}();

        vm.prank(organizer);
        tid = tournament.createTournament(_arenaConfig());

        vm.prank(organizer);
        tournament.allocateEthPrize(tid, 1 ether);

        uint16[] memory split = new uint16[](2);
        split[0] = 7000;
        split[1] = 3000;
        vm.prank(organizer);
        tournament.setPrizeSplit(tid, split);

        vm.prank(organizer);
        tournament.openRegistration(tid);

        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);

        vm.prank(organizer);
        tournament.startTournament(tid);

        address[] memory winners = new address[](2);
        winners[0] = user1;
        winners[1] = user2;
        vm.prank(arbiter);
        tournament.submitResults(tid, winners, keccak256("logs"));

        vm.prank(organizer);
        tournament.enableClaims(tid);
    }

    /// @dev Full cycle: Conquista with lock, up to CLAIMABLE
    function _fullCycleConquista() internal returns (uint256 tid, uint256[] memory user1Cards, uint256[] memory user2Cards) {
        vm.prank(organizer);
        tournament.depositToTreasury{value: 5 ether}();

        vm.prank(organizer);
        tid = tournament.createTournament(_conquistaConfig());

        vm.prank(organizer);
        tournament.allocateEthPrize(tid, 1 ether);

        uint16[] memory split = new uint16[](2);
        split[0] = 7000;
        split[1] = 3000;
        vm.prank(organizer);
        tournament.setPrizeSplit(tid, split);

        vm.prank(organizer);
        tournament.openRegistration(tid);

        // Mint + register with lock
        user1Cards = _mint10Cards(user1);
        user2Cards = _mint10Cards(user2);

        vm.prank(user1);
        tournament.registerWithLock(tid, user1Cards);
        vm.prank(user2);
        tournament.registerWithLock(tid, user2Cards);

        vm.prank(organizer);
        tournament.startTournament(tid);

        address[] memory winners = new address[](2);
        winners[0] = user1;
        winners[1] = user2;
        vm.prank(arbiter);
        tournament.submitResults(tid, winners, keccak256("logs"));

        vm.prank(organizer);
        tournament.enableClaims(tid);
    }

    // =====================================================================
    //  SECTION A: H-01 — Auto-unlock in claimPrize (3 test)
    // =====================================================================

    /// @notice H-01: claimPrize auto-unlocks locked tokens for winner in Conquista format
    function test_H01_claimPrize_autounlocks_conquista() public {
        (uint256 tid, uint256[] memory cards,) = _fullCycleConquista();

        // Before claim: tokens should be locked
        for (uint256 i; i < cards.length; i++) {
            assertTrue(bestiary.tokenLocked(cards[i]), "Card should be locked before claim");
        }

        // Claim
        vm.prank(user1);
        tournament.claimPrize(tid);

        // After claim: tokens should be auto-unlocked
        for (uint256 i; i < cards.length; i++) {
            assertFalse(bestiary.tokenLocked(cards[i]), "Card should be unlocked after claim");
        }

        // lockedTokens should be cleared
        uint256[] memory remaining = tournament.getLockedTokens(tid, user1);
        assertEq(remaining.length, 0, "lockedTokens should be empty after claim");
    }

    /// @notice H-01: claimPrize works for Arena (no lock) — no revert
    function test_H01_claimPrize_noLock_arenaAperta() public {
        uint256 tid = _fullCycleArena();

        vm.prank(user1);
        tournament.claimPrize(tid);

        assertTrue(tournament.hasClaimed(tid, user1));
    }

    /// @notice H-01: selfUnlock works for Conquista after cancellation
    function test_H01_selfUnlock_afterCancel() public {
        vm.prank(organizer);
        tournament.depositToTreasury{value: 5 ether}();

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());

        vm.prank(organizer);
        tournament.openRegistration(tid);

        uint256[] memory cards = _mint10Cards(user1);
        uint256[] memory cards2 = _mint10Cards(user2);

        vm.prank(user1);
        tournament.registerWithLock(tid, cards);
        vm.prank(user2);
        tournament.registerWithLock(tid, cards2);

        vm.prank(organizer);
        tournament.startTournament(tid);

        // Advance time past results deadline to allow cancellation
        vm.warp(block.timestamp + 7 days + 1);

        // Cancel (now allowed after resultsDeadline in M-04 fix)
        vm.prank(organizer);
        tournament.cancelTournament(tid);

        // selfUnlock works after cancel
        vm.prank(user1);
        tournament.selfUnlock(tid);

        for (uint256 i; i < cards.length; i++) {
            assertFalse(bestiary.tokenLocked(cards[i]), "Card should be unlocked after selfUnlock");
        }
    }

    /// @notice CRITICAL: Exploit test — selfUnlock during REGISTRATION must revert.
    ///         Without this fix, a player could register with lock, immediately selfUnlock,
    ///         and remain registered (isRegistered=true) while cards are free.
    function test_H01_exploit_selfUnlock_during_registration_reverts() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());

        vm.prank(organizer);
        tournament.openRegistration(tid);

        uint256[] memory cards = _mint10Cards(user1);

        // Register with lock
        vm.prank(user1);
        tournament.registerWithLock(tid, cards);

        // Verify: cards ARE locked
        for (uint256 i; i < cards.length; i++) {
            assertTrue(bestiary.tokenLocked(cards[i]), "Card should be locked after registerWithLock");
        }

        // Exploit attempt: selfUnlock in REGISTRATION — MUST REVERT
        vm.prank(user1);
        vm.expectRevert(SatoshiTournament.TournamentStillInProgress.selector);
        tournament.selfUnlock(tid);

        // Verify: cards STILL locked (exploit failed)
        for (uint256 i; i < cards.length; i++) {
            assertTrue(bestiary.tokenLocked(cards[i]), "Card must remain locked - exploit must fail");
        }
    }

    /// @notice selfUnlock during CREATED status must also revert
    function test_H01_selfUnlock_during_created_reverts() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());

        // Tournament is CREATED, no one registered yet, but someone with lockedTokens shouldn't unlock
        vm.prank(user1);
        vm.expectRevert(SatoshiTournament.TournamentStillInProgress.selector);
        tournament.selfUnlock(tid);
    }

    /// @notice unlockBatch during REGISTRATION must revert (organizer cannot bypass either)
    function test_H01_unlockBatch_during_registration_reverts() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());

        vm.prank(organizer);
        tournament.openRegistration(tid);

        uint256[] memory cards = _mint10Cards(user1);
        vm.prank(user1);
        tournament.registerWithLock(tid, cards);

        // Organizer tries batch unlock during REGISTRATION — MUST REVERT
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.TournamentStillInProgress.selector);
        tournament.unlockBatch(tid, 0, 1);
    }

    /// @notice Correct flow: cancel → CLOSED → selfUnlock works
    function test_H01_correct_flow_cancel_then_selfUnlock() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());

        vm.prank(organizer);
        tournament.openRegistration(tid);

        uint256[] memory cards = _mint10Cards(user1);
        vm.prank(user1);
        tournament.registerWithLock(tid, cards);

        // Organizer cancels tournament (REGISTRATION → CLOSED)
        vm.prank(organizer);
        tournament.cancelTournament(tid);

        // NOW selfUnlock works (status is CLOSED > IN_PROGRESS)
        vm.prank(user1);
        tournament.selfUnlock(tid);

        for (uint256 i; i < cards.length; i++) {
            assertFalse(bestiary.tokenLocked(cards[i]), "Card should be unlocked after cancel + selfUnlock");
        }
    }

    // =====================================================================
    //  SECTION B: H-02 — Atomic allocateNftPrize + withdrawNFT (4 test)
    // =====================================================================

    /// @notice H-02: After allocateNftPrize, NFT cannot be withdrawn from treasury
    ///         (reverts with NftNotInTreasury because treasuryNfts is cleared on allocation)
    function test_H02_allocated_nft_cannot_be_withdrawn() public {
        // Deposit NFT
        nft1.mintId(organizer, 100);
        vm.prank(organizer);
        nft1.approve(address(tournament), 100);
        vm.prank(organizer);
        tournament.depositNFTToTreasury(address(nft1), 100);

        // Create tournament + allocate NFT
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.allocateNftPrize(tid, address(nft1), 100);

        // Try withdraw — should revert (NftNotInTreasury is the first guard,
        // NftAllocatedToActiveTournament is the second defense layer)
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.NftNotInTreasury.selector);
        tournament.withdrawNFT(address(nft1), 100);
    }

    /// @notice H-02: nftAllocatedToTournament is set BEFORE treasuryNfts is cleared
    function test_H02_allocation_order_is_atomic() public {
        nft1.mintId(organizer, 200);
        vm.prank(organizer);
        nft1.approve(address(tournament), 200);
        vm.prank(organizer);
        tournament.depositNFTToTreasury(address(nft1), 200);

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());

        // After allocation: treasuryNfts = false, nftAllocatedToTournament = tid+1
        vm.prank(organizer);
        tournament.allocateNftPrize(tid, address(nft1), 200);

        assertFalse(tournament.treasuryNfts(address(nft1), 200), "treasuryNfts should be false");
        assertEq(tournament.nftAllocatedToTournament(address(nft1), 200), tid + 1, "allocation tracking should be set");
    }

    /// @notice H-02: After deallocatePrize, NFT returns to treasury and allocation is cleared
    function test_H02_deallocate_clears_tracking() public {
        nft1.mintId(organizer, 300);
        vm.prank(organizer);
        nft1.approve(address(tournament), 300);
        vm.prank(organizer);
        tournament.depositNFTToTreasury(address(nft1), 300);

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.allocateNftPrize(tid, address(nft1), 300);

        // Deallocate
        vm.prank(organizer);
        tournament.deallocatePrize(tid);

        // Should be back in treasury, allocation cleared
        assertTrue(tournament.treasuryNfts(address(nft1), 300), "NFT should be back in treasury");
        assertEq(tournament.nftAllocatedToTournament(address(nft1), 300), 0, "allocation should be cleared");

        // Now withdrawal should work
        vm.prank(organizer);
        tournament.withdrawNFT(address(nft1), 300);
        assertEq(nft1.ownerOf(300), organizer, "NFT should be transferred to organizer");
    }

    /// @notice H-02: closeTournament clears allocation for unclaimed NFTs
    function test_H02_closeTournament_clears_allocation() public {
        // Setup: deposit NFT + create full cycle with NFT prize
        nft1.mintId(organizer, 400);
        vm.prank(organizer);
        nft1.approve(address(tournament), 400);
        vm.prank(organizer);
        tournament.depositNFTToTreasury(address(nft1), 400);

        _fullCycleArena();

        // Allocate NFT to tournament (can't do it in CLAIMABLE, so let's test with a new tournament)
        // Actually we need to test closeTournament flow properly
        // Let's create a fresh flow with NFT allocated before start
        vm.prank(organizer);
        tournament.depositToTreasury{value: 2 ether}();

        vm.prank(organizer);
        uint256 tid2 = tournament.createTournament(_arenaConfig());

        vm.prank(organizer);
        tournament.allocateNftPrize(tid2, address(nft1), 400);
        vm.prank(organizer);
        tournament.assignNftToPlacement(tid2, 0, 1);

        vm.prank(organizer);
        tournament.allocateEthPrize(tid2, 1 ether);
        uint16[] memory split = new uint16[](2);
        split[0] = 7000;
        split[1] = 3000;
        vm.prank(organizer);
        tournament.setPrizeSplit(tid2, split);

        vm.prank(organizer);
        tournament.openRegistration(tid2);
        vm.prank(user1);
        tournament.register(tid2);
        vm.prank(user3);
        tournament.register(tid2);

        vm.prank(organizer);
        tournament.startTournament(tid2);

        address[] memory winners = new address[](2);
        winners[0] = user1;
        winners[1] = user3;
        vm.prank(arbiter);
        tournament.submitResults(tid2, winners, keccak256("logs2"));

        vm.prank(organizer);
        tournament.enableClaims(tid2);

        // Skip claim period without claiming NFT
        vm.warp(block.timestamp + 31 days);
        vm.prank(organizer);
        tournament.closeTournament(tid2);

        // Allocation should be cleared
        assertEq(tournament.nftAllocatedToTournament(address(nft1), 400), 0, "allocation cleared after close");
        // NFT back in treasury
        assertTrue(tournament.treasuryNfts(address(nft1), 400), "NFT returned to treasury");
    }

    // =====================================================================
    //  SECTION C: M-01 — Duplicate winners in submitResults (3 test)
    // =====================================================================

    /// @notice M-01: submitResults reverts on duplicate winner address
    function test_M01_submitResults_duplicateWinner_reverts() public {
        vm.prank(organizer);
        tournament.depositToTreasury{value: 5 ether}();

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());

        vm.prank(organizer);
        tournament.openRegistration(tid);
        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);
        vm.prank(user3);
        tournament.register(tid);

        vm.prank(organizer);
        tournament.startTournament(tid);

        // Try submit with user1 in two positions
        address[] memory winners = new address[](3);
        winners[0] = user1;
        winners[1] = user2;
        winners[2] = user1; // duplicate!

        vm.prank(arbiter);
        vm.expectRevert(SatoshiTournament.DuplicateWinner.selector);
        tournament.submitResults(tid, winners, keccak256("logs"));
    }

    /// @notice M-01: submitResults accepts unique winners
    function test_M01_submitResults_uniqueWinners_success() public {
        vm.prank(organizer);
        tournament.depositToTreasury{value: 5 ether}();

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());

        vm.prank(organizer);
        tournament.openRegistration(tid);
        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);

        vm.prank(organizer);
        tournament.startTournament(tid);

        address[] memory winners = new address[](2);
        winners[0] = user1;
        winners[1] = user2;

        vm.prank(arbiter);
        tournament.submitResults(tid, winners, keccak256("logs"));

        assertEq(tournament.placementCount(tid), 2);
    }

    /// @notice M-01: submitResults reverts for unregistered winner
    function test_M01_submitResults_unregistered_reverts() public {
        vm.prank(organizer);
        tournament.depositToTreasury{value: 5 ether}();

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());

        vm.prank(organizer);
        tournament.openRegistration(tid);
        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);

        vm.prank(organizer);
        tournament.startTournament(tid);

        address[] memory winners = new address[](2);
        winners[0] = user1;
        winners[1] = user3; // not registered

        vm.prank(arbiter);
        vm.expectRevert(SatoshiTournament.WinnerNotRegistered.selector);
        tournament.submitResults(tid, winners, keccak256("logs"));
    }

    // =====================================================================
    //  SECTION D: M-02 — prizeSplitBps covers placementCount (3 test)
    // =====================================================================

    /// @notice M-02: enableClaims reverts when prizeSplitBps is too short for placements
    function test_M02_enableClaims_splitTooShort_reverts() public {
        vm.prank(organizer);
        tournament.depositToTreasury{value: 5 ether}();

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());

        vm.prank(organizer);
        tournament.allocateEthPrize(tid, 1 ether);

        // Only 1 split entry but will have 2 placements
        uint16[] memory split = new uint16[](1);
        split[0] = 10000; // 100% to 1st place only
        vm.prank(organizer);
        tournament.setPrizeSplit(tid, split);

        vm.prank(organizer);
        tournament.openRegistration(tid);
        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);

        vm.prank(organizer);
        tournament.startTournament(tid);

        // Submit 2 placements
        address[] memory winners = new address[](2);
        winners[0] = user1;
        winners[1] = user2;
        vm.prank(arbiter);
        tournament.submitResults(tid, winners, keccak256("logs"));

        // Enable claims should revert (split covers 1, but 2 placements)
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.PrizeSplitTooShort.selector);
        tournament.enableClaims(tid);
    }

    /// @notice M-02: enableClaims succeeds when split covers all placements
    function test_M02_enableClaims_splitCoversAll_success() public {
        _fullCycleArena();
        // Already in CLAIMABLE — the fullCycle helper uses matching split/placements
        assertTrue(true, "enableClaims succeeded");
    }

    /// @notice M-02: enableClaims succeeds without ETH prize (NFT-only)
    function test_M02_enableClaims_noEthPrize_success() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());

        // No ETH prize, no split needed
        vm.prank(organizer);
        tournament.openRegistration(tid);
        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);

        vm.prank(organizer);
        tournament.startTournament(tid);

        address[] memory winners = new address[](2);
        winners[0] = user1;
        winners[1] = user2;
        vm.prank(arbiter);
        tournament.submitResults(tid, winners, keccak256("logs"));

        // enableClaims should work even without split (ethPrize == 0)
        vm.prank(organizer);
        tournament.enableClaims(tid);

        assertEq(uint8(tournament.getTournamentStatus(tid)), uint8(SatoshiTournament.TournamentStatus.CLAIMABLE));
    }

    // =====================================================================
    //  SECTION E: M-03 — uint16 placement in PrizeClaimed event (2 test)
    // =====================================================================

    /// @notice M-03: PrizeClaimed event emits correct uint16 placement (not truncated)
    function test_M03_prizeClaimed_emits_uint16_placement() public {
        uint256 tid = _fullCycleArena();

        // Expect PrizeClaimed with position=1 (uint16)
        vm.expectEmit(true, true, false, true);
        emit SatoshiTournament.PrizeClaimed(tid, user1, 1, 0.7 ether);

        vm.prank(user1);
        tournament.claimPrize(tid);
    }

    /// @notice M-03: 2nd place claimPrize emits correct position and amount
    function test_M03_prizeClaimed_secondPlace() public {
        uint256 tid = _fullCycleArena();

        vm.expectEmit(true, true, false, true);
        emit SatoshiTournament.PrizeClaimed(tid, user2, 2, 0.3 ether);

        vm.prank(user2);
        tournament.claimPrize(tid);
    }

    // =====================================================================
    //  SECTION F: M-04 — resultsDeadline enforcement (5 test)
    // =====================================================================

    /// @notice M-04: startTournament sets resultsDeadline — verified by submitting at deadline edge
    function test_M04_startTournament_setsDeadline() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());

        vm.prank(organizer);
        tournament.openRegistration(tid);
        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);

        uint256 startTs = block.timestamp;
        vm.prank(organizer);
        tournament.startTournament(tid);

        // Verify: submit at exactly deadline should succeed (block.timestamp == deadline, not >)
        vm.warp(startTs + 7 days);

        address[] memory winners = new address[](2);
        winners[0] = user1;
        winners[1] = user2;
        vm.prank(arbiter);
        tournament.submitResults(tid, winners, keccak256("logs"));
        // If deadline was set correctly, this passes (timestamp == deadline is allowed)
        assertEq(tournament.placementCount(tid), 2);
    }

    /// @notice M-04: submitResults works before deadline
    function test_M04_submitResults_beforeDeadline_success() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());

        vm.prank(organizer);
        tournament.openRegistration(tid);
        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);

        vm.prank(organizer);
        tournament.startTournament(tid);

        // Submit within deadline (warp to day 6)
        vm.warp(block.timestamp + 6 days);

        address[] memory winners = new address[](2);
        winners[0] = user1;
        winners[1] = user2;
        vm.prank(arbiter);
        tournament.submitResults(tid, winners, keccak256("logs"));

        assertEq(tournament.placementCount(tid), 2);
    }

    /// @notice M-04: submitResults reverts after deadline
    function test_M04_submitResults_afterDeadline_reverts() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());

        vm.prank(organizer);
        tournament.openRegistration(tid);
        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);

        vm.prank(organizer);
        tournament.startTournament(tid);

        // Warp past deadline (7 days + 1 second)
        vm.warp(block.timestamp + 7 days + 1);

        address[] memory winners = new address[](2);
        winners[0] = user1;
        winners[1] = user2;

        vm.prank(arbiter);
        vm.expectRevert(SatoshiTournament.ResultsDeadlineExpired.selector);
        tournament.submitResults(tid, winners, keccak256("logs"));
    }

    /// @notice M-04: cancelTournament allowed for IN_PROGRESS after deadline
    function test_M04_cancelTournament_inProgress_afterDeadline_success() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());

        vm.prank(organizer);
        tournament.openRegistration(tid);
        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);

        vm.prank(organizer);
        tournament.startTournament(tid);

        // Warp past deadline
        vm.warp(block.timestamp + 7 days + 1);

        // Cancel should now work
        vm.prank(organizer);
        tournament.cancelTournament(tid);

        assertEq(uint8(tournament.getTournamentStatus(tid)), uint8(SatoshiTournament.TournamentStatus.CLOSED));
    }

    /// @notice M-04: cancelTournament reverts for IN_PROGRESS before deadline
    function test_M04_cancelTournament_inProgress_beforeDeadline_reverts() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());

        vm.prank(organizer);
        tournament.openRegistration(tid);
        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);

        vm.prank(organizer);
        tournament.startTournament(tid);

        // Try cancel immediately (before deadline)
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.ResultsDeadlineNotReached.selector);
        tournament.cancelTournament(tid);
    }
}
