// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================================
//  ERC721C — OZ v5 native implementation of the Limit Break Creator Token
//  Standard (creator-token-contracts v1 / creator-token-standards v5).
//
//  Perché questo file esiste:
//    @limitbreak/creator-token-contracts  usa gli hook OZ v4
//    (_beforeTokenTransfer / _afterTokenTransfer con batchSize) che OZ v5 ha
//    rimosso e sostituito con _update(). Nessun package Limit Break supporta
//    OZ v5 nativamente, quindi implementiamo lo standard inline.
//
//  Funzionalità replicate:
//    - _update() hook  → chiama il transfer validator su ogni trasferimento
//    - setToDefaultSecurityPolicy() → attiva il validator Limit Break V3
//    - setTransferValidator()        → imposta validator custom (o zero)
//    - getTransferValidator()        → legge il validator attivo
//    - supportsInterface()           → espone ICreatorToken (0xad0d7f6c)
//
//  Transfer Validator V3 (same address on Ethereum, Base, Polygon, Arbitrum,
//  Optimism — deploy deterministico Limit Break via CREATE2):
//    0x0000721C310194CcfC01E523fc93C9cCcFa2A0Ac
// ============================================================================

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev Interfaccia minimale del Limit Break Transfer Validator V3.
///      Signature confermata da: limitbreak/creator-token-standards src/erc721c/ERC721C.sol
///      getTransferValidationFunction() returns "validateTransfer(address,address,address,uint256)"
interface ICreatorTokenTransferValidator {
    function validateTransfer(
        address caller,
        address from,
        address to,
        uint256 tokenId
    ) external view;
}

/// @title ERC721C
/// @notice Abstract ERC721 con enforcement delle royalties tramite il
///         Limit Break Transfer Validator V3. Drop-in replacement per
///         limitbreak/creator-token-contracts, compatibile con OZ v5.
abstract contract ERC721C is ERC721 {

    // -----------------------------------------------------------------------
    //  Costanti
    // -----------------------------------------------------------------------

    /// @dev InterfaceId di ICreatorToken — richiesto dai marketplace (OpenSea, etc.)
    ///      per riconoscere i contratti ERC721C.
    bytes4 private constant _INTERFACE_ID_CREATOR_TOKEN = 0xad0d7f6c;

    /// @dev Indirizzo del Transfer Validator V3 di Limit Break.
    ///      Stesso indirizzo su tutte le chain (CREATE2 deterministico).
    address private constant _DEFAULT_TRANSFER_VALIDATOR =
        0x0000721C310194CcfC01E523fc93C9cCcFa2A0Ac;

    // -----------------------------------------------------------------------
    //  Storage
    // -----------------------------------------------------------------------

    /// @dev Emesso quando il transfer validator viene modificato.
    event TransferValidatorUpdated(address indexed oldValidator, address indexed newValidator);

    /// @dev Transfer validator attivo. Inizialmente zero (nessun enforcement).
    ///      ⚠️ FIX AUDIT F-12: OBBLIGATORIO chiamare setToDefaultSecurityPolicy()
    ///      subito dopo il deploy per attivare l'enforcement delle royalties.
    ///      Senza questa chiamata, i marketplace non-compliant (es. Blur)
    ///      possono scambiare token senza pagare il 5% di royalty.
    ///      Aggiungere alla Preflight List (docs/CTO/5_Preflight_List.html).
    address private _transferValidator;

    // -----------------------------------------------------------------------
    //  Constructor
    // -----------------------------------------------------------------------

    constructor(string memory name_, string memory symbol_)
        ERC721(name_, symbol_)
    {}

    // -----------------------------------------------------------------------
    //  Interface detection
    // -----------------------------------------------------------------------

    function supportsInterface(bytes4 interfaceId)
        public view virtual override
        returns (bool)
    {
        return interfaceId == _INTERFACE_ID_CREATOR_TOKEN ||
               super.supportsInterface(interfaceId);
    }

    // -----------------------------------------------------------------------
    //  Transfer Validator API
    // -----------------------------------------------------------------------

    /// @notice Restituisce il validator attivo (zero se enforcement disattivato).
    function getTransferValidator() external view returns (address) {
        return _transferValidator;
    }

    /// @notice Attiva la Default Security Policy di Limit Break:
    ///         blocca i marketplace che non rispettano le royalties (Blur, etc.).
    ///         OBBLIGATORIO chiamare questa funzione una volta dopo il deploy.
    ///         Solo il contract owner può chiamarla.
    function setToDefaultSecurityPolicy() external virtual {
        _requireCallerIsContractOwner();
        address oldValidator = _transferValidator;
        _transferValidator = _DEFAULT_TRANSFER_VALIDATOR;
        emit TransferValidatorUpdated(oldValidator, _DEFAULT_TRANSFER_VALIDATOR);
    }

    /// @notice Imposta un transfer validator custom (o address(0) per disattivare).
    ///         Solo il contract owner può chiamarla.
    function setTransferValidator(address validator) external virtual {
        _requireCallerIsContractOwner();
        address oldValidator = _transferValidator;
        _transferValidator = validator;
        emit TransferValidatorUpdated(oldValidator, validator);
    }

    // -----------------------------------------------------------------------
    //  OZ v5 _update hook — Transfer validation
    // -----------------------------------------------------------------------

    /// @dev Override dell'hook OZ v5 _update().
    ///      Su ogni trasferimento reale (non mint, non burn), chiama il
    ///      validator esterno che reverterà se il transfer non è consentito
    ///      dalla security policy della collection.
    function _update(address to, uint256 tokenId, address auth)
        internal virtual override
        returns (address)
    {
        address from = super._update(to, tokenId, auth);

        // Valida solo i trasferimenti reali (da ≠ 0 e a ≠ 0).
        // Mint (from=0) e burn (to=0) sono sempre permessi.
        if (from != address(0) && to != address(0)) {
            address validator = _transferValidator;
            if (validator != address(0)) {
                ICreatorTokenTransferValidator(validator).validateTransfer(
                    msg.sender,
                    from,
                    to,
                    tokenId
                );
            }
        }

        return from;
    }

    // -----------------------------------------------------------------------
    //  Abstract — da implementare nel contratto figlio
    // -----------------------------------------------------------------------

    /// @dev Deve revertire se msg.sender non è il contract owner.
    ///      Mira il sistema di ownership esistente (ConfirmedOwner, OZ Ownable, etc.).
    function _requireCallerIsContractOwner() internal view virtual;
}
