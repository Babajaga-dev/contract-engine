// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SatoshiTournament.sol";
import "./mocks/MockERC721.sol";
import "./mocks/MockBestiaryV4.sol";

/**
 * @title SatoshiTournament_Security.t.sol
 * @notice Test suite di sicurezza e stress per SatoshiTournament.
 *
 *         Sezioni:
 *         A. Access Control (12 test)
 *         B. Treasury Security (10 test)
 *         C. Tournament Lifecycle Integrity (10 test)
 *         D. Registration & Lock Security (10 test)
 *         E. Claims & Reentrancy (8 test)
 *         F. Stress Test — Molti Utenti (6 test)
 *         G. Edge Cases (6 test)
 *
 *         Totale: ~62 test
 */
contract SatoshiTournamentSecurityTest is Test {
    SatoshiTournament tournament;
    MockERC721 nft1;
    MockERC721 nft2;
    MockBestiaryV4 bestiary;

    address admin;
    address organizer;
    address arbiter;
    address user1;
    address user2;
    address user3;
    address attacker;

    // Helper: default tournament config (Arena Aperta)
    function _arenaConfig() internal view returns (SatoshiTournament.TournamentConfig memory) {
        return SatoshiTournament.TournamentConfig({
            name: "Test Arena",
            format: SatoshiTournament.TournamentFormat.ARENA_APERTA,
            structure: SatoshiTournament.BracketStructure.SWISS_BRACKET,
            bestOf: 3,
            maxPlayers: 0,
            arbiter: arbiter,
            bestiaryContract: address(0)
        });
    }

    // Helper: Conquista config (con lock)
    function _conquistaConfig() internal view returns (SatoshiTournament.TournamentConfig memory) {
        return SatoshiTournament.TournamentConfig({
            name: "Test Conquista",
            format: SatoshiTournament.TournamentFormat.CONQUISTA,
            structure: SatoshiTournament.BracketStructure.SINGLE_ELIM,
            bestOf: 3,
            maxPlayers: 0,
            arbiter: arbiter,
            bestiaryContract: address(bestiary)
        });
    }

    // Helper: Sigillo d'Oro config
    function _sigilloConfig() internal view returns (SatoshiTournament.TournamentConfig memory) {
        return SatoshiTournament.TournamentConfig({
            name: "Test Sigillo",
            format: SatoshiTournament.TournamentFormat.SIGILLO_ORO,
            structure: SatoshiTournament.BracketStructure.SWISS_BRACKET,
            bestOf: 5,
            maxPlayers: 8,
            arbiter: arbiter,
            bestiaryContract: address(bestiary)
        });
    }

    // Helper: crea torneo Arena + apre registrazioni + registra N giocatori
    function _createArenaWithPlayers(uint256 count) internal returns (uint256 tid) {
        vm.prank(organizer);
        tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.openRegistration(tid);
        for (uint256 i; i < count; i++) {
            address p = makeAddr(string(abi.encodePacked("player", vm.toString(i))));
            vm.prank(p);
            tournament.register(tid);
        }
    }

    // Helper: ciclo completo fino a CLAIMABLE con 2 giocatori
    function _fullCycleArena() internal returns (uint256 tid) {
        // Deposita ETH nella treasury
        vm.deal(organizer, 10 ether);
        vm.prank(organizer);
        tournament.depositToTreasury{value: 5 ether}();

        // Crea torneo
        vm.prank(organizer);
        tid = tournament.createTournament(_arenaConfig());

        // Alloca premi + split
        vm.prank(organizer);
        tournament.allocateEthPrize(tid, 1 ether);
        uint16[] memory split = new uint16[](2);
        split[0] = 7000; // 70% al 1°
        split[1] = 3000; // 30% al 2°
        vm.prank(organizer);
        tournament.setPrizeSplit(tid, split);

        // Registrazione
        vm.prank(organizer);
        tournament.openRegistration(tid);
        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);

        // Start
        vm.prank(organizer);
        tournament.startTournament(tid);

        // Submit results
        address[] memory winners = new address[](2);
        winners[0] = user1;
        winners[1] = user2;
        vm.prank(arbiter);
        tournament.submitResults(tid, winners, keccak256("logs"));

        // Enable claims
        vm.prank(organizer);
        tournament.enableClaims(tid);
    }

    // Helper: minta 10 carte al giocatore su bestiary
    function _mint10Cards(address to) internal returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; i++) {
            ids[i] = bestiary.mintTo(to);
        }
        return ids;
    }

    // Helper: minta 15 carte al giocatore su bestiary
    function _mint15Cards(address to) internal returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](15);
        for (uint256 i; i < 15; i++) {
            ids[i] = bestiary.mintTo(to);
        }
        return ids;
    }

    function setUp() public {
        admin = makeAddr("admin");
        organizer = makeAddr("organizer");
        arbiter = makeAddr("arbiter");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        attacker = makeAddr("attacker");

        // Deploy contratti
        tournament = new SatoshiTournament(admin, organizer);
        nft1 = new MockERC721("NFT1", "N1");
        nft2 = new MockERC721("NFT2", "N2");
        bestiary = new MockBestiaryV4();
        bestiary.setTournamentContract(address(tournament));

        // Grant arbiter role
        bytes32 arbiterRole = keccak256("ARBITER_ROLE");
        vm.prank(admin);
        tournament.grantRole(arbiterRole, arbiter);
    }

    // =====================================================================
    //  SECTION A: ACCESS CONTROL (12 test)
    // =====================================================================

    function test_A01_onlyOrganizer_createTournament() public {
        vm.prank(attacker);
        vm.expectRevert();
        tournament.createTournament(_arenaConfig());
    }

    function test_A02_onlyOrganizer_openRegistration() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(attacker);
        vm.expectRevert();
        tournament.openRegistration(tid);
    }

    function test_A03_onlyOrganizer_startTournament() public {
        uint256 tid = _createArenaWithPlayers(2);
        vm.prank(attacker);
        vm.expectRevert();
        tournament.startTournament(tid);
    }

    function test_A04_onlyOrganizer_cancelTournament() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(attacker);
        vm.expectRevert();
        tournament.cancelTournament(tid);
    }

    function test_A05_onlyOrganizer_allocateEthPrize() public {
        vm.deal(address(tournament), 1 ether);
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(attacker);
        vm.expectRevert();
        tournament.allocateEthPrize(tid, 0.5 ether);
    }

    function test_A06_onlyOrganizer_allocateNftPrize() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(attacker);
        vm.expectRevert();
        tournament.allocateNftPrize(tid, address(nft1), 1);
    }

    function test_A07_onlyOrganizer_setPrizeSplit() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        uint16[] memory split = new uint16[](1);
        split[0] = 10000;
        vm.prank(attacker);
        vm.expectRevert();
        tournament.setPrizeSplit(tid, split);
    }

    function test_A08_onlyOrganizer_withdrawUnallocated() public {
        vm.deal(organizer, 1 ether);
        vm.prank(organizer);
        tournament.depositToTreasury{value: 1 ether}();
        vm.prank(attacker);
        vm.expectRevert();
        tournament.withdrawUnallocated(0.5 ether);
    }

    function test_A09_onlyOrganizer_withdrawNFT() public {
        // Deposita NFT
        uint256 nftId = nft1.mintTo(organizer);
        vm.prank(organizer);
        nft1.approve(address(tournament), nftId);
        vm.prank(organizer);
        tournament.depositNFTToTreasury(address(nft1), nftId);

        vm.prank(attacker);
        vm.expectRevert();
        tournament.withdrawNFT(address(nft1), nftId);
    }

    function test_A10_onlyAdmin_pause() public {
        vm.prank(attacker);
        vm.expectRevert();
        tournament.pause();
    }

    function test_A11_onlyAdmin_unpause() public {
        vm.prank(admin);
        tournament.pause();
        vm.prank(attacker);
        vm.expectRevert();
        tournament.unpause();
    }

    function test_A12_onlyAdmin_emergencyWithdraw() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(attacker);
        vm.expectRevert();
        tournament.emergencyWithdraw(tid, attacker);
    }

    // =====================================================================
    //  SECTION B: TREASURY SECURITY (10 test)
    // =====================================================================

    function test_B01_depositEth_updatesBalance() public {
        vm.deal(user1, 5 ether);
        vm.prank(user1);
        tournament.depositToTreasury{value: 2 ether}();
        assertEq(tournament.treasuryEthBalance(), 2 ether);
        assertEq(address(tournament).balance, 2 ether);
    }

    function test_B02_depositEth_zeroReverts() public {
        vm.expectRevert(SatoshiTournament.ZeroAmount.selector);
        tournament.depositToTreasury{value: 0}();
    }

    function test_B03_receive_tracksEth() public {
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        (bool ok,) = address(tournament).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(tournament.treasuryEthBalance(), 1 ether);
    }

    function test_B04_withdrawUnallocated_cannotExceedAvailable() public {
        vm.deal(organizer, 5 ether);
        vm.prank(organizer);
        tournament.depositToTreasury{value: 3 ether}();

        // Alloca 2 ETH a un torneo
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.allocateEthPrize(tid, 2 ether);

        // Prova a ritirare più di 1 ETH disponibile
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.InsufficientTreasuryEth.selector);
        tournament.withdrawUnallocated(1.5 ether);
    }

    function test_B05_withdrawUnallocated_success() public {
        vm.deal(organizer, 5 ether);
        vm.prank(organizer);
        tournament.depositToTreasury{value: 3 ether}();

        uint256 balBefore = organizer.balance;
        vm.prank(organizer);
        tournament.withdrawUnallocated(1 ether);
        assertEq(organizer.balance, balBefore + 1 ether);
        assertEq(tournament.treasuryEthBalance(), 2 ether);
    }

    function test_B06_depositNFT_tracked() public {
        uint256 nftId = nft1.mintTo(organizer);
        vm.prank(organizer);
        nft1.approve(address(tournament), nftId);
        vm.prank(organizer);
        tournament.depositNFTToTreasury(address(nft1), nftId);

        assertTrue(tournament.treasuryNfts(address(nft1), nftId));
        assertEq(tournament.treasuryNftCount(), 1);
        assertEq(nft1.ownerOf(nftId), address(tournament));
    }

    function test_B07_depositNFT_zeroAddressReverts() public {
        vm.expectRevert(SatoshiTournament.ZeroAddress.selector);
        tournament.depositNFTToTreasury(address(0), 1);
    }

    function test_B08_withdrawNFT_notInTreasuryReverts() public {
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.NftNotInTreasury.selector);
        tournament.withdrawNFT(address(nft1), 999);
    }

    function test_B09_withdrawNFT_success() public {
        uint256 nftId = nft1.mintTo(organizer);
        vm.prank(organizer);
        nft1.approve(address(tournament), nftId);
        vm.prank(organizer);
        tournament.depositNFTToTreasury(address(nft1), nftId);

        vm.prank(organizer);
        tournament.withdrawNFT(address(nft1), nftId);
        assertFalse(tournament.treasuryNfts(address(nft1), nftId));
        assertEq(nft1.ownerOf(nftId), organizer);
        assertEq(tournament.treasuryNftCount(), 0);
    }

    function test_B10_allocateEth_cannotExceedTreasury() public {
        vm.deal(organizer, 2 ether);
        vm.prank(organizer);
        tournament.depositToTreasury{value: 2 ether}();

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());

        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.InsufficientTreasuryEth.selector);
        tournament.allocateEthPrize(tid, 3 ether);
    }

    // =====================================================================
    //  SECTION C: TOURNAMENT LIFECYCLE INTEGRITY (10 test)
    // =====================================================================

    function test_C01_createTournament_invalidBestOf() public {
        SatoshiTournament.TournamentConfig memory cfg = _arenaConfig();
        cfg.bestOf = 2; // non valido (solo 1, 3, 5)
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.InvalidBestOf.selector);
        tournament.createTournament(cfg);
    }

    function test_C02_createTournament_zeroArbiter() public {
        SatoshiTournament.TournamentConfig memory cfg = _arenaConfig();
        cfg.arbiter = address(0);
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.InvalidArbiter.selector);
        tournament.createTournament(cfg);
    }

    function test_C03_conquista_needsBestiaryContract() public {
        SatoshiTournament.TournamentConfig memory cfg = _conquistaConfig();
        cfg.bestiaryContract = address(0);
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.InvalidBestiaryContract.selector);
        tournament.createTournament(cfg);
    }

    function test_C04_lifecycle_wrongStatusReverts() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());

        // Provare a startTournament senza essere in REGISTRATION
        vm.prank(organizer);
        vm.expectRevert();
        tournament.startTournament(tid);
    }

    function test_C05_cannotStartWithLessThan2Players() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.openRegistration(tid);
        vm.prank(user1);
        tournament.register(tid);

        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.NeedMinimumPlayers.selector);
        tournament.startTournament(tid);
    }

    function test_C06_fullLifecycle_ArenaAperta() public {
        uint256 tid = _fullCycleArena();
        assertEq(uint8(tournament.getTournamentStatus(tid)), uint8(SatoshiTournament.TournamentStatus.CLAIMABLE));
    }

    function test_C07_cancelTournament_returnsEthToTreasury() public {
        vm.deal(organizer, 5 ether);
        vm.prank(organizer);
        tournament.depositToTreasury{value: 5 ether}();

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.allocateEthPrize(tid, 2 ether);
        assertEq(tournament.treasuryEthAllocated(), 2 ether);

        vm.prank(organizer);
        tournament.cancelTournament(tid);

        assertEq(tournament.treasuryEthAllocated(), 0);
        assertEq(tournament.treasuryEthBalance(), 5 ether); // tutto torna disponibile
    }

    function test_C08_cancelTournament_returnsNftsToTreasury() public {
        uint256 nftId = nft1.mintTo(organizer);
        vm.prank(organizer);
        nft1.approve(address(tournament), nftId);
        vm.prank(organizer);
        tournament.depositNFTToTreasury(address(nft1), nftId);

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.allocateNftPrize(tid, address(nft1), nftId);

        assertFalse(tournament.treasuryNfts(address(nft1), nftId)); // rimosso da treasury
        assertEq(tournament.treasuryNftCount(), 0);

        vm.prank(organizer);
        tournament.cancelTournament(tid);

        assertTrue(tournament.treasuryNfts(address(nft1), nftId)); // tornato in treasury
        assertEq(tournament.treasuryNftCount(), 1);
    }

    function test_C09_deallocatePrize_onlyInCreated() public {
        vm.deal(organizer, 5 ether);
        vm.prank(organizer);
        tournament.depositToTreasury{value: 5 ether}();

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.allocateEthPrize(tid, 1 ether);

        // Apri registrazioni — status != CREATED
        vm.prank(organizer);
        tournament.openRegistration(tid);

        vm.prank(organizer);
        vm.expectRevert();
        tournament.deallocatePrize(tid);
    }

    function test_C10_prizeSplit_mustSumTo10000() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        uint16[] memory bad = new uint16[](2);
        bad[0] = 5000;
        bad[1] = 4000; // sum = 9000 ≠ 10000

        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.InvalidSplitSum.selector);
        tournament.setPrizeSplit(tid, bad);
    }

    // =====================================================================
    //  SECTION D: REGISTRATION & LOCK SECURITY (10 test)
    // =====================================================================

    function test_D01_register_onlyDuringRegistration() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        // Ancora in CREATED, non REGISTRATION
        vm.prank(user1);
        vm.expectRevert();
        tournament.register(tid);
    }

    function test_D02_register_doubleRegistrationReverts() public {
        uint256 tid = _createArenaWithPlayers(0);
        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user1);
        vm.expectRevert(SatoshiTournament.AlreadyRegistered.selector);
        tournament.register(tid);
    }

    function test_D03_register_maxPlayersEnforced() public {
        SatoshiTournament.TournamentConfig memory cfg = _arenaConfig();
        cfg.maxPlayers = 2;
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(cfg);
        vm.prank(organizer);
        tournament.openRegistration(tid);

        vm.prank(user1);
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);

        vm.prank(user3);
        vm.expectRevert(SatoshiTournament.MaxPlayersReached.selector);
        tournament.register(tid);
    }

    function test_D04_register_unlimitedPlayers() public {
        // maxPlayers = 0 = illimitato
        uint256 tid = _createArenaWithPlayers(50);
        // Se arriviamo qui senza revert, l'illimitato funziona
        (,,,,, uint32 registeredCount,,,,,,,,,,,) = tournament.tournaments(tid);
        assertEq(registeredCount, 50);
    }

    function test_D05_registerArena_cannotUseLock() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.openRegistration(tid);

        uint256[] memory fakeIds = new uint256[](10);
        vm.prank(user1);
        vm.expectRevert(SatoshiTournament.LockNotRequired.selector);
        tournament.registerWithLock(tid, fakeIds);
    }

    function test_D06_registerConquista_wrongCardCountReverts() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());
        vm.prank(organizer);
        tournament.openRegistration(tid);

        // Minta 5 carte (dovrebbero essere 10)
        uint256[] memory ids = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            ids[i] = bestiary.mintTo(user1);
        }

        vm.prank(user1);
        vm.expectRevert(SatoshiTournament.InvalidTokenCount.selector);
        tournament.registerWithLock(tid, ids);
    }

    function test_D07_registerConquista_tokenNotOwnedReverts() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());
        vm.prank(organizer);
        tournament.openRegistration(tid);

        // Minta 10 carte a user2 (non a user1)
        uint256[] memory ids = _mint10Cards(user2);

        vm.prank(user1);
        vm.expectRevert(SatoshiTournament.TokenNotOwned.selector);
        tournament.registerWithLock(tid, ids);
    }

    function test_D08_registerConquista_success_locksCards() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());
        vm.prank(organizer);
        tournament.openRegistration(tid);

        uint256[] memory ids = _mint10Cards(user1);

        vm.prank(user1);
        tournament.registerWithLock(tid, ids);

        assertTrue(tournament.isRegistered(tid, user1));
        // Verifica che le carte sono lockate nel mock
        for (uint256 i; i < ids.length; i++) {
            assertTrue(bestiary.tokenLocked(ids[i]));
        }
        // Verifica tracked
        uint256[] memory locked = tournament.getLockedTokens(tid, user1);
        assertEq(locked.length, 10);
    }

    function test_D09_sigilloOro_notInvitedReverts() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_sigilloConfig());
        vm.prank(organizer);
        tournament.openRegistration(tid);

        uint256[] memory ids = _mint15Cards(user1);

        vm.prank(user1);
        vm.expectRevert(SatoshiTournament.NotInvited.selector);
        tournament.registerWithLock(tid, ids);
    }

    function test_D10_sigilloOro_invitedCanRegister() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_sigilloConfig());
        vm.prank(organizer);
        tournament.invitePlayer(tid, user1);
        vm.prank(organizer);
        tournament.openRegistration(tid);

        uint256[] memory ids = _mint15Cards(user1);

        vm.prank(user1);
        tournament.registerWithLock(tid, ids);
        assertTrue(tournament.isRegistered(tid, user1));
    }

    // =====================================================================
    //  SECTION E: CLAIMS & REENTRANCY (8 test)
    // =====================================================================

    function test_E01_claimPrize_correctEthAmounts() public {
        uint256 tid = _fullCycleArena();

        uint256 bal1Before = user1.balance;
        uint256 bal2Before = user2.balance;

        vm.prank(user1);
        tournament.claimPrize(tid);
        vm.prank(user2);
        tournament.claimPrize(tid);

        // 70% di 1 ETH = 0.7 ETH, 30% = 0.3 ETH
        assertEq(user1.balance - bal1Before, 0.7 ether);
        assertEq(user2.balance - bal2Before, 0.3 ether);
    }

    function test_E02_claimPrize_doubleClaimReverts() public {
        uint256 tid = _fullCycleArena();

        vm.prank(user1);
        tournament.claimPrize(tid);

        vm.prank(user1);
        vm.expectRevert(SatoshiTournament.AlreadyClaimed.selector);
        tournament.claimPrize(tid);
    }

    function test_E03_claimPrize_nonWinnerReverts() public {
        uint256 tid = _fullCycleArena();

        vm.prank(user3); // non registrato, non piazzato
        vm.expectRevert(SatoshiTournament.NoPlacement.selector);
        tournament.claimPrize(tid);
    }

    function test_E04_claimPrize_withNftPrize() public {
        // Setup: deposita NFT e alloca al torneo
        uint256 nftId = nft1.mintTo(organizer);
        vm.prank(organizer);
        nft1.approve(address(tournament), nftId);
        vm.prank(organizer);
        tournament.depositNFTToTreasury(address(nft1), nftId);

        vm.deal(organizer, 5 ether);
        vm.prank(organizer);
        tournament.depositToTreasury{value: 5 ether}();

        // Crea torneo con premi
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.allocateEthPrize(tid, 1 ether);
        vm.prank(organizer);
        tournament.allocateNftPrize(tid, address(nft1), nftId);
        vm.prank(organizer);
        tournament.assignNftToPlacement(tid, 0, 1); // NFT index 0 → 1° posto

        uint16[] memory split = new uint16[](2);
        split[0] = 7000;
        split[1] = 3000;
        vm.prank(organizer);
        tournament.setPrizeSplit(tid, split);

        // Registra e gioca
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
        tournament.submitResults(tid, winners, keccak256("nft-logs"));
        vm.prank(organizer);
        tournament.enableClaims(tid);

        // User1 claima — riceve ETH + NFT
        vm.prank(user1);
        tournament.claimPrize(tid);

        assertEq(nft1.ownerOf(nftId), user1);
    }

    function test_E05_closeTournament_returnsUnclaimedEth() public {
        uint256 tid = _fullCycleArena();

        // Solo user1 claima (70% = 0.7 ETH)
        vm.prank(user1);
        tournament.claimPrize(tid);

        // Avanza oltre la deadline
        vm.warp(block.timestamp + 31 days);

        uint256 allocatedBefore = tournament.treasuryEthAllocated();
        vm.prank(organizer);
        tournament.closeTournament(tid);

        // 0.3 ETH non claimati → tornano disponibili
        uint256 allocatedAfter = tournament.treasuryEthAllocated();
        assertEq(allocatedBefore - allocatedAfter, 0.3 ether);
        assertEq(uint8(tournament.getTournamentStatus(tid)), uint8(SatoshiTournament.TournamentStatus.CLOSED));
    }

    function test_E06_closeTournament_beforeDeadlineReverts() public {
        uint256 tid = _fullCycleArena();

        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.ClaimDeadlineNotReached.selector);
        tournament.closeTournament(tid);
    }

    function test_E07_claimPrize_pausedReverts() public {
        uint256 tid = _fullCycleArena();

        vm.prank(admin);
        tournament.pause();

        vm.prank(user1);
        vm.expectRevert();
        tournament.claimPrize(tid);
    }

    function test_E08_reentrancy_claimPrize() public {
        // Testa che un attacco reentrancy al claim fallisce grazie a nonReentrant
        // Creiamo un contratto malevolo che chiama claimPrize nel fallback
        ReentrantAttacker attackContract = new ReentrantAttacker(tournament);

        vm.deal(organizer, 10 ether);
        vm.prank(organizer);
        tournament.depositToTreasury{value: 5 ether}();

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.allocateEthPrize(tid, 2 ether);
        uint16[] memory split = new uint16[](2);
        split[0] = 7000;
        split[1] = 3000;
        vm.prank(organizer);
        tournament.setPrizeSplit(tid, split);

        vm.prank(organizer);
        tournament.openRegistration(tid);

        // Registra l'attacker e user2
        vm.prank(address(attackContract));
        tournament.register(tid);
        vm.prank(user2);
        tournament.register(tid);

        vm.prank(organizer);
        tournament.startTournament(tid);

        address[] memory winners = new address[](2);
        winners[0] = address(attackContract);
        winners[1] = user2;
        vm.prank(arbiter);
        tournament.submitResults(tid, winners, keccak256("reentrancy-test"));
        vm.prank(organizer);
        tournament.enableClaims(tid);

        // L'attacker prova la reentrancy — deve fallire
        attackContract.setTournamentId(tid);
        vm.expectRevert(); // ReentrancyGuard blocca
        attackContract.attack();
    }

    // =====================================================================
    //  SECTION F: STRESS TEST — MOLTI UTENTI (6 test)
    // =====================================================================

    function test_F01_stress_100PlayersRegister() public {
        uint256 tid = _createArenaWithPlayers(100);
        (,,,,, uint32 registeredCount,,,,,,,,,,,) = tournament.tournaments(tid);
        assertEq(registeredCount, 100);
    }

    function test_F02_stress_256PlayersRegister() public {
        uint256 tid = _createArenaWithPlayers(256);
        (,,,,, uint32 registeredCount,,,,,,,,,,,) = tournament.tournaments(tid);
        assertEq(registeredCount, 256);
    }

    function test_F03_stress_multipleTournamentsConcurrent() public {
        vm.deal(organizer, 100 ether);
        vm.prank(organizer);
        tournament.depositToTreasury{value: 50 ether}();

        // Crea 20 tornei simultanei
        uint256[] memory tids = new uint256[](20);
        for (uint256 i; i < 20; i++) {
            vm.prank(organizer);
            tids[i] = tournament.createTournament(_arenaConfig());
            vm.prank(organizer);
            tournament.allocateEthPrize(tids[i], 1 ether);
        }

        assertEq(tournament.nextTournamentId(), 20);
        assertEq(tournament.treasuryEthAllocated(), 20 ether);
        assertEq(tournament.treasuryAvailableEth(), 30 ether);
    }

    function test_F04_stress_submitResults_manyPlacements() public {
        uint256 count = 32; // 32 posizioni premiate
        uint256 tid = _createArenaWithPlayers(count);

        vm.prank(organizer);
        tournament.startTournament(tid);

        // Submit 32 piazzamenti
        address[] memory winners = new address[](count);
        for (uint256 i; i < count; i++) {
            winners[i] = makeAddr(string(abi.encodePacked("player", vm.toString(i))));
        }
        vm.prank(arbiter);
        tournament.submitResults(tid, winners, keccak256("stress-results"));

        // uint8 cast safe: count bounded by MAX_PRIZE_SPLIT_ENTRIES (32)
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(tournament.placementCount(tid), uint8(count));
    }

    function test_F05_stress_multipleNftPrizes() public {
        // Deposita 10 NFT da 2 contratti diversi
        uint256[] memory nftIds1 = new uint256[](5);
        uint256[] memory nftIds2 = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            nftIds1[i] = nft1.mintTo(organizer);
            vm.prank(organizer);
            nft1.approve(address(tournament), nftIds1[i]);
            vm.prank(organizer);
            tournament.depositNFTToTreasury(address(nft1), nftIds1[i]);

            nftIds2[i] = nft2.mintTo(organizer);
            vm.prank(organizer);
            nft2.approve(address(tournament), nftIds2[i]);
            vm.prank(organizer);
            tournament.depositNFTToTreasury(address(nft2), nftIds2[i]);
        }
        assertEq(tournament.treasuryNftCount(), 10);

        // Alloca tutti a un torneo
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        for (uint256 i; i < 5; i++) {
            vm.prank(organizer);
            tournament.allocateNftPrize(tid, address(nft1), nftIds1[i]);
            vm.prank(organizer);
            tournament.allocateNftPrize(tid, address(nft2), nftIds2[i]);
        }

        SatoshiTournament.NftPrize[] memory prizes = tournament.getTournamentNftPrizes(tid);
        assertEq(prizes.length, 10);
        assertEq(tournament.treasuryNftCount(), 0); // tutti allocati
    }

    function test_F06_stress_conquista_20PlayersLocking() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());
        vm.prank(organizer);
        tournament.openRegistration(tid);

        // 20 giocatori, ognuno locka 10 carte = 200 carte totali
        for (uint256 i; i < 20; i++) {
            address player = makeAddr(string(abi.encodePacked("lockPlayer", vm.toString(i))));
            uint256[] memory ids = new uint256[](10);
            for (uint256 j; j < 10; j++) {
                ids[j] = bestiary.mintTo(player);
            }
            vm.prank(player);
            tournament.registerWithLock(tid, ids);
        }

        (,,,,, uint32 registeredCount,,,,,,,,,,,) = tournament.tournaments(tid);
        assertEq(registeredCount, 20);
        assertEq(tournament.getLockPlayersCount(tid), 20);
    }

    // =====================================================================
    //  SECTION G: EDGE CASES (6 test)
    // =====================================================================

    function test_G01_constructorRejects_zeroAdmin() public {
        vm.expectRevert(SatoshiTournament.ZeroAddress.selector);
        new SatoshiTournament(address(0), organizer);
    }

    function test_G02_constructorRejects_zeroOrganizer() public {
        vm.expectRevert(SatoshiTournament.ZeroAddress.selector);
        new SatoshiTournament(admin, address(0));
    }

    function test_G03_submitResults_alreadySubmittedReverts() public {
        uint256 tid = _createArenaWithPlayers(2);
        vm.prank(organizer);
        tournament.startTournament(tid);

        address[] memory winners = new address[](2);
        winners[0] = makeAddr("player0");
        winners[1] = makeAddr("player1");
        vm.prank(arbiter);
        tournament.submitResults(tid, winners, keccak256("first"));

        // Dopo submitResults lo status è FINALIZED, quindi il secondo tentativo
        // fallisce su _requireStatus(IN_PROGRESS) prima di raggiungere il check matchLogsRoot
        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(
                SatoshiTournament.WrongStatus.selector,
                SatoshiTournament.TournamentStatus.IN_PROGRESS,
                SatoshiTournament.TournamentStatus.FINALIZED
            )
        );
        tournament.submitResults(tid, winners, keccak256("second"));
    }

    function test_G04_submitResults_unregisteredWinnerReverts() public {
        uint256 tid = _createArenaWithPlayers(2);
        vm.prank(organizer);
        tournament.startTournament(tid);

        address[] memory winners = new address[](2);
        winners[0] = makeAddr("player0");
        winners[1] = makeAddr("unregistered"); // non registrato!
        vm.prank(arbiter);
        vm.expectRevert(SatoshiTournament.WinnerNotRegistered.selector);
        tournament.submitResults(tid, winners, keccak256("bad"));
    }

    function test_G05_emergencyWithdraw_thenSelfUnlock() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());
        vm.prank(organizer);
        tournament.openRegistration(tid);

        uint256[] memory ids = _mint10Cards(user1);
        vm.prank(user1);
        tournament.registerWithLock(tid, ids);

        // Verifica locked
        for (uint256 i; i < ids.length; i++) {
            assertTrue(bestiary.tokenLocked(ids[i]));
        }

        // Emergency withdraw — NON unlock più (H-01 fix)
        vm.prank(admin);
        tournament.emergencyWithdraw(tid, admin);

        // Carte ancora locked dopo emergency
        for (uint256 i; i < ids.length; i++) {
            assertTrue(bestiary.tokenLocked(ids[i]));
        }

        // Player usa selfUnlock dopo emergency
        vm.prank(user1);
        tournament.selfUnlock(tid);

        // Ora sbloccate
        for (uint256 i; i < ids.length; i++) {
            assertFalse(bestiary.tokenLocked(ids[i]));
        }
    }

    function test_G06_cancelTournament_thenSelfUnlock() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());
        vm.prank(organizer);
        tournament.openRegistration(tid);

        uint256[] memory ids = _mint10Cards(user1);
        vm.prank(user1);
        tournament.registerWithLock(tid, ids);

        vm.prank(organizer);
        tournament.cancelTournament(tid);

        // Carte ancora lockate dopo cancel (H-01 fix)
        for (uint256 i; i < ids.length; i++) {
            assertTrue(bestiary.tokenLocked(ids[i]));
        }

        // Player chiama selfUnlock
        vm.prank(user1);
        tournament.selfUnlock(tid);

        // Ora sbloccate
        for (uint256 i; i < ids.length; i++) {
            assertFalse(bestiary.tokenLocked(ids[i]));
        }
    }

    // =====================================================================
    //  SECTION H: AUDIT FIX TESTS (12 test)
    // =====================================================================

    // --- H-01: selfUnlock + unlockBatch ---

    function test_H01_selfUnlock_duringInProgressReverts() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());
        vm.prank(organizer);
        tournament.openRegistration(tid);

        uint256[] memory ids1 = _mint10Cards(user1);
        vm.prank(user1);
        tournament.registerWithLock(tid, ids1);
        uint256[] memory ids2 = _mint10Cards(user2);
        vm.prank(user2);
        tournament.registerWithLock(tid, ids2);

        vm.prank(organizer);
        tournament.startTournament(tid);

        // Non puoi selfUnlock durante IN_PROGRESS
        vm.prank(user1);
        vm.expectRevert(SatoshiTournament.TournamentStillInProgress.selector);
        tournament.selfUnlock(tid);
    }

    function test_H02_unlockBatch_success() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());
        vm.prank(organizer);
        tournament.openRegistration(tid);

        // 3 player lockano 10 carte ciascuno
        address p0 = makeAddr("bp0");
        address p1 = makeAddr("bp1");
        address p2 = makeAddr("bp2");
        uint256[] memory ids0 = _mint10Cards(p0);
        uint256[] memory ids1 = _mint10Cards(p1);
        uint256[] memory ids2 = _mint10Cards(p2);
        vm.prank(p0);
        tournament.registerWithLock(tid, ids0);
        vm.prank(p1);
        tournament.registerWithLock(tid, ids1);
        vm.prank(p2);
        tournament.registerWithLock(tid, ids2);

        // Cancella torneo
        vm.prank(organizer);
        tournament.cancelTournament(tid);

        // Organizer fa batch unlock dei primi 2
        vm.prank(organizer);
        tournament.unlockBatch(tid, 0, 2);

        // p0 e p1 sbloccate
        for (uint256 i; i < 10; i++) {
            assertFalse(bestiary.tokenLocked(ids0[i]));
            assertFalse(bestiary.tokenLocked(ids1[i]));
            assertTrue(bestiary.tokenLocked(ids2[i])); // p2 ancora locked
        }

        // p2 selfUnlock
        vm.prank(p2);
        tournament.selfUnlock(tid);
        for (uint256 i; i < 10; i++) {
            assertFalse(bestiary.tokenLocked(ids2[i]));
        }
    }

    function test_H03_selfUnlock_noTokensReverts() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_conquistaConfig());
        vm.prank(organizer);
        tournament.cancelTournament(tid); // CLOSED

        vm.prank(user1);
        vm.expectRevert(SatoshiTournament.NoLockedTokens.selector);
        tournament.selfUnlock(tid);
    }

    // --- H-02: withdrawNFT protezione ---

    function test_H04_withdrawNFT_allocatedReverts() public {
        uint256 nftId = nft1.mintTo(organizer);
        vm.prank(organizer);
        nft1.approve(address(tournament), nftId);
        vm.prank(organizer);
        tournament.depositNFTToTreasury(address(nft1), nftId);

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.allocateNftPrize(tid, address(nft1), nftId);

        // treasuryNfts è false (rimosso dalla treasury), ma nftAllocatedToTournament != 0
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.NftNotInTreasury.selector);
        tournament.withdrawNFT(address(nft1), nftId);
    }

    function test_H05_deallocatePrize_clearsNftTracking() public {
        uint256 nftId = nft1.mintTo(organizer);
        vm.prank(organizer);
        nft1.approve(address(tournament), nftId);
        vm.prank(organizer);
        tournament.depositNFTToTreasury(address(nft1), nftId);

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.allocateNftPrize(tid, address(nft1), nftId);

        // deallocate → torna in treasury + H-02 tracking azzerato
        vm.prank(organizer);
        tournament.deallocatePrize(tid);

        assertEq(tournament.nftAllocatedToTournament(address(nft1), nftId), 0);
        assertTrue(tournament.treasuryNfts(address(nft1), nftId));

        // Ora withdraw funziona
        vm.prank(organizer);
        tournament.withdrawNFT(address(nft1), nftId);
        assertEq(nft1.ownerOf(nftId), organizer);
    }

    // --- M-01: unicità winners ---

    function test_H06_submitResults_duplicateWinnerReverts() public {
        uint256 tid = _createArenaWithPlayers(3);
        vm.prank(organizer);
        tournament.startTournament(tid);

        address p0 = makeAddr("player0");
        address[] memory winners = new address[](3);
        winners[0] = p0;
        winners[1] = makeAddr("player1");
        winners[2] = p0; // duplicato!

        vm.prank(arbiter);
        vm.expectRevert(SatoshiTournament.DuplicateWinner.selector);
        tournament.submitResults(tid, winners, keccak256("dup"));
    }

    // --- L-01: validazione nome ---

    function test_H07_createTournament_emptyNameReverts() public {
        SatoshiTournament.TournamentConfig memory cfg = _arenaConfig();
        cfg.name = "";
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.InvalidNameLength.selector);
        tournament.createTournament(cfg);
    }

    function test_H08_createTournament_tooLongNameReverts() public {
        SatoshiTournament.TournamentConfig memory cfg = _arenaConfig();
        // 129 bytes → troppo lungo
        bytes memory longName = new bytes(129);
        for (uint256 i; i < 129; i++) longName[i] = "A";
        cfg.name = string(longName);
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.InvalidNameLength.selector);
        tournament.createTournament(cfg);
    }

    // --- L-04: invite zero-address ---

    function test_H09_invitePlayer_zeroAddressReverts() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_sigilloConfig());
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.ZeroAddress.selector);
        tournament.invitePlayer(tid, address(0));
    }

    function test_H10_invitePlayers_zeroAddressReverts() public {
        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_sigilloConfig());
        address[] memory players = new address[](2);
        players[0] = user1;
        players[1] = address(0); // secondo è zero
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.ZeroAddress.selector);
        tournament.invitePlayers(tid, players);
    }

    // --- L-03: event NftAssignedToPlacement ---

    function test_H11_assignNftToPlacement_emitsEvent() public {
        uint256 nftId = nft1.mintTo(organizer);
        vm.prank(organizer);
        nft1.approve(address(tournament), nftId);
        vm.prank(organizer);
        tournament.depositNFTToTreasury(address(nft1), nftId);

        vm.prank(organizer);
        uint256 tid = tournament.createTournament(_arenaConfig());
        vm.prank(organizer);
        tournament.allocateNftPrize(tid, address(nft1), nftId);

        vm.prank(organizer);
        vm.expectEmit(true, false, false, true);
        emit SatoshiTournament.NftAssignedToPlacement(tid, 0, 1);
        tournament.assignNftToPlacement(tid, 0, 1);
    }

    // --- I-01: custom errors ---

    function test_H12_cancelTournament_wrongStatusReverts() public {
        uint256 tid = _fullCycleArena();
        // Torneo è CLAIMABLE, non cancellabile
        vm.prank(organizer);
        vm.expectRevert(SatoshiTournament.CannotCancelInStatus.selector);
        tournament.cancelTournament(tid);
    }
}

// =====================================================================
//  ATTACKER CONTRACT (per test reentrancy)
// =====================================================================

contract ReentrantAttacker {
    SatoshiTournament public target;
    uint256 public tournamentId;
    bool public attacking;

    constructor(SatoshiTournament _target) {
        target = _target;
    }

    function setTournamentId(uint256 _tid) external {
        tournamentId = _tid;
    }

    function attack() external {
        attacking = true;
        target.claimPrize(tournamentId);
    }

    receive() external payable {
        if (attacking) {
            attacking = false;
            // Tenta reentrancy
            target.claimPrize(tournamentId);
        }
    }
}
