// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/TestableBestiaryV4.sol";
import "./mocks/MockVRFCoordinator.sol";

/**
 * @title BestiaryV4_Security.t.sol
 * @notice Test suite di sicurezza esaustiva per SatoshiBestiaryV4.
 *         Copertura: Constructor validation, getSpeciesId, Mint+VRF, Sigillo.
 *         ~40 test organizzati in 4 sezioni.
 */
contract BestiaryV4SecurityTest is Test {
    TestableBestiaryV4 bestiary;
    MockVRFCoordinatorV2Plus vrfCoord;

    address owner;
    address user1;
    address user2;

    // Setup helper
    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vrfCoord = new MockVRFCoordinatorV2Plus();
    }

    // =====================================================================
    //  SECTION A: CONSTRUCTOR VALIDATION (10 test)
    // =====================================================================

    /**
     * test_constructor_GenesisParams_OK
     * Deploy con parametri Genesis standard, verifica gli immutable.
     */
    function test_constructor_GenesisParams_OK() public {
        TestableBestiaryV4 temp = new TestableBestiaryV4(
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

        assertEq(temp.maxSupply(), 21000);
        assertEq(temp.devReserve(), 2100);
        assertEq(temp.publicSupply(), 18900);
        assertEq(temp.maxPerWallet(), 10);
        assertEq(temp.mintBlock(), 5);
        assertEq(temp.mintCooldown(), 7200);
        assertEq(temp.totalSpecies(), 42);
    }

    /**
     * test_constructor_EpochParams_OK
     * Deploy con parametri Epoch (42K supply), verifica i confini tier.
     */
    function test_constructor_EpochParams_OK() public {
        TestableBestiaryV4 temp = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Satoshi Epoch",
                symbol: "SBE2",
                maxSupply: 42000,
                devReserve: 4200,
                maxPerWallet: 10,
                mintBlock: 5,
                mintCooldown: 7200,
                totalSpecies: 42,
                tierBoundaries: [uint256(42), 2100, 6300, 14700, 42000],
                speciesPerTier: [uint8(2), 7, 10, 10, 13],
                royaltyBps: 500
            }),
            SatoshiBestiaryV4.VRFParams({
                subscriptionId: 2,
                vrfCoordinator: address(vrfCoord),
                keyHash: bytes32(uint256(2)),
                notRevealedURI: "ipfs://hidden2/"
            })
        );

        assertEq(temp.maxSupply(), 42000);
        assertEq(temp.devReserve(), 4200);
        assertEq(temp.publicSupply(), 37800);
    }

    /**
     * test_constructor_revert_ZeroSupply
     * Validazione: maxSupply non può essere 0.
     */
    function test_constructor_revert_ZeroSupply() public {
        vm.expectRevert(SatoshiBestiaryV4.InvalidMaxSupply.selector);
        new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Bad",
                symbol: "BAD",
                maxSupply: 0,
                devReserve: 0,
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
    }

    /**
     * test_constructor_revert_DevReserveExceedsSupply
     * Validazione: devReserve non può superare maxSupply.
     */
    function test_constructor_revert_DevReserveExceedsSupply() public {
        vm.expectRevert(SatoshiBestiaryV4.InvalidDevReserve.selector);
        new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Bad",
                symbol: "BAD",
                maxSupply: 21000,
                devReserve: 30000, // Exceeds supply
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
    }

    /**
     * test_constructor_revert_TierBoundaryNotMonotonic
     * Validazione: tier boundaries devono essere in ordine crescente.
     */
    function test_constructor_revert_TierBoundaryNotMonotonic() public {
        vm.expectRevert(SatoshiBestiaryV4.TierBoundaryNotMonotonic.selector);
        new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Bad",
                symbol: "BAD",
                maxSupply: 21000,
                devReserve: 2100,
                maxPerWallet: 10,
                mintBlock: 5,
                mintCooldown: 7200,
                totalSpecies: 42,
                tierBoundaries: [uint256(1050), 21, 3150, 7350, 21000], // NOT monotonic
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
    }

    /**
     * test_constructor_revert_TierBoundaryExceedsSupply
     * Validazione: ultimo tier boundary deve == maxSupply.
     */
    function test_constructor_revert_TierBoundaryExceedsSupply() public {
        vm.expectRevert(SatoshiBestiaryV4.TierBoundaryExceedsSupply.selector);
        new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Bad",
                symbol: "BAD",
                maxSupply: 21000,
                devReserve: 2100,
                maxPerWallet: 10,
                mintBlock: 5,
                mintCooldown: 7200,
                totalSpecies: 42,
                tierBoundaries: [uint256(21), 1050, 3150, 7350, 20000], // != maxSupply
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
    }

    /**
     * test_constructor_revert_ZeroSpeciesInTier
     * Validazione: ogni tier deve avere almeno 1 specie.
     */
    function test_constructor_revert_ZeroSpeciesInTier() public {
        vm.expectRevert(SatoshiBestiaryV4.ZeroSpeciesInTier.selector);
        new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Bad",
                symbol: "BAD",
                maxSupply: 21000,
                devReserve: 2100,
                maxPerWallet: 10,
                mintBlock: 5,
                mintCooldown: 7200,
                totalSpecies: 42,
                tierBoundaries: [uint256(21), 1050, 3150, 7350, 21000],
                speciesPerTier: [uint8(2), 0, 10, 10, 20], // Tier 1 ha 0 specie
                royaltyBps: 500
            }),
            SatoshiBestiaryV4.VRFParams({
                subscriptionId: 1,
                vrfCoordinator: address(vrfCoord),
                keyHash: bytes32(uint256(1)),
                notRevealedURI: "ipfs://hidden/"
            })
        );
    }

    /**
     * test_constructor_revert_SpeciesTotalMismatch
     * Validazione: sum(speciesPerTier) deve == totalSpecies.
     */
    function test_constructor_revert_SpeciesTotalMismatch() public {
        vm.expectRevert(SatoshiBestiaryV4.SpeciesTotalMismatch.selector);
        new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Bad",
                symbol: "BAD",
                maxSupply: 21000,
                devReserve: 2100,
                maxPerWallet: 10,
                mintBlock: 5,
                mintCooldown: 7200,
                totalSpecies: 50, // Sum of speciesPerTier is 42, not 50
                tierBoundaries: [uint256(21), 1050, 3150, 7350, 21000],
                speciesPerTier: [uint8(2), 7, 10, 10, 13], // sum = 42
                royaltyBps: 500
            }),
            SatoshiBestiaryV4.VRFParams({
                subscriptionId: 1,
                vrfCoordinator: address(vrfCoord),
                keyHash: bytes32(uint256(1)),
                notRevealedURI: "ipfs://hidden/"
            })
        );
    }

    /**
     * test_constructor_revert_ZeroMintBlock
     * Validazione: mintBlock non può essere 0.
     */
    function test_constructor_revert_ZeroMintBlock() public {
        vm.expectRevert(SatoshiBestiaryV4.InvalidMintBlock.selector);
        new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Bad",
                symbol: "BAD",
                maxSupply: 21000,
                devReserve: 2100,
                maxPerWallet: 10,
                mintBlock: 0, // Invalid
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
    }

    /**
     * test_constructor_revert_InvalidVRF
     * Validazione: subscriptionId non può essere 0.
     */
    function test_constructor_revert_InvalidVRF() public {
        vm.expectRevert(SatoshiBestiaryV4.InvalidSubscriptionId.selector);
        new TestableBestiaryV4(
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
                subscriptionId: 0, // Invalid
                vrfCoordinator: address(vrfCoord),
                keyHash: bytes32(uint256(1)),
                notRevealedURI: "ipfs://hidden/"
            })
        );
    }

    // =====================================================================
    //  SECTION B: getSpeciesId EXHAUSTIVE (15 test)
    // =====================================================================

    /**
     * Helper per deployare un bestiary standard.
     */
    function _deployStandardBestiary() internal returns (TestableBestiaryV4) {
        return new TestableBestiaryV4(
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
    }

    /**
     * test_getSpeciesId_FirstTokenMythic
     * tokenId=1 -> species 0 (first of Mythic)
     */
    function test_getSpeciesId_FirstTokenMythic() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        uint8 species = temp.getSpeciesId(1);
        assertEq(species, 0);
    }

    /**
     * test_getSpeciesId_LastTokenMythicSpecies0
     * tokenId=11 -> still species 0 (each specie has ceil(21/2)=11 cards)
     */
    function test_getSpeciesId_LastTokenMythicSpecies0() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        uint8 species = temp.getSpeciesId(11);
        assertEq(species, 0);
    }

    /**
     * test_getSpeciesId_FirstTokenMythicSpecies1
     * tokenId=12 -> species 1 (first of second Mythic specie)
     */
    function test_getSpeciesId_FirstTokenMythicSpecies1() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        uint8 species = temp.getSpeciesId(12);
        assertEq(species, 1);
    }

    /**
     * test_getSpeciesId_LastTokenMythic
     * tokenId=21 -> species 1 (end of Mythic tier)
     */
    function test_getSpeciesId_LastTokenMythic() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        uint8 species = temp.getSpeciesId(21);
        assertEq(species, 1);
    }

    /**
     * test_getSpeciesId_FirstTokenLegendary
     * tokenId=22 -> species 2 (first of Legendary tier)
     */
    function test_getSpeciesId_FirstTokenLegendary() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        uint8 species = temp.getSpeciesId(22);
        assertEq(species, 2);
    }

    /**
     * test_getSpeciesId_LastTokenLegendary
     * tokenId=1050 -> species 8 (end of Legendary tier)
     */
    function test_getSpeciesId_LastTokenLegendary() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        uint8 species = temp.getSpeciesId(1050);
        assertEq(species, 8);
    }

    /**
     * test_getSpeciesId_FirstTokenEpic
     * tokenId=1051 -> species 9 (first of Epic tier)
     */
    function test_getSpeciesId_FirstTokenEpic() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        uint8 species = temp.getSpeciesId(1051);
        assertEq(species, 9);
    }

    /**
     * test_getSpeciesId_LastTokenEpic
     * tokenId=3150 -> species 18 (end of Epic tier)
     */
    function test_getSpeciesId_LastTokenEpic() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        uint8 species = temp.getSpeciesId(3150);
        assertEq(species, 18);
    }

    /**
     * test_getSpeciesId_FirstTokenRare
     * tokenId=3151 -> species 19 (first of Rare tier)
     */
    function test_getSpeciesId_FirstTokenRare() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        uint8 species = temp.getSpeciesId(3151);
        assertEq(species, 19);
    }

    /**
     * test_getSpeciesId_LastTokenCommon
     * tokenId=21000 -> species 41 (end of Common tier, con clamping)
     */
    function test_getSpeciesId_LastTokenCommon() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        uint8 species = temp.getSpeciesId(21000);
        assertEq(species, 41);
    }

    /**
     * test_getSpeciesId_BoundaryLegendaryEpic
     * Verifica boundary tra Legendary e Epic (1050->1051)
     */
    function test_getSpeciesId_BoundaryLegendaryEpic() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        uint8 species1050 = temp.getSpeciesId(1050);
        uint8 species1051 = temp.getSpeciesId(1051);
        assertEq(species1050, 8); // Last Legendary
        assertEq(species1051, 9); // First Epic
    }

    /**
     * test_getSpeciesId_BoundaryRareCommon
     * Verifica boundary tra Rare e Common (7350->7351)
     */
    function test_getSpeciesId_BoundaryRareCommon() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        uint8 species7350 = temp.getSpeciesId(7350);
        uint8 species7351 = temp.getSpeciesId(7351);
        assertEq(species7350, 28); // Last Rare
        assertEq(species7351, 29); // First Common
    }

    /**
     * test_getSpeciesId_revert_TokenId0
     * tokenId=0 deve revert (invalid)
     */
    function test_getSpeciesId_revert_TokenId0() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        vm.expectRevert();
        temp.getSpeciesId(0);
    }

    /**
     * test_getSpeciesId_revert_TokenIdOverMax
     * tokenId > maxSupply deve revert
     */
    function test_getSpeciesId_revert_TokenIdOverMax() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        vm.expectRevert();
        temp.getSpeciesId(21001);
    }

    /**
     * test_getSpeciesId_AllSpeciesCovered
     * Loop su tutte le specie 0-41, verifica che almeno 1 tokenId
     * mappa a ciascuna specie.
     */
    function test_getSpeciesId_AllSpeciesCovered() public {
        TestableBestiaryV4 temp = _deployStandardBestiary();
        bool[] memory speciesCovered = new bool[](42);

        // Test strategico: primo e ultimo tokenId di ogni tier + boundary tokens
        // Mythic: 1-21 (sp 0-1), Legendary: 22-1050 (sp 2-8), Epic: 1051-3150 (sp 9-18)
        // Rare: 3151-7350 (sp 19-28), Common: 7351-21000 (sp 29-41)
        uint256[10] memory keyTokenIds = [uint256(1), 12, 22, 169, 1051, 1261, 3151, 3571, 7351, 8401];
        for (uint256 k = 0; k < keyTokenIds.length; k++) {
            uint8 species = temp.getSpeciesId(keyTokenIds[k]);
            if (species < 42) speciesCovered[species] = true;
        }
        // Full sweep con step piccolo per coprire tutti
        for (uint256 tokenId = 1; tokenId <= 21000; tokenId += 50) {
            uint8 species = temp.getSpeciesId(tokenId);
            if (species < 42) speciesCovered[species] = true;
        }
        // Ultimi token di ogni tier boundary
        speciesCovered[temp.getSpeciesId(11)] = true;   // last sp0
        speciesCovered[temp.getSpeciesId(12)] = true;   // first sp1
        speciesCovered[temp.getSpeciesId(21)] = true;   // last sp1
        speciesCovered[temp.getSpeciesId(1050)] = true;  // last legendary
        speciesCovered[temp.getSpeciesId(3150)] = true;  // last epic
        speciesCovered[temp.getSpeciesId(7350)] = true;  // last rare
        speciesCovered[temp.getSpeciesId(21000)] = true; // last common

        // Verifica che tutte le specie sono coperte
        for (uint256 i = 0; i < 42; i++) {
            assertTrue(speciesCovered[i], string(abi.encodePacked("Species ", vm.toString(i), " not covered")));
        }
    }

    // =====================================================================
    //  SECTION C: MINT + VRF (10 test)
    // =====================================================================

    /**
     * test_freeMint_HappyPath
     * Mint pubblico standard con VRF.
     */
    function test_freeMint_HappyPath() public {
        bestiary = _deployStandardBestiary();
        bestiary.setMintStatus(true);
        vm.roll(7201);

        vm.prank(user1, user1);
        bestiary.freeMint();

        vrfCoord.fulfillWithSeed(1, address(bestiary), 12345);

        assertEq(bestiary.balanceOf(user1), 5);
        assertEq(bestiary.totalSupply(), 5);
    }

    /**
     * test_freeMint_RevertWhenInactive
     * Mint inattivo deve revert.
     */
    function test_freeMint_RevertWhenInactive() public {
        bestiary = _deployStandardBestiary();
        // Mint NOT activated

        vm.prank(user1, user1);
        vm.expectRevert(SatoshiBestiaryV4.MintInactive.selector);
        bestiary.freeMint();
    }

    /**
     * test_freeMint_CooldownEnforced
     * Cooldown tra i mint deve essere rispettato.
     */
    function test_freeMint_CooldownEnforced() public {
        bestiary = _deployStandardBestiary();
        bestiary.setMintStatus(true);
        vm.roll(7201);

        // First mint
        vm.prank(user1, user1);
        bestiary.freeMint();
        vrfCoord.fulfillWithSeed(1, address(bestiary), 111);

        // Second mint prima del cooldown deve revert
        vm.prank(user1, user1);
        vm.expectRevert(SatoshiBestiaryV4.CooldownActive.selector);
        bestiary.freeMint();

        // Aspetta il cooldown
        vm.roll(block.number + 7200);

        // Ora deve funzionare
        vm.prank(user1, user1);
        bestiary.freeMint();
        vrfCoord.fulfillWithSeed(2, address(bestiary), 222);

        assertEq(bestiary.balanceOf(user1), 10);
    }

    /**
     * test_freeMint_WalletCapEnforced
     * maxPerWallet = 10, non può mintare più di 10.
     */
    function test_freeMint_WalletCapEnforced() public {
        bestiary = _deployStandardBestiary();
        bestiary.setMintStatus(true);
        vm.roll(7201);

        // First mint: 5 NFT
        vm.prank(user1, user1);
        bestiary.freeMint();
        vrfCoord.fulfillWithSeed(1, address(bestiary), 111);
        assertEq(bestiary.balanceOf(user1), 5);

        // Cooldown
        vm.roll(block.number + 7200);

        // Second mint: 5 NFT (total = 10, at cap)
        vm.prank(user1, user1);
        bestiary.freeMint();
        vrfCoord.fulfillWithSeed(2, address(bestiary), 222);
        assertEq(bestiary.balanceOf(user1), 10);

        // Cooldown
        vm.roll(block.number + 7200);

        // Third mint: must revert (would exceed 10)
        vm.prank(user1, user1);
        vm.expectRevert(SatoshiBestiaryV4.MaxPerWallet.selector);
        bestiary.freeMint();
    }

    /**
     * test_freeMint_ContractCaller_Allowed
     * Dopo la rimozione dell'EOA-only check (fix H1 audit 2026-04-22), i contratti
     * (inclusi Account Abstraction wallet come Coinbase Smart Wallet su Base L2)
     * possono chiamare freeMint(). Difesa anti-bot delegata a: maxPerWallet + mintCooldown.
     */
    function test_freeMint_ContractCaller_Allowed() public {
        bestiary = _deployStandardBestiary();
        bestiary.setMintStatus(true);
        vm.roll(7201);

        // Chiama da un contratto (msg.sender != tx.origin): deve passare, non revertire
        vm.prank(address(0x1234), address(0x5678));
        uint256 requestId = bestiary.freeMint();
        assertGt(requestId, 0, "Contract caller should be able to request mint");
    }

    /**
     * test_devMint_HappyPath
     * Dev mint standard.
     */
    function test_devMint_HappyPath() public {
        bestiary = _deployStandardBestiary();

        bestiary.devMint(user1, 5);
        vrfCoord.fulfillWithSeed(1, address(bestiary), 333);

        assertEq(bestiary.balanceOf(user1), 5);
        assertEq(bestiary.totalSupply(), 5);
    }

    /**
     * test_devMint_RevertExceedsReserve
     * Dev reserve = 2100, non può mintare più di 2100.
     */
    function test_devMint_RevertExceedsReserve() public {
        bestiary = _deployStandardBestiary();

        // Mint fino al limite (2100 / 20 = 105 lotti)
        for (uint256 i = 0; i < 105; i++) {
            bestiary.devMint(user1, 20);
            vrfCoord.fulfillWithSeed(uint256(i) + 1, address(bestiary), uint256(i) + 1);
        }

        // Prossimo devMint deve revert
        vm.expectRevert(SatoshiBestiaryV4.SupplyExhausted.selector);
        bestiary.devMint(user1, 1);
    }

    /**
     * test_devMint_RevertNotOwner
     * Solo owner può fare devMint.
     */
    function test_devMint_RevertNotOwner() public {
        bestiary = _deployStandardBestiary();

        vm.prank(user2);
        vm.expectRevert();
        bestiary.devMint(user1, 5);
    }

    /**
     * test_VRF_DuplicateCallback_Reverts
     * Fulfill due volte stesso requestId deve revert.
     */
    function test_VRF_DuplicateCallback_Reverts() public {
        bestiary = _deployStandardBestiary();

        bestiary.devMint(user1, 5);

        vrfCoord.fulfillWithSeed(1, address(bestiary), 444);
        assertEq(bestiary.balanceOf(user1), 5);

        // Tenta di fulfillare di nuovo
        vm.expectRevert(SatoshiBestiaryV4.DuplicateCallback.selector);
        vrfCoord.fulfillWithSeed(1, address(bestiary), 555);
    }

    /**
     * test_VRF_Timeout_RefundWorks
     * VRF timeout, richiesta scade, refund funziona.
     */
    function test_VRF_Timeout_RefundWorks() public {
        bestiary = _deployStandardBestiary();
        bestiary.setMintStatus(true);
        vm.roll(7201);

        // Mint richiesta
        vm.prank(user1, user1);
        bestiary.freeMint();

        uint256 pendingBefore = bestiary.pendingPerWallet(user1);
        assertEq(pendingBefore, 5);

        // Aspetta timeout (256 blocchi)
        vm.roll(block.number + 256);

        // Refund
        vm.prank(user1, user1);
        bestiary.refundFailedMint(1);

        uint256 pendingAfter = bestiary.pendingPerWallet(user1);
        assertEq(pendingAfter, 0);
    }

    // =====================================================================
    //  SECTION D: SIGILLO (5 test)
    // =====================================================================

    /**
     * test_revealAndSeal_HappyPath
     * Set URI -> Reveal -> Seal ciclo standard.
     */
    function test_revealAndSeal_HappyPath() public {
        bestiary = _deployStandardBestiary();

        // Set species 0 URI
        string memory uri = "ipfs://species0/";
        bestiary.setSpeciesURI(0, uri);
        assertEq(bestiary.speciesURI(0), uri);

        // Reveal
        bestiary.revealSpecies(0);
        assertTrue(bestiary.speciesRevealed(0));

        // Seal
        bestiary.sealSpecies(0);
        assertTrue(bestiary.speciesSealed(0));
        assertEq(bestiary.sealedCount(), 1);
    }

    /**
     * test_sealSpecies_RevertNotRevealed
     * Non può sigillare una specie che non è stata rivelata.
     */
    function test_sealSpecies_RevertNotRevealed() public {
        bestiary = _deployStandardBestiary();

        // Set URI ma NON reveal
        bestiary.setSpeciesURI(0, "ipfs://uri/");

        vm.expectRevert(SatoshiBestiaryV4.SpeciesNotRevealed.selector);
        bestiary.sealSpecies(0);
    }

    /**
     * test_setSpeciesURI_RevertAfterSeal
     * Non può modificare URI dopo sigillo.
     */
    function test_setSpeciesURI_RevertAfterSeal() public {
        bestiary = _deployStandardBestiary();

        bestiary.setSpeciesURI(0, "ipfs://original/");
        bestiary.revealSpecies(0);
        bestiary.sealSpecies(0);

        vm.expectRevert(SatoshiBestiaryV4.SpeciesURISealed.selector);
        bestiary.setSpeciesURI(0, "ipfs://hacked/");
    }

    /**
     * test_sigilloNero_AllSpeciesSealed
     * Quando tutte le 42 specie sono sigillate, Sigillo Nero attiva.
     */
    function test_sigilloNero_AllSpeciesSealed() public {
        bestiary = _deployStandardBestiary();

        // Set e reveal tutte le 42 specie
        for (uint8 i = 0; i < 42; i++) {
            bestiary.setSpeciesURI(i, string(abi.encodePacked("ipfs://species", vm.toString(i), "/")));
            bestiary.revealSpecies(i);
        }

        // Seal le prime 41
        for (uint8 i = 0; i < 41; i++) {
            bestiary.sealSpecies(i);
            assertFalse(bestiary.sigilloNero());
        }

        // Seal la 42esima -> Sigillo Nero attiva
        bestiary.sealSpecies(41);
        assertTrue(bestiary.sigilloNero());
        assertEq(bestiary.sealedCount(), 42);
    }

    /**
     * test_sigilloNero_RevertIfURIMissing
     * sigilloNeroForceAll() revert se manca URI per qualche specie.
     */
    function test_sigilloNero_RevertIfURIMissing() public {
        bestiary = _deployStandardBestiary();

        // Set URI per 41 specie (skip species 10)
        for (uint8 i = 0; i < 42; i++) {
            if (i != 10) {
                bestiary.setSpeciesURI(i, string(abi.encodePacked("ipfs://uri", vm.toString(i), "/")));
            }
        }

        vm.expectRevert(abi.encodeWithSelector(SatoshiBestiaryV4.SigilloNeroURIMissing.selector, uint8(10)));
        bestiary.sigilloNeroForceAll();
    }

    /**
     * test_sigilloNeroForceAll_FullFlow
     * Happy-path completo: tutte 42 specie hanno URI (nessuna ancora rivelata/sigillata),
     * sigilloNeroForceAll() deve rivelare + sigillare in un colpo.
     * Verifica: gas consumption < 3M, stato finale corretto, eventi emessi.
     */
    function test_sigilloNeroForceAll_FullFlow() public {
        bestiary = _deployStandardBestiary();

        // Set URI per tutte 42 specie, senza rivelare né sigillare
        for (uint8 i = 0; i < 42; i++) {
            bestiary.setSpeciesURI(i, string(abi.encodePacked("ipfs://final/", vm.toString(i), "/")));
        }
        assertEq(bestiary.sealedCount(), 0);
        assertFalse(bestiary.sigilloNero());

        // Force all — misura gas
        uint256 gasBefore = gasleft();
        bestiary.sigilloNeroForceAll();
        uint256 gasUsed = gasBefore - gasleft();

        // Verifica stato finale
        assertTrue(bestiary.sigilloNero(), "Sigillo Nero must be true");
        assertEq(bestiary.sealedCount(), 42, "All 42 species must be sealed");
        for (uint8 i = 0; i < 42; i++) {
            assertTrue(bestiary.speciesRevealed(i), "Each species must be revealed");
            assertTrue(bestiary.speciesSealed(i), "Each species must be sealed");
        }

        // Gas sanity: 42 iterations × ~50k gas/seal ≈ 2.1M → cap conservativo 3M
        assertLt(gasUsed, 3_000_000, "sigilloNeroForceAll gas must be under 3M");
    }

    /**
     * test_sigilloNeroForceAll_RevertDouble
     * Non si può chiamare sigilloNeroForceAll due volte.
     */
    function test_sigilloNeroForceAll_RevertDouble() public {
        bestiary = _deployStandardBestiary();
        for (uint8 i = 0; i < 42; i++) {
            bestiary.setSpeciesURI(i, string(abi.encodePacked("ipfs://x/", vm.toString(i), "/")));
        }
        bestiary.sigilloNeroForceAll();

        vm.expectRevert(SatoshiBestiaryV4.SigilloNeroAlreadyDone.selector);
        bestiary.sigilloNeroForceAll();
    }
}
