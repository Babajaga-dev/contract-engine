// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/TestableBestiaryV4.sol";
import "./mocks/MockVRFCoordinator.sol";

/**
 * @title BestiaryV4_EdgeCases.t.sol
 * @notice Test suite per edge cases e stress test di SatoshiBestiaryV4.
 *         Copertura: Parametri edge, distribuzioni asimmetriche, load test.
 *         ~20 test organizzati in 3 sezioni.
 */
contract BestiaryV4EdgeCasesTest is Test {
    MockVRFCoordinatorV2Plus vrfCoord;

    address owner;
    address user1;
    address user2;

    // Necessario per ricevere ETH da withdraw()
    receive() external payable {}

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        vrfCoord = new MockVRFCoordinatorV2Plus();
    }

    // =====================================================================
    //  SECTION A: EDGE CASES PARAMETRICI (10 test)
    // =====================================================================

    /**
     * test_MinimalCollection
     * Deploy con supply minima (5), 5 tier, 1 specie per tier, 1 card per specie.
     * Verifica che il contratto funzioni anche con dimensioni ridotte.
     */
    function test_MinimalCollection() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Minimal",
                symbol: "MIN",
                maxSupply: 5,
                devReserve: 1,
                maxPerWallet: 5,
                mintBlock: 1,
                mintCooldown: 0,
                totalSpecies: 5,
                tierBoundaries: [uint256(1), 2, 3, 4, 5],
                speciesPerTier: [uint8(1), 1, 1, 1, 1],
                royaltyBps: 500
            }),
            SatoshiBestiaryV4.VRFParams({
                subscriptionId: 1,
                vrfCoordinator: address(vrfCoord),
                keyHash: bytes32(uint256(1)),
                notRevealedURI: "ipfs://hidden/"
            })
        );

        assertEq(bestiary.maxSupply(), 5);
        assertEq(bestiary.totalSpecies(), 5);
        assertEq(bestiary.devReserve(), 1);
        assertEq(bestiary.publicSupply(), 4);

        // Verifica che getSpeciesId funziona
        uint8 s1 = bestiary.getSpeciesId(1);
        uint8 s5 = bestiary.getSpeciesId(5);
        assertEq(s1, 0);
        assertEq(s5, 4);
    }

    /**
     * test_LargeCollection
     * Deploy con supply grande (100K).
     * Verifica che il contratto scala.
     */
    function test_LargeCollection() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Large",
                symbol: "LRG",
                maxSupply: 100000,
                devReserve: 10000,
                maxPerWallet: 20,
                mintBlock: 5,
                mintCooldown: 7200,
                totalSpecies: 50,
                tierBoundaries: [uint256(1000), 10000, 30000, 70000, 100000],
                speciesPerTier: [uint8(10), 10, 10, 10, 10],
                royaltyBps: 500
            }),
            SatoshiBestiaryV4.VRFParams({
                subscriptionId: 1,
                vrfCoordinator: address(vrfCoord),
                keyHash: bytes32(uint256(1)),
                notRevealedURI: "ipfs://hidden/"
            })
        );

        assertEq(bestiary.maxSupply(), 100000);
        assertEq(bestiary.totalSpecies(), 50);

        // Test getSpeciesId su alcuni punti chiave
        uint8 s1 = bestiary.getSpeciesId(1);
        uint8 s100000 = bestiary.getSpeciesId(100000);
        assertTrue(s1 < 50);
        assertTrue(s100000 < 50);
    }

    /**
     * test_SingleSpeciesPerTier
     * Distribuzione: 1 specie per tier (5 tier totali).
     * Card range: [1..1000, 1001..2000, 2001..3000, 3001..4000, 4001..5000]
     */
    function test_SingleSpeciesPerTier() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "SingleSpecies",
                symbol: "SSP",
                maxSupply: 5000,
                devReserve: 500,
                maxPerWallet: 10,
                mintBlock: 5,
                mintCooldown: 7200,
                totalSpecies: 5,
                tierBoundaries: [uint256(1000), 2000, 3000, 4000, 5000],
                speciesPerTier: [uint8(1), 1, 1, 1, 1],
                royaltyBps: 500
            }),
            SatoshiBestiaryV4.VRFParams({
                subscriptionId: 1,
                vrfCoordinator: address(vrfCoord),
                keyHash: bytes32(uint256(1)),
                notRevealedURI: "ipfs://hidden/"
            })
        );

        // Tutte le carte del tier 0 -> species 0
        assertEq(bestiary.getSpeciesId(1), 0);
        assertEq(bestiary.getSpeciesId(1000), 0);

        // Tutte le carte del tier 1 -> species 1
        assertEq(bestiary.getSpeciesId(1001), 1);
        assertEq(bestiary.getSpeciesId(2000), 1);

        // Verifica gli altri tier
        assertEq(bestiary.getSpeciesId(3000), 2);
        assertEq(bestiary.getSpeciesId(4000), 3);
        assertEq(bestiary.getSpeciesId(5000), 4);
    }

    /**
     * test_UnevenTierDistribution
     * Distribuzione asimmetrica: la maggior parte nel tier Common.
     * Tier boundaries: [1, 2, 3, 4, 21000] (quasi tutto Common)
     */
    function test_UnevenTierDistribution() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Uneven",
                symbol: "UNV",
                maxSupply: 21000,
                devReserve: 100,
                maxPerWallet: 10,
                mintBlock: 5,
                mintCooldown: 7200,
                totalSpecies: 5,
                tierBoundaries: [uint256(1), 2, 3, 4, 21000],
                speciesPerTier: [uint8(1), 1, 1, 1, 1],
                royaltyBps: 500
            }),
            SatoshiBestiaryV4.VRFParams({
                subscriptionId: 1,
                vrfCoordinator: address(vrfCoord),
                keyHash: bytes32(uint256(1)),
                notRevealedURI: "ipfs://hidden/"
            })
        );

        assertEq(bestiary.maxSupply(), 21000);

        // Tier 0: 1 carta -> species 0
        assertEq(bestiary.getSpeciesId(1), 0);

        // Tier 1: 1 carta -> species 1
        assertEq(bestiary.getSpeciesId(2), 1);

        // Tier 4 (Common): 20996 carte -> species 4
        assertEq(bestiary.getSpeciesId(5), 4);
        assertEq(bestiary.getSpeciesId(21000), 4);
    }

    /**
     * test_MaxPerWallet_EqualsMintBlock
     * maxPerWallet = mintBlock = 5.
     * Permette solo 1 mint per wallet.
     */
    function test_MaxPerWallet_EqualsMintBlock() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "MaxWallet",
                symbol: "MWL",
                maxSupply: 21000,
                devReserve: 2100,
                maxPerWallet: 5, // == mintBlock
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

        bestiary.setMintStatus(true);
        vm.roll(7201);

        // Primo mint funziona
        vm.prank(user1, user1);
        bestiary.freeMint();
        vrfCoord.fulfillWithSeed(1, address(bestiary), 111);

        // Secondo mint deve revert (max per wallet raggiunto)
        vm.roll(block.number + 7200);
        vm.prank(user1, user1);
        vm.expectRevert(SatoshiBestiaryV4.MaxPerWallet.selector);
        bestiary.freeMint();
    }

    /**
     * test_DevReserve_Zero
     * devReserve = 0, tutto è public supply.
     */
    function test_DevReserve_Zero() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "NoDevReserve",
                symbol: "NDR",
                maxSupply: 21000,
                devReserve: 0, // No dev reserve
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

        assertEq(bestiary.devReserve(), 0);
        assertEq(bestiary.publicSupply(), 21000);

        // devMint deve revert (supply == 0)
        vm.expectRevert(SatoshiBestiaryV4.SupplyExhausted.selector);
        bestiary.devMint(user1, 1);
    }

    /**
     * test_DevReserve_EqualMax
     * devReserve == maxSupply, tutto è dev, niente public.
     */
    function test_DevReserve_EqualMax() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "AllDev",
                symbol: "ADV",
                maxSupply: 1000,
                devReserve: 1000, // All dev
                maxPerWallet: 10,
                mintBlock: 5,
                mintCooldown: 7200,
                totalSpecies: 5,
                tierBoundaries: [uint256(100), 300, 500, 700, 1000], // Monotonic, ultimo = maxSupply
                speciesPerTier: [uint8(1), 1, 1, 1, 1],
                royaltyBps: 500
            }),
            SatoshiBestiaryV4.VRFParams({
                subscriptionId: 1,
                vrfCoordinator: address(vrfCoord),
                keyHash: bytes32(uint256(1)),
                notRevealedURI: "ipfs://hidden/"
            })
        );

        assertEq(bestiary.devReserve(), 1000);
        assertEq(bestiary.publicSupply(), 0);

        bestiary.setMintStatus(true);
        vm.roll(7201);

        // freeMint deve revert (public supply == 0)
        vm.prank(user1, user1);
        vm.expectRevert(SatoshiBestiaryV4.SupplyExhausted.selector);
        bestiary.freeMint();
    }

    /**
     * test_MintCooldown_Zero
     * mintCooldown = 0, nessun cooldown tra i mint.
     */
    function test_MintCooldown_Zero() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "NoCooldown",
                symbol: "NCL",
                maxSupply: 21000,
                devReserve: 2100,
                maxPerWallet: 10,
                mintBlock: 5,
                mintCooldown: 0, // No cooldown
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

        bestiary.setMintStatus(true);
        vm.roll(1);

        // Primo mint
        vm.prank(user1, user1);
        bestiary.freeMint();
        vrfCoord.fulfillWithSeed(1, address(bestiary), 111);

        // Secondo mint subito (stesso block) deve funzionare
        vm.prank(user1, user1);
        bestiary.freeMint();
        vrfCoord.fulfillWithSeed(2, address(bestiary), 222);

        assertEq(bestiary.balanceOf(user1), 10);
    }

    /**
     * test_getSpeciesId_Epoch_42K
     * Deploy Epoch (42K), verifica boundary tokens.
     */
    function test_getSpeciesId_Epoch_42K() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Epoch",
                symbol: "SB2",
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
                subscriptionId: 1,
                vrfCoordinator: address(vrfCoord),
                keyHash: bytes32(uint256(2)),
                notRevealedURI: "ipfs://hidden2/"
            })
        );

        // Verifica boundary Mythic->Legendary
        assertEq(bestiary.getSpeciesId(42), 1); // Last Mythic
        assertEq(bestiary.getSpeciesId(43), 2); // First Legendary

        // Verifica boundary Common
        assertEq(bestiary.getSpeciesId(42000), 41); // Last token
    }

    /**
     * test_getSpeciesId_MaxTokenId_AllTiers
     * Loop su tier boundaries, verifica che getSpeciesId non revert.
     */
    function test_getSpeciesId_MaxTokenId_AllTiers() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "AllTiers",
                symbol: "ATR",
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

        // Test ogni tier boundary
        uint256[] memory boundaries = new uint256[](5);
        boundaries[0] = 21;
        boundaries[1] = 1050;
        boundaries[2] = 3150;
        boundaries[3] = 7350;
        boundaries[4] = 21000;

        for (uint256 i = 0; i < 5; i++) {
            uint8 species = bestiary.getSpeciesId(boundaries[i]);
            assertTrue(species < 42, "Species out of range");
        }
    }

    // =====================================================================
    //  SECTION B: LOAD / STRESS (5 test)
    // =====================================================================

    /**
     * test_MassDevMint_100Batches
     * 100 lotti di devMint(20), verify totalSupply = 2000.
     */
    function test_MassDevMint_100Batches() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Load Test",
                symbol: "LOD",
                maxSupply: 100000,
                devReserve: 100000, // All dev
                maxPerWallet: 100,
                mintBlock: 20,
                mintCooldown: 0,
                totalSpecies: 42,
                tierBoundaries: [uint256(2000), 10000, 30000, 70000, 100000],
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

        // 100 batch di 20 = 2000
        for (uint256 i = 0; i < 100; i++) {
            bestiary.devMint(user1, 20);
            vrfCoord.fulfillWithSeed(uint256(i) + 1, address(bestiary), uint256(i) + 1);
        }

        assertEq(bestiary.totalSupply(), 2000);
        assertEq(bestiary.devMinted(), 2000);
    }

    /**
     * test_MultipleUsers_ConcurrentMint
     * 10 utenti mintano in parallelo.
     */
    function test_MultipleUsers_ConcurrentMint() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Concurrent",
                symbol: "CNC",
                maxSupply: 21000,
                devReserve: 2100,
                maxPerWallet: 10,
                mintBlock: 5,
                mintCooldown: 0,
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

        bestiary.setMintStatus(true);
        vm.roll(7201);

        address[] memory users = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", vm.toString(i))));
        }

        // Tutti mintano
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(users[i], users[i]);
            bestiary.freeMint();
        }

        // Fulfilla tutte le richieste
        for (uint256 i = 0; i < 10; i++) {
            vrfCoord.fulfillWithSeed(uint256(i) + 1, address(bestiary), uint256(i) + 1);
        }

        // Verifica: 10 utenti x 5 NFT = 50
        assertEq(bestiary.totalSupply(), 50);
        for (uint256 i = 0; i < 10; i++) {
            assertEq(bestiary.balanceOf(users[i]), 5);
        }
    }

    /**
     * test_SupplyExhaustion_PublicMint
     * Minta finché la supply pubblica non si esaurisce.
     */
    function test_SupplyExhaustion_PublicMint() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Exhaust",
                symbol: "EXH",
                maxSupply: 100,
                devReserve: 10,
                maxPerWallet: 50,
                mintBlock: 5,
                mintCooldown: 0,
                totalSpecies: 10,
                tierBoundaries: [uint256(10), 20, 30, 40, 100],
                speciesPerTier: [uint8(2), 2, 2, 2, 2],
                royaltyBps: 500
            }),
            SatoshiBestiaryV4.VRFParams({
                subscriptionId: 1,
                vrfCoordinator: address(vrfCoord),
                keyHash: bytes32(uint256(1)),
                notRevealedURI: "ipfs://hidden/"
            })
        );

        bestiary.setMintStatus(true);
        vm.roll(1);

        // Public supply = 90, maxPerWallet = 50, mintBlock = 5
        // Usa 2 utenti: user1 minta 50 (10 lotti), user2 minta 40 (8 lotti)
        uint256 reqId = 1;
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(user1, user1);
            bestiary.freeMint();
            vrfCoord.fulfillWithSeed(reqId++, address(bestiary), reqId);
        }
        assertEq(bestiary.mintedPerWallet(user1), 50);

        for (uint256 i = 0; i < 8; i++) {
            vm.prank(user2, user2);
            bestiary.freeMint();
            vrfCoord.fulfillWithSeed(reqId++, address(bestiary), reqId);
        }

        assertEq(bestiary.publicMinted(), 90);

        // Prossimo mint deve revert (supply esaurita)
        vm.prank(user2, user2);
        vm.expectRevert(SatoshiBestiaryV4.SupplyExhausted.selector);
        bestiary.freeMint();
    }

    /**
     * test_RefundAllExpired_LargeQueue
     * 50 mint pendenti, tutte scadute, refund batch.
     */
    function test_RefundAllExpired_LargeQueue() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "LargeQueue",
                symbol: "LQU",
                maxSupply: 100000,
                devReserve: 50000,
                maxPerWallet: 100,
                mintBlock: 5,
                mintCooldown: 0,
                totalSpecies: 42,
                tierBoundaries: [uint256(2000), 10000, 30000, 70000, 100000],
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

        // 50 dev mint (10 per utente)
        for (uint256 i = 0; i < 50; i++) {
            bestiary.devMint(user1, 1);
        }

        assertEq(bestiary.devPending(), 50);

        // Timeout
        vm.roll(block.number + 256);

        // Refund batch
        uint256 refunded = bestiary.refundAllExpiredDevMints();

        assertEq(refunded, 50);
        assertEq(bestiary.devPending(), 0);
    }

    /**
     * test_BatchBurnFrom_MaxSize
     * Burn batch di 50 token.
     */
    function test_BatchBurnFrom_MaxSize() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Burn",
                symbol: "BRN",
                maxSupply: 21000,
                devReserve: 2100,
                maxPerWallet: 100,
                mintBlock: 5,
                mintCooldown: 0,
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

        // Mint 50 token per user1
        for (uint256 i = 1; i <= 50; i++) {
            bestiary.testMintDirectTo(user1, i);
        }

        assertEq(bestiary.balanceOf(user1), 50);
        assertEq(bestiary.totalSupply(), 50);

        // Prepara array di tokenIds da burnare
        uint256[] memory tokenIds = new uint256[](50);
        for (uint256 i = 0; i < 50; i++) {
            tokenIds[i] = i + 1;
        }

        // Approve per il burn
        vm.prank(user1);
        bestiary.setApprovalForAll(address(this), true);

        // Burn batch
        bestiary.batchBurnFrom(user1, tokenIds);

        assertEq(bestiary.balanceOf(user1), 0);
        assertEq(bestiary.totalSupply(), 0);
    }

    // =====================================================================
    //  SECTION C: ACCESS CONTROL (5 test)
    // =====================================================================

    /**
     * test_onlyOwner_setMintStatus
     * Solo owner può cambiare mint status.
     */
    function test_onlyOwner_setMintStatus() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "AC",
                symbol: "ACL",
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

        // Non-owner revert
        vm.prank(user1);
        vm.expectRevert();
        bestiary.setMintStatus(true);

        // Owner OK
        bestiary.setMintStatus(true);
        assertTrue(bestiary.publicMintActive());
    }

    /**
     * test_onlyOwner_setForgeContract
     * Solo owner può impostare forge contract.
     */
    function test_onlyOwner_setForgeContract() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Forge",
                symbol: "FRG",
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

        address forgeAddr = makeAddr("forge");

        // Non-owner revert
        vm.prank(user1);
        vm.expectRevert();
        bestiary.setForgeContract(forgeAddr);

        // Owner OK
        bestiary.setForgeContract(forgeAddr);
        assertEq(bestiary.forgeContract(), forgeAddr);
    }

    /**
     * test_onlyOwner_lockContracts
     * Solo owner può lockare i contratti.
     */
    function test_onlyOwner_lockContracts() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Lock",
                symbol: "LCK",
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

        // Non-owner revert
        vm.prank(user1);
        vm.expectRevert();
        bestiary.lockContracts();

        // Owner OK
        bestiary.lockContracts();
        assertTrue(bestiary.contractsLocked());
    }

    /**
     * test_lockContracts_PreventsFurtherChanges
     * Dopo lock, setForgeContract deve revert.
     */
    function test_lockContracts_PreventsFurtherChanges() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "PrevChange",
                symbol: "PCH",
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

        address forge1 = makeAddr("forge1");
        address forge2 = makeAddr("forge2");

        // Set forge prima del lock
        bestiary.setForgeContract(forge1);
        assertEq(bestiary.forgeContract(), forge1);

        // Lock
        bestiary.lockContracts();

        // Tentativo di cambiare forge dopo lock revert
        vm.expectRevert(SatoshiBestiaryV4.ContractsAlreadyLocked.selector);
        bestiary.setForgeContract(forge2);
    }

    /**
     * test_withdraw_OnlyOwner
     * Solo owner può fare withdraw.
     */
    function test_withdraw_OnlyOwner() public {
        TestableBestiaryV4 bestiary = new TestableBestiaryV4(
            SatoshiBestiaryV4.CollectionParams({
                name: "Withdraw",
                symbol: "WDR",
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

        // Aggiungi balance
        vm.deal(address(bestiary), 1 ether);

        // Non-owner revert
        vm.prank(user1);
        vm.expectRevert();
        bestiary.withdraw();

        // Owner OK
        uint256 ownerBalanceBefore = owner.balance;
        bestiary.withdraw();

        assertEq(address(bestiary).balance, 0);
        assertEq(owner.balance, ownerBalanceBefore + 1 ether);
    }
}
