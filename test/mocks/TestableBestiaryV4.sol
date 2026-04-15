// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../contracts/SatoshiBestiaryV4.sol";

/**
 * @title TestableBestiaryV4 (Foundry)
 * @notice Wrapper di SatoshiBestiaryV4 con helper per test.
 *         Fornisce accesso a funzioni interne e helper per testare
 *         il comportamento del contratto.
 */
contract TestableBestiaryV4 is SatoshiBestiaryV4 {

    constructor(
        CollectionParams memory cp,
        VRFParams memory vrf
    ) SatoshiBestiaryV4(cp, vrf) {}

    /**
     * @dev Restituisce gli immutable GENESIS_PARAMS standard (Genesis 21K, 42 specie).
     */
    function GENESIS_PARAMS() external pure returns (CollectionParams memory) {
        return CollectionParams({
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
        });
    }

    /**
     * @dev Restituisce i VRF params di default per test.
     */
    function DEFAULT_VRF_PARAMS(
        uint256 subscriptionId,
        address vrfCoordinator
    ) external pure returns (VRFParams memory) {
        return VRFParams({
            subscriptionId: subscriptionId,
            vrfCoordinator: vrfCoordinator,
            keyHash: bytes32(uint256(1)),
            notRevealedURI: "ipfs://hidden/"
        });
    }

    /**
     * @dev Test helper: mint a specific tokenId directly without VRF
     *      Bypassa il VRF e minta direttamente uno specifico tokenId.
     */
    function testMintDirectTo(address to, uint256 tokenId) external {
        require(tokenId >= 1 && tokenId <= maxSupply, "Invalid tokenId");
        _mint(to, tokenId);
        totalSupply++;
    }

    /**
     * @dev Restituisce il numero di IDs rimasti disponibili per il minting.
     *      Utilizza totalSupply come proxy per _remainingIds
     *      (nota: non conta i pending, solo quelli già assegnati).
     */
    function getRemainingIds() external view returns (uint256) {
        return maxSupply - totalSupply;
    }

    /**
     * @dev Helper di debug: ritorna tutti gli immutable del contratto.
     *      Utile per verificare che il constructor abbia impostato
     *      correttamente i parametri.
     */
    function getContractConfig() external view returns (
        uint256 _maxSupply,
        uint256 _devReserve,
        uint256 _publicSupply,
        uint256 _maxPerWallet,
        uint256 _mintBlock,
        uint256 _mintCooldown,
        uint8 _totalSpecies
    ) {
        return (
            maxSupply,
            devReserve,
            publicSupply,
            maxPerWallet,
            mintBlock,
            mintCooldown,
            totalSpecies
        );
    }

    /**
     * @dev Restituisce il numero totale di specie sigilate.
     *      (pubblica, ma alias comodo).
     */
    function getSealedCount() external view returns (uint8) {
        return sealedCount;
    }

    /**
     * @dev Restituisce vero se il Sigillo Nero è stato attivato.
     */
    function getSigilloNero() external view returns (bool) {
        return sigilloNero;
    }
}
