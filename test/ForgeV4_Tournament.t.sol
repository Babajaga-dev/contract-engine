// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/TestableBestiaryV4.sol";
import "./mocks/MockVRFCoordinator.sol";
import "../contracts/SatoshiForgeV4.sol";
import "../contracts/SatoshiBestiaryV4.sol";

/**
 * @title ForgeV4_Tournament.t.sol
 * @notice Test suite per Fase F0: Token lock, setTournamentContract, setVRFTuning on ForgeV4.
 */
contract ForgeV4TournamentTest is Test {
    TestableBestiaryV4 bestiary;
    SatoshiForgeV4 forge;
    MockVRFCoordinatorV2Plus vrfCoord;

    address owner;
    address alice;
    address tournamentAddr;

    // Forge start IDs (V4 parametric)
    uint256 constant RARE_FORGED_START = 21001;
    uint256 constant EPIC_FORGED_START = 21253;
    uint256 constant LEGENDARY_FORGED_START = 21463;
    uint256 constant MYTHIC_FORGED_START = 21568;
    uint256 constant MYTHIC_SHARD_START = 21589;
    uint256 constant APEX_START = 21598;
    uint256 constant RELIQUIA_START = 21601;

    // Bestiary tier boundaries (Genesis)
    uint256 constant COMMON_START = 7351;
    uint256 constant COMMON_END = 21000;
    uint256 constant RARE_START = 3151;
    uint256 constant RARE_END = 7350;
    uint256 constant EPIC_START = 1051;
    uint256 constant EPIC_END = 3150;
    uint256 constant LEGENDARY_START = 22;
    uint256 constant LEGENDARY_END = 1050;

    receive() external payable {}

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        tournamentAddr = makeAddr("tournament");

        vrfCoord = new MockVRFCoordinatorV2Plus();

        // Deploy Bestiary
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

        // Deploy Forge
        forge = new SatoshiForgeV4(
            "Satoshi Genesis Forged",
            "SFORGE",
            address(bestiary),
            SatoshiForgeV4.ForgeParams({
                maxRareForged: 252,
                maxEpicForged: 210,
                maxLegendaryForged: 105,
                maxMythicForged: 21,
                maxReliquia: 21,
                maxMythicShard: 9,
                maxApex: 3,
                mythicForgedStartId: MYTHIC_FORGED_START,
                legendaryForgedStartId: LEGENDARY_FORGED_START,
                epicForgedStartId: EPIC_FORGED_START,
                rareForgedStartId: RARE_FORGED_START,
                mythicShardStartId: MYTHIC_SHARD_START,
                apexStartId: APEX_START,
                reliquiaStartId: RELIQUIA_START,
                rareForgedSpecies: 13,
                epicForgedSpecies: 10,
                legendaryForgedSpecies: 7,
                mythicForgedSpecies: 2,
                bestiaryCommonStart: COMMON_START,
                bestiaryCommonEnd: COMMON_END,
                bestiaryRareStart: RARE_START,
                bestiaryRareEnd: RARE_END,
                bestiaryEpicStart: EPIC_START,
                bestiaryEpicEnd: EPIC_END,
                bestiaryLegendaryStart: LEGENDARY_START,
                bestiaryLegendaryEnd: LEGENDARY_END
            }),
            SatoshiForgeV4.VRFParams({
                subscriptionId: 1,
                vrfCoordinator: address(vrfCoord),
                keyHash: bytes32(uint256(1)),
                notRevealedURI: "ipfs://hidden/"
            }),
            500
        );

        // Cross-link contracts
        bestiary.setForgeContract(address(forge));

        // Activate all forge steps
        for (uint256 i = 0; i < 7; i++) {
            forge.setForgeStepActive(i, true);
        }

        // Mint Common tokens to alice for forge testing
        for (uint256 i = 0; i < 20; i++) {
            bestiary.testMintDirectTo(alice, COMMON_START + i); // 7351-7370
        }

        vm.deal(alice, 100 ether);
    }

    // =====================================================================
    //  SECTION A: TOURNAMENT LOCK ON FORGE (8 test)
    // =====================================================================

    /// @dev Helper: forge 20 commons → 1 RareForged, returns the minted token ID
    function _forgeOneRare() internal returns (uint256) {
        uint256[] memory ids = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            ids[i] = COMMON_START + i;
        }
        vm.prank(alice);
        forge.forgeRare{value: 0.01 ether}(ids);
        // The first RareForged minted should be at rareForgedStartId
        return RARE_FORGED_START;
    }

    function test_setTournamentContract_owner_success() public {
        forge.setTournamentContract(tournamentAddr);
        assertEq(forge.tournamentContract(), tournamentAddr);
    }

    function test_setTournamentContract_zeroAddress_reverts() public {
        vm.expectRevert(SatoshiForgeV4.InvalidTournamentAddress.selector);
        forge.setTournamentContract(address(0));
    }

    function test_setTournamentContract_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        forge.setTournamentContract(tournamentAddr);
    }

    function test_lockTokens_byTournament_success() public {
        uint256 forgedId = _forgeOneRare();
        forge.setTournamentContract(tournamentAddr);

        uint256[] memory ids = new uint256[](1);
        ids[0] = forgedId;

        vm.prank(tournamentAddr);
        forge.lockTokens(ids);

        assertTrue(forge.tokenLocked(forgedId));
    }

    function test_lockTokens_notTournament_reverts() public {
        uint256 forgedId = _forgeOneRare();
        forge.setTournamentContract(tournamentAddr);

        uint256[] memory ids = new uint256[](1);
        ids[0] = forgedId;

        vm.prank(alice);
        vm.expectRevert(SatoshiForgeV4.NotTournamentContract.selector);
        forge.lockTokens(ids);
    }

    function test_lockTokens_emptyArray_reverts() public {
        forge.setTournamentContract(tournamentAddr);

        uint256[] memory ids = new uint256[](0);

        vm.prank(tournamentAddr);
        vm.expectRevert(SatoshiForgeV4.NoTokensProvided.selector);
        forge.lockTokens(ids);
    }

    function test_transfer_lockedForgedToken_reverts() public {
        uint256 forgedId = _forgeOneRare();
        forge.setTournamentContract(tournamentAddr);

        uint256[] memory ids = new uint256[](1);
        ids[0] = forgedId;

        vm.prank(tournamentAddr);
        forge.lockTokens(ids);

        // Try to transfer locked forged token
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SatoshiForgeV4.TokenLocked.selector, forgedId));
        forge.transferFrom(alice, owner, forgedId);
    }

    function test_unlockTokens_thenTransfer_success() public {
        uint256 forgedId = _forgeOneRare();
        forge.setTournamentContract(tournamentAddr);

        uint256[] memory ids = new uint256[](1);
        ids[0] = forgedId;

        vm.prank(tournamentAddr);
        forge.lockTokens(ids);

        // Unlock
        vm.prank(tournamentAddr);
        forge.unlockTokens(ids);

        assertFalse(forge.tokenLocked(forgedId));

        // Now transfer works
        address bob = makeAddr("bob");
        vm.prank(alice);
        forge.transferFrom(alice, bob, forgedId);
        assertEq(forge.ownerOf(forgedId), bob);
    }

    // =====================================================================
    //  SECTION B: VRF TUNING CONSOLIDATION (3 test)
    // =====================================================================

    function test_setVRFTuning_owner_success() public {
        forge.setVRFTuning(500_000, 5, false);
        assertEq(forge.shardCallbackGasLimit(), 500_000);
        assertEq(forge.shardRequestConfirmations(), 5);
        assertEq(forge.vrfNativePayment(), false);
    }

    function test_setVRFTuning_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        forge.setVRFTuning(500_000, 5, false);
    }

    function test_setVRFTuning_defaultValues() public view {
        assertEq(forge.shardCallbackGasLimit(), 3_000_000);
        assertEq(forge.shardRequestConfirmations(), 3);
        assertEq(forge.vrfNativePayment(), true);
    }

    // =====================================================================
    //  SECTION C: _inRange CONSOLIDATION (2 test — implicit through forge)
    // =====================================================================

    function test_forgeRare_validCommons_success() public {
        // This implicitly tests _inRange for common range check
        uint256 forgedId = _forgeOneRare();
        assertEq(forge.ownerOf(forgedId), alice);
    }

    function test_forgeRare_invalidToken_reverts() public {
        // Token outside common range should revert
        uint256[] memory ids = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            ids[i] = COMMON_START + i;
        }
        // Replace one with a non-common token
        ids[19] = RARE_START; // This is a Rare Bestiary token, not Common
        bestiary.testMintDirectTo(alice, RARE_START);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SatoshiForgeV4.InvalidTokenTier.selector, RARE_START));
        forge.forgeRare{value: 0.01 ether}(ids);
    }

    // =====================================================================
    //  SECTION D: getAvailableShardIds REMOVED (1 test)
    // =====================================================================

    function test_availableShardSlots_stillWorks() public view {
        // getAvailableShardIds() was removed, but availableShardSlots() should still work
        assertEq(forge.availableShardSlots(), 9); // maxMythicShard = 9
    }
}
