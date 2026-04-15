// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SatoshiTournament — Sistema Tornei Ufficiali Satoshi Bestiary
 * @notice Contratto permanente che gestisce N tornei simultanei con treasury multi-contratto.
 *         Entry fee SEMPRE ZERO. Premi da organizzatore/sponsor o auto-split mint.
 *
 * @dev Decisioni di design (docs/36_Fase_F_Tornei.md v2.1):
 *      F-01: Entry fee sempre zero (no gambling)
 *      F-02: 1 contratto permanente, multi-torneo (mapping)
 *      F-03: Treasury centralizzata con allocazione per torneo
 *      F-17: Iscrizioni illimitate (maxPlayers=0 default)
 *      F-18: Premi NFT multi-contratto (NftPrize struct)
 *      F-19: Token lock solo per formati premium (Conquista/Sigillo d'Oro)
 *      F-20: Bye per dispari gestito server-side (contratto non ne sa nulla)
 *      F-21: depositNFTToTreasury flag PRIMA del safeTransferFrom (anti double-count)
 *      F-22: Batch unlock + selfUnlock per evitare gas DoS con molti player (audit H-01)
 *      F-23: nftAllocatedToTournament mapping per proteggere withdrawNFT (audit H-02)
 *      F-24: Unicità winners in submitResults (audit M-01)
 *
 *      Architettura:
 *      - Treasury riceve ETH da auto-split BestiaryV4.paidMint() + depositi manuali
 *      - Treasury riceve NFT da qualsiasi ERC-721 (multi-contratto, multi-serie)
 *      - Organizer alloca fondi dalla treasury a tornei specifici
 *      - Arbiter submitta risultati + Merkle root dei match log
 *      - Vincitori claimano premi (pull-pattern ETH, safeTransferFrom NFT)
 *
 *      Lifecycle: CREATED → REGISTRATION → IN_PROGRESS → FINALIZED → CLAIMABLE → CLOSED
 */

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @dev Interface minima del BestiaryV4 per token lock
interface IBestiaryV4 {
    function setTokenLock(uint256[] calldata tokenIds, bool locked) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract SatoshiTournament is AccessControl, Pausable, ReentrancyGuard, IERC721Receiver {

    // =====================================================================
    //  ROLES
    // =====================================================================

    bytes32 public constant ORGANIZER_ROLE = keccak256("ORGANIZER_ROLE");
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");

    // DEFAULT_ADMIN_ROLE from AccessControl = emergency admin (multisig)

    // =====================================================================
    //  ENUMS
    // =====================================================================

    enum TournamentStatus {
        CREATED,        // 0 — slot creato, premi allocabili
        REGISTRATION,   // 1 — iscrizioni aperte
        IN_PROGRESS,    // 2 — partite in corso (server)
        FINALIZED,      // 3 — risultati scritti, Merkle root immutabile
        CLAIMABLE,      // 4 — vincitori possono claimare
        CLOSED          // 5 — storico, fondi non claimati tornati in treasury
    }

    enum TournamentFormat {
        ARENA_APERTA,   // 0 — nessun lock, chiunque
        CONQUISTA,      // 1 — 10 carte lockate, "Triade si ritira"
        SIGILLO_ORO     // 2 — 15 carte lockate, elite, su invito
    }

    enum BracketStructure {
        SWISS_BRACKET,  // 0 — Swiss + Top N bracket (default)
        SINGLE_ELIM,    // 1 — eliminazione diretta
        ROUND_ROBIN     // 2 — tutti contro tutti (gironi se N>10)
    }

    // =====================================================================
    //  STRUCTS
    // =====================================================================

    /// @notice Premio NFT singolo — supporta qualsiasi ERC-721
    struct NftPrize {
        address nftContract;    // Bestiary Genesis, Epoch, Forge, o qualsiasi ERC-721
        uint256 tokenId;
        uint8 placement;        // 0 = non assegnato, 1 = 1° posto, 2 = 2°, etc.
        bool claimed;
    }

    /// @notice Configurazione iniziale di un torneo
    struct TournamentConfig {
        string name;
        TournamentFormat format;
        BracketStructure structure;
        uint8 bestOf;           // 1, 3, o 5
        uint32 maxPlayers;      // 0 = illimitato
        address arbiter;        // wallet arbiter per questo torneo
        address bestiaryContract; // contratto Bestiary per lock (solo Conquista/Sigillo)
    }

    /// @notice Stato completo di un torneo
    struct Tournament {
        string name;
        TournamentFormat format;
        BracketStructure structure;
        uint8 bestOf;
        uint32 maxPlayers;          // 0 = illimitato
        uint32 registeredCount;
        TournamentStatus status;
        uint256 ethPrize;           // ETH totale allocato a questo torneo
        uint256 ethClaimed;         // ETH già claimato
        uint16[] prizeSplitBps;     // split ETH per posizione (somma = 10000)
        bytes32 matchLogsRoot;      // Merkle root dei match log
        address organizer;          // chi ha creato il torneo
        address arbiter;            // chi può submittare risultati
        address bestiaryContract;   // contratto Bestiary per lock carte
        uint64 startTime;
        uint64 endTime;
        uint64 claimDeadline;       // dopo questo timestamp, closeTournament() possibile
        uint64 resultsDeadline;     // M-04: dopo questo timestamp, torneo cancellabile se ancora IN_PROGRESS
    }

    // =====================================================================
    //  STATE
    // =====================================================================

    // --- Treasury ---
    uint256 public treasuryEthBalance;      // ETH totale nella treasury (depositato - allocato)
    uint256 public treasuryEthAllocated;    // ETH allocato a tornei attivi

    /// @notice NFT nella treasury, indicizzati per (nftContract, tokenId) → true se presente
    mapping(address => mapping(uint256 => bool)) public treasuryNfts;
    uint256 public treasuryNftCount;

    /// @notice [H-02] Tracking NFT allocati: (nftContract, tokenId) → tournamentId (0 = non allocato)
    mapping(address => mapping(uint256 => uint256)) public nftAllocatedToTournament;

    // --- Tornei ---
    uint256 public nextTournamentId;
    mapping(uint256 => Tournament) public tournaments;

    // --- Premi NFT per torneo (array separato, non nello struct per evitare nested mapping issues) ---
    mapping(uint256 => NftPrize[]) public tournamentNftPrizes;

    // --- Registrazioni ---
    mapping(uint256 => mapping(address => bool)) public isRegistered;

    // --- Token lock tracking (per unlock a fine torneo) ---
    /// @dev tournamentId → player → tokenIds[] lockati
    mapping(uint256 => mapping(address => uint256[])) public lockedTokens;
    /// @dev tournamentId → lista di tutti i player che hanno lockato carte
    mapping(uint256 => address[]) public lockPlayers;

    // --- Piazzamenti ---
    /// @dev tournamentId → posizione (1-indexed) → wallet vincitore
    mapping(uint256 => mapping(uint16 => address)) public placements;
    mapping(uint256 => uint16) public placementCount;

    // --- Claims ---
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    // --- Inviti (solo Sigillo d'Oro) ---
    mapping(uint256 => mapping(address => bool)) public isInvited;

    // =====================================================================
    //  CONSTANTS
    // =====================================================================

    uint16 public constant MAX_SPLIT_BPS = 10000;
    uint32 public constant DEFAULT_CLAIM_PERIOD = 30 days;
    uint32 public constant DEFAULT_RESULTS_PERIOD = 7 days; // M-04: max time for results submission
    uint16 public constant MAX_PRIZE_SPLIT_ENTRIES = 32; // max posizioni premiabili
    uint8 public constant MAX_LOCK_CARDS_CONQUISTA = 10;
    uint8 public constant MAX_LOCK_CARDS_SIGILLO = 15;

    // =====================================================================
    //  ERRORS
    // =====================================================================

    error InvalidBestOf();
    error InvalidSplitSum();
    error TooManySplitEntries();
    error InvalidArbiter();
    error TournamentNotFound();
    error TournamentAlreadyClosed();
    error WrongStatus(TournamentStatus expected, TournamentStatus actual);
    error MaxPlayersReached();
    error AlreadyRegistered();
    error NotRegistered();
    error NotInvited();
    error InsufficientTreasuryEth();
    error InsufficientTreasuryNft();
    error NftNotInTreasury();
    error NftAlreadyAllocated();
    error EthTransferFailed();
    error NftTransferFailed();
    error NoPlacement();
    error AlreadyClaimed();
    error ResultsAlreadySubmitted();
    error PlacementsExceedRegistered();
    error ClaimDeadlineNotReached();
    error InvalidTokenCount();
    error TokenNotOwned();
    error InvalidBestiaryContract();
    error LockNotRequired();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidNameLength();           // L-01: nome torneo vuoto o troppo lungo
    error InvalidNftIndex();             // I-01: require→custom error
    error InvalidPlacement();            // I-01: require→custom error
    error NotSigilloOro();               // I-01: require→custom error
    error CannotInviteInStatus();        // I-01: require→custom error
    error CannotCancelInStatus();        // I-01: require→custom error
    error NeedMinimumPlayers();          // I-01: require→custom error
    error NotArbiterOrOrganizer();       // I-01: require→custom error
    error WinnerNotRegistered();         // I-01: require→custom error
    error DuplicateWinner();             // M-01: unicità winners
    error NftAllocatedToActiveTournament(); // H-02: withdrawNFT protezione
    error TournamentStillInProgress();   // H-01: selfUnlock guard
    error NoLockedTokens();              // H-01: selfUnlock guard
    error ResultsDeadlineExpired();      // M-04: deadline for results submission
    error ResultsDeadlineNotReached();   // M-04: cancel after deadline
    error PrizeSplitTooShort();          // M-02: prizeSplitBps doesn't cover all placements

    // =====================================================================
    //  EVENTS
    // =====================================================================

    event TreasuryEthDeposited(address indexed from, uint256 amount);
    event TreasuryNftDeposited(address indexed from, address indexed nftContract, uint256 tokenId);
    event TreasuryEthWithdrawn(address indexed to, uint256 amount);
    event TreasuryNftWithdrawn(address indexed to, address indexed nftContract, uint256 tokenId);

    event TournamentCreated(uint256 indexed tournamentId, string name, TournamentFormat format);
    event EthPrizeAllocated(uint256 indexed tournamentId, uint256 amount);
    event NftPrizeAllocated(uint256 indexed tournamentId, address indexed nftContract, uint256 tokenId);
    event PrizeDeallocated(uint256 indexed tournamentId);
    event PrizeSplitSet(uint256 indexed tournamentId, uint16[] splitBps);

    event RegistrationOpened(uint256 indexed tournamentId);
    event PlayerRegistered(uint256 indexed tournamentId, address indexed player);
    event PlayerRegisteredWithLock(uint256 indexed tournamentId, address indexed player, uint256 tokenCount);
    event TournamentStarted(uint256 indexed tournamentId);
    event TournamentCancelled(uint256 indexed tournamentId);

    event ResultsSubmitted(uint256 indexed tournamentId, bytes32 matchLogsRoot, uint8 placementCount);
    event ClaimsEnabled(uint256 indexed tournamentId, uint64 claimDeadline);
    event PrizeClaimed(uint256 indexed tournamentId, address indexed winner, uint16 placement, uint256 ethAmount);
    event NftPrizeClaimed(uint256 indexed tournamentId, address indexed winner, address indexed nftContract, uint256 tokenId);
    event TournamentClosed(uint256 indexed tournamentId, uint256 unclaimedEthReturned);

    event PlayerInvited(uint256 indexed tournamentId, address indexed player);
    event TokensUnlocked(uint256 indexed tournamentId, address indexed player, uint256 tokenCount);
    event NftAssignedToPlacement(uint256 indexed tournamentId, uint256 nftIndex, uint8 placement); // L-03
    event EmergencyEvacuated(uint256 indexed tournamentId, address indexed to, uint256 ethAmount, uint256 nftCount); // F-08: monitoring

    // =====================================================================
    //  CONSTRUCTOR
    // =====================================================================

    /// @param admin Multisig address per DEFAULT_ADMIN_ROLE (pause/unpause, emergency)
    /// @param organizer Initial organizer (CTO wallet)
    constructor(address admin, address organizer) {
        if (admin == address(0) || organizer == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORGANIZER_ROLE, organizer);
    }

    // =====================================================================
    //  TREASURY — Depositi
    // =====================================================================

    /// @notice Riceve ETH (da auto-split BestiaryV4 o depositi manuali)
    receive() external payable {
        treasuryEthBalance += msg.value;
        emit TreasuryEthDeposited(msg.sender, msg.value);
    }

    /// @notice Deposito manuale ETH nella treasury
    function depositToTreasury() external payable {
        if (msg.value == 0) revert ZeroAmount();
        treasuryEthBalance += msg.value;
        emit TreasuryEthDeposited(msg.sender, msg.value);
    }

    /// @notice Deposito NFT da qualsiasi ERC-721 nella treasury
    /// @dev Il chiamante deve aver fatto approve() prima.
    ///      Flag settato PRIMA del safeTransferFrom per evitare double-count
    ///      nel callback onERC721Received (CEI pattern invertito ma safe con nonReentrant).
    function depositNFTToTreasury(address nftContract, uint256 tokenId) external nonReentrant {
        if (nftContract == address(0)) revert ZeroAddress();

        // Segna PRIMA del transfer — onERC721Received vedrà treasuryNfts=true e non incrementerà
        treasuryNfts[nftContract][tokenId] = true;
        treasuryNftCount++;

        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);

        emit TreasuryNftDeposited(msg.sender, nftContract, tokenId);
    }

    /// @notice Callback ERC-721 — necessario per ricevere NFT via safeTransferFrom
    /// @dev NOTA: accetta qualsiasi ERC-721 (by-design, multi-contratto). Questo significa che
    ///      NFT "spam" possono gonfiare treasuryNftCount. L'impatto è nullo: l'organizer
    ///      non può allocare NFT che non ha depositato, e withdrawNFT richiede ORGANIZER_ROLE.
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        // Se arriva un NFT non tramite depositNFTToTreasury, lo trackiamo comunque
        if (!treasuryNfts[msg.sender][tokenId]) {
            treasuryNfts[msg.sender][tokenId] = true;
            treasuryNftCount++;
            emit TreasuryNftDeposited(from, msg.sender, tokenId);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    // =====================================================================
    //  TREASURY — Prelievi (solo fondi NON allocati)
    // =====================================================================

    /// @notice Ritira ETH non allocato dalla treasury
    function withdrawUnallocated(uint256 amount) external onlyRole(ORGANIZER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 available = treasuryEthBalance - treasuryEthAllocated;
        if (amount > available) revert InsufficientTreasuryEth();

        treasuryEthBalance -= amount;

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert EthTransferFailed();

        emit TreasuryEthWithdrawn(msg.sender, amount);
    }

    /// @notice Ritira NFT non allocato dalla treasury
    /// @dev H-02: check nftAllocatedToTournament impedisce ritiro di NFT allocati
    function withdrawNFT(address nftContract, uint256 tokenId) external onlyRole(ORGANIZER_ROLE) nonReentrant {
        if (!treasuryNfts[nftContract][tokenId]) revert NftNotInTreasury();
        // H-02: verifica che l'NFT non sia allocato a un torneo
        if (nftAllocatedToTournament[nftContract][tokenId] != 0) revert NftAllocatedToActiveTournament();

        // CEI pattern: rimuovi dalla treasury PRIMA del transfer
        treasuryNfts[nftContract][tokenId] = false;
        treasuryNftCount--;

        IERC721(nftContract).safeTransferFrom(address(this), msg.sender, tokenId);

        emit TreasuryNftWithdrawn(msg.sender, nftContract, tokenId);
    }

    // =====================================================================
    //  TOURNAMENT — Creazione
    // =====================================================================

    /// @notice Crea un nuovo torneo
    function createTournament(TournamentConfig calldata config) external onlyRole(ORGANIZER_ROLE) returns (uint256) {
        // L-01: validazione nome
        if (bytes(config.name).length == 0 || bytes(config.name).length > 128) revert InvalidNameLength();
        if (config.bestOf != 1 && config.bestOf != 3 && config.bestOf != 5) revert InvalidBestOf();
        if (config.arbiter == address(0)) revert InvalidArbiter();
        if (config.format != TournamentFormat.ARENA_APERTA && config.bestiaryContract == address(0)) {
            revert InvalidBestiaryContract();
        }

        uint256 id = nextTournamentId++;

        Tournament storage t = tournaments[id];
        t.name = config.name;
        t.format = config.format;
        t.structure = config.structure;
        t.bestOf = config.bestOf;
        t.maxPlayers = config.maxPlayers;
        t.status = TournamentStatus.CREATED;
        t.organizer = msg.sender;
        t.arbiter = config.arbiter;
        t.bestiaryContract = config.bestiaryContract;

        emit TournamentCreated(id, config.name, config.format);
        return id;
    }

    // =====================================================================
    //  TOURNAMENT — Allocazione premi
    // =====================================================================

    /// @notice Alloca ETH dalla treasury a un torneo
    function allocateEthPrize(uint256 tournamentId, uint256 amount) external onlyRole(ORGANIZER_ROLE) {
        Tournament storage t = tournaments[tournamentId];
        _requireStatus(t, TournamentStatus.CREATED);
        if (amount == 0) revert ZeroAmount();

        uint256 available = treasuryEthBalance - treasuryEthAllocated;
        if (amount > available) revert InsufficientTreasuryEth();

        treasuryEthAllocated += amount;
        t.ethPrize += amount;

        emit EthPrizeAllocated(tournamentId, amount);
    }

    /// @notice Alloca un NFT specifico dalla treasury a un torneo
    function allocateNftPrize(uint256 tournamentId, address nftContract, uint256 tokenId) external onlyRole(ORGANIZER_ROLE) {
        Tournament storage t = tournaments[tournamentId];
        _requireStatus(t, TournamentStatus.CREATED);

        if (!treasuryNfts[nftContract][tokenId]) revert NftNotInTreasury();

        // H-02: set allocation BEFORE clearing treasury (atomic: NFT is always tracked)
        // +1 perché tournamentId 0 è valido, usiamo 0 come "non allocato"
        nftAllocatedToTournament[nftContract][tokenId] = tournamentId + 1;

        // Rimuovi dalla treasury disponibile (after allocation tracking is set)
        treasuryNfts[nftContract][tokenId] = false;
        treasuryNftCount--;

        // Aggiungi ai premi del torneo
        tournamentNftPrizes[tournamentId].push(NftPrize({
            nftContract: nftContract,
            tokenId: tokenId,
            placement: 0,
            claimed: false
        }));

        emit NftPrizeAllocated(tournamentId, nftContract, tokenId);
    }

    /// @notice Assegna NFT a posizioni specifiche (1° posto riceve NFT X, 2° riceve NFT Y, etc.)
    function assignNftToPlacement(uint256 tournamentId, uint256 nftIndex, uint8 placement) external onlyRole(ORGANIZER_ROLE) {
        Tournament storage t = tournaments[tournamentId];
        if (t.status != TournamentStatus.CREATED && t.status != TournamentStatus.REGISTRATION) {
            revert WrongStatus(TournamentStatus.CREATED, t.status);
        }

        NftPrize[] storage prizes = tournamentNftPrizes[tournamentId];
        if (nftIndex >= prizes.length) revert InvalidNftIndex();
        if (placement == 0) revert InvalidPlacement();

        prizes[nftIndex].placement = placement;

        // L-03: event per tracking off-chain
        emit NftAssignedToPlacement(tournamentId, nftIndex, placement);
    }

    /// @notice Setta lo split ETH per posizione (es. [5000, 3000, 1000, 500, 500] = 50/30/10/5/5%)
    function setPrizeSplit(uint256 tournamentId, uint16[] calldata splitBps) external onlyRole(ORGANIZER_ROLE) {
        Tournament storage t = tournaments[tournamentId];
        _requireStatus(t, TournamentStatus.CREATED);

        if (splitBps.length > MAX_PRIZE_SPLIT_ENTRIES) revert TooManySplitEntries();

        uint256 sum;
        for (uint256 i; i < splitBps.length; i++) {
            sum += splitBps[i];
        }
        if (sum != MAX_SPLIT_BPS) revert InvalidSplitSum();

        t.prizeSplitBps = splitBps;

        emit PrizeSplitSet(tournamentId, splitBps);
    }

    /// @notice Dealloca tutti i premi (solo se CREATED). Fondi tornano in treasury.
    function deallocatePrize(uint256 tournamentId) external onlyRole(ORGANIZER_ROLE) {
        Tournament storage t = tournaments[tournamentId];
        _requireStatus(t, TournamentStatus.CREATED);

        // Restituisci ETH alla treasury
        if (t.ethPrize > 0) {
            treasuryEthAllocated -= t.ethPrize;
            t.ethPrize = 0;
        }

        // Restituisci NFT alla treasury
        NftPrize[] storage nfts = tournamentNftPrizes[tournamentId];
        for (uint256 i; i < nfts.length; i++) {
            treasuryNfts[nfts[i].nftContract][nfts[i].tokenId] = true;
            treasuryNftCount++;
            nftAllocatedToTournament[nfts[i].nftContract][nfts[i].tokenId] = 0; // H-02
        }
        delete tournamentNftPrizes[tournamentId];
        delete t.prizeSplitBps;

        emit PrizeDeallocated(tournamentId);
    }

    // =====================================================================
    //  TOURNAMENT — Lifecycle
    // =====================================================================

    /// @notice Apre le iscrizioni: CREATED → REGISTRATION
    function openRegistration(uint256 tournamentId) external onlyRole(ORGANIZER_ROLE) {
        Tournament storage t = tournaments[tournamentId];
        _requireStatus(t, TournamentStatus.CREATED);
        t.status = TournamentStatus.REGISTRATION;
        emit RegistrationOpened(tournamentId);
    }

    /// @notice Avvia il torneo: REGISTRATION → IN_PROGRESS
    function startTournament(uint256 tournamentId) external onlyRole(ORGANIZER_ROLE) {
        Tournament storage t = tournaments[tournamentId];
        _requireStatus(t, TournamentStatus.REGISTRATION);
        if (t.registeredCount < 2) revert NeedMinimumPlayers();
        t.status = TournamentStatus.IN_PROGRESS;
        t.startTime = uint64(block.timestamp);
        t.resultsDeadline = uint64(block.timestamp) + DEFAULT_RESULTS_PERIOD; // M-04
        emit TournamentStarted(tournamentId);
    }

    /// @notice Annulla il torneo. Fondi tornano in treasury. Carte sbloccabili dai player.
    /// @dev H-01: unlock rimosso dal lifecycle. I player usano selfUnlock() dopo cancellazione.
    ///      M-04: IN_PROGRESS cancellation only allowed after resultsDeadline has passed.
    function cancelTournament(uint256 tournamentId) external onlyRole(ORGANIZER_ROLE) nonReentrant {
        Tournament storage t = tournaments[tournamentId];
        if (t.status != TournamentStatus.CREATED &&
            t.status != TournamentStatus.REGISTRATION &&
            t.status != TournamentStatus.IN_PROGRESS) {
            revert CannotCancelInStatus();
        }
        // M-04: if IN_PROGRESS, only allow cancellation after results deadline has passed
        if (t.status == TournamentStatus.IN_PROGRESS) {
            if (t.resultsDeadline == 0 || block.timestamp < t.resultsDeadline) {
                revert ResultsDeadlineNotReached();
            }
        }

        // Restituisci ETH alla treasury
        if (t.ethPrize > 0) {
            treasuryEthAllocated -= t.ethPrize;
            t.ethPrize = 0;
        }

        // Restituisci NFT alla treasury + clear H-02 tracking
        _returnNftsToTreasury(tournamentId);

        t.status = TournamentStatus.CLOSED;
        t.endTime = uint64(block.timestamp);

        emit TournamentCancelled(tournamentId);
    }

    // =====================================================================
    //  PLAYER — Registrazione
    // =====================================================================

    /// @notice Registrazione semplice (Arena Aperta — nessun lock)
    function register(uint256 tournamentId) external whenNotPaused {
        Tournament storage t = tournaments[tournamentId];
        _requireStatus(t, TournamentStatus.REGISTRATION);
        if (t.format != TournamentFormat.ARENA_APERTA) revert LockNotRequired();
        _registerPlayer(tournamentId, t);
    }

    /// @notice Registrazione con lock carte (Conquista / Sigillo d'Oro)
    function registerWithLock(uint256 tournamentId, uint256[] calldata tokenIds) external whenNotPaused nonReentrant {
        Tournament storage t = tournaments[tournamentId];
        _requireStatus(t, TournamentStatus.REGISTRATION);

        if (t.format == TournamentFormat.ARENA_APERTA) revert LockNotRequired();

        // Verifica numero carte corretto
        uint8 required = t.format == TournamentFormat.CONQUISTA
            ? MAX_LOCK_CARDS_CONQUISTA
            : MAX_LOCK_CARDS_SIGILLO;
        if (tokenIds.length != required) revert InvalidTokenCount();

        // Sigillo d'Oro: verifica invito
        if (t.format == TournamentFormat.SIGILLO_ORO && !isInvited[tournamentId][msg.sender]) {
            revert NotInvited();
        }

        // Verifica ownership delle carte
        IBestiaryV4 bestiary = IBestiaryV4(t.bestiaryContract);
        for (uint256 i; i < tokenIds.length; i++) {
            if (bestiary.ownerOf(tokenIds[i]) != msg.sender) revert TokenNotOwned();
        }

        // Lock carte on-chain
        bestiary.setTokenLock(tokenIds, true);

        // Traccia token lockati per unlock futuro
        lockedTokens[tournamentId][msg.sender] = tokenIds;
        lockPlayers[tournamentId].push(msg.sender);

        // Registra giocatore
        _registerPlayer(tournamentId, t);

        emit PlayerRegisteredWithLock(tournamentId, msg.sender, tokenIds.length);
    }

    /// @notice Invita un giocatore a un torneo Sigillo d'Oro
    function invitePlayer(uint256 tournamentId, address player) external onlyRole(ORGANIZER_ROLE) {
        if (player == address(0)) revert ZeroAddress(); // L-04
        Tournament storage t = tournaments[tournamentId];
        if (t.format != TournamentFormat.SIGILLO_ORO) revert NotSigilloOro();
        if (t.status != TournamentStatus.CREATED && t.status != TournamentStatus.REGISTRATION) {
            revert CannotInviteInStatus();
        }
        isInvited[tournamentId][player] = true;
        emit PlayerInvited(tournamentId, player);
    }

    /// @notice Invita batch di giocatori
    function invitePlayers(uint256 tournamentId, address[] calldata players) external onlyRole(ORGANIZER_ROLE) {
        Tournament storage t = tournaments[tournamentId];
        if (t.format != TournamentFormat.SIGILLO_ORO) revert NotSigilloOro();
        if (t.status != TournamentStatus.CREATED && t.status != TournamentStatus.REGISTRATION) {
            revert CannotInviteInStatus();
        }
        for (uint256 i; i < players.length; i++) {
            if (players[i] == address(0)) revert ZeroAddress(); // L-04
            isInvited[tournamentId][players[i]] = true;
            emit PlayerInvited(tournamentId, players[i]);
        }
    }

    // =====================================================================
    //  ARBITER — Risultati
    // =====================================================================

    /// @notice Submitta i piazzamenti finali e il Merkle root dei match log
    /// @param tournamentId ID del torneo
    /// @param winners Array di indirizzi ordinato per posizione (index 0 = 1° posto)
    /// @param matchLogsRoot Merkle root di tutti i match log hash
    function submitResults(
        uint256 tournamentId,
        address[] calldata winners,
        bytes32 matchLogsRoot
    ) external whenNotPaused {
        Tournament storage t = tournaments[tournamentId];
        _requireStatus(t, TournamentStatus.IN_PROGRESS);
        if (msg.sender != t.arbiter && !hasRole(ORGANIZER_ROLE, msg.sender)) revert NotArbiterOrOrganizer();
        // M-04: enforce results deadline — after expiry, tournament must be cancelled
        if (t.resultsDeadline != 0 && block.timestamp > t.resultsDeadline) revert ResultsDeadlineExpired();
        if (t.matchLogsRoot != bytes32(0)) revert ResultsAlreadySubmitted();
        if (winners.length > t.registeredCount) revert PlacementsExceedRegistered();
        // F-10: cap esplicito per proteggere da gas DoS sul loop O(n²) duplicati
        if (winners.length > MAX_PRIZE_SPLIT_ENTRIES) revert TooManySplitEntries();
        // M-01: explicit overflow guard before uint16 cast (defense-in-depth)
        if (winners.length > type(uint16).max) revert TooManySplitEntries();

        t.matchLogsRoot = matchLogsRoot;

        for (uint256 i; i < winners.length; i++) {
            if (!isRegistered[tournamentId][winners[i]]) revert WinnerNotRegistered();
            // M-01: verifica unicità — il piazzamento per questa posizione deve essere vuoto
            if (placements[tournamentId][uint16(i + 1)] != address(0)) revert DuplicateWinner();
            // Verifica che questo indirizzo non sia già stato piazzato in una posizione precedente
            for (uint256 j; j < i; j++) {
                if (winners[j] == winners[i]) revert DuplicateWinner();
            }
            placements[tournamentId][uint16(i + 1)] = winners[i]; // 1-indexed
        }
        placementCount[tournamentId] = uint16(winners.length); // L-02: uint16

        t.status = TournamentStatus.FINALIZED;
        t.endTime = uint64(block.timestamp);

        emit ResultsSubmitted(tournamentId, matchLogsRoot, uint8(winners.length)); // safe: capped at MAX_PRIZE_SPLIT_ENTRIES (32)
    }

    /// @notice Abilita i claims: FINALIZED → CLAIMABLE
    /// @dev H-01: unlock NON avviene qui per evitare gas DoS. I player usano selfUnlock().
    ///      M-02: revert se prizeSplitBps non copre tutti i piazzamenti (vincitori senza premio ETH)
    function enableClaims(uint256 tournamentId) external onlyRole(ORGANIZER_ROLE) whenNotPaused {
        Tournament storage t = tournaments[tournamentId];
        _requireStatus(t, TournamentStatus.FINALIZED);

        // M-02: verify prizeSplitBps covers all placements (if ETH prize exists)
        if (t.ethPrize > 0 && t.prizeSplitBps.length < placementCount[tournamentId]) {
            revert PrizeSplitTooShort();
        }

        t.status = TournamentStatus.CLAIMABLE;
        t.claimDeadline = uint64(block.timestamp) + DEFAULT_CLAIM_PERIOD;

        emit ClaimsEnabled(tournamentId, t.claimDeadline);
    }

    /// @notice [H-01] Ogni player sblocca le proprie carte — nessun gas DoS possibile.
    ///         Chiamabile SOLO dopo che il torneo ha superato IN_PROGRESS (FINALIZED, CLAIMABLE, CLOSED).
    ///         CREATED/REGISTRATION sono bloccati: un player potrebbe sbloccare carte e restare iscritto.
    ///         Per tornei mai avviati → organizer chiama cancelTournament() → status diventa CLOSED → selfUnlock ok.
    function selfUnlock(uint256 tournamentId) external nonReentrant {
        Tournament storage t = tournaments[tournamentId];
        if (uint8(t.status) <= uint8(TournamentStatus.IN_PROGRESS)) {
            revert TournamentStillInProgress();
        }
        if (t.bestiaryContract == address(0)) revert InvalidBestiaryContract();

        uint256[] storage tokens = lockedTokens[tournamentId][msg.sender];
        if (tokens.length == 0) revert NoLockedTokens();

        IBestiaryV4(t.bestiaryContract).setTokenLock(tokens, false);
        emit TokensUnlocked(tournamentId, msg.sender, tokens.length);
        delete lockedTokens[tournamentId][msg.sender];
    }

    /// @notice [H-01] Batch unlock di emergenza — organizer sblocca per conto dei player a lotti.
    ///         Utile se un player non chiama selfUnlock. Permesso SOLO dopo IN_PROGRESS
    ///         (FINALIZED, CLAIMABLE, CLOSED). Per tornei abbandonati → cancelTournament() prima.
    function unlockBatch(uint256 tournamentId, uint256 startIdx, uint256 count) external onlyRole(ORGANIZER_ROLE) nonReentrant {
        Tournament storage t = tournaments[tournamentId];
        if (uint8(t.status) <= uint8(TournamentStatus.IN_PROGRESS)) {
            revert TournamentStillInProgress();
        }
        if (t.bestiaryContract == address(0)) revert InvalidBestiaryContract();

        address[] storage players = lockPlayers[tournamentId];
        IBestiaryV4 bestiary = IBestiaryV4(t.bestiaryContract);

        uint256 end = startIdx + count;
        if (end > players.length) end = players.length;

        for (uint256 i = startIdx; i < end; i++) {
            uint256[] storage tokens = lockedTokens[tournamentId][players[i]];
            if (tokens.length > 0) {
                bestiary.setTokenLock(tokens, false);
                emit TokensUnlocked(tournamentId, players[i], tokens.length);
                delete lockedTokens[tournamentId][players[i]];
            }
        }
    }

    // =====================================================================
    //  PLAYER — Claims
    // =====================================================================

    /// @notice Vincitore claima il proprio premio (ETH + NFT assegnati alla sua posizione)
    function claimPrize(uint256 tournamentId) external nonReentrant whenNotPaused {
        Tournament storage t = tournaments[tournamentId];
        _requireStatus(t, TournamentStatus.CLAIMABLE);
        if (hasClaimed[tournamentId][msg.sender]) revert AlreadyClaimed();

        // Trova la posizione del chiamante (L-02: uint16)
        uint16 position = _getPlacement(tournamentId, msg.sender);
        if (position == 0) revert NoPlacement();

        hasClaimed[tournamentId][msg.sender] = true;

        // Calcola ETH spettante
        // NOTA: integer division può lasciare rounding dust (wei). Il dust viene
        // recuperato in closeTournament tramite unclaimedEth = ethPrize - ethClaimed.
        uint256 ethAmount;
        if (t.ethPrize > 0 && t.prizeSplitBps.length >= position) {
            ethAmount = (t.ethPrize * t.prizeSplitBps[position - 1]) / MAX_SPLIT_BPS;
        }

        // Trasferisci ETH
        if (ethAmount > 0) {
            t.ethClaimed += ethAmount;
            treasuryEthAllocated -= ethAmount;
            treasuryEthBalance -= ethAmount;

            (bool success,) = msg.sender.call{value: ethAmount}("");
            if (!success) revert EthTransferFailed();

            emit PrizeClaimed(tournamentId, msg.sender, position, ethAmount);
        }

        // Trasferisci NFT assegnati a questa posizione
        NftPrize[] storage nfts = tournamentNftPrizes[tournamentId];
        for (uint256 i; i < nfts.length; i++) {
            // M-03: safe cast — position is always <= MAX_PRIZE_SPLIT_ENTRIES (32)
            if (nfts[i].placement == uint8(position) && !nfts[i].claimed) {
                nfts[i].claimed = true;
                nftAllocatedToTournament[nfts[i].nftContract][nfts[i].tokenId] = 0; // H-02: clear
                IERC721(nfts[i].nftContract).safeTransferFrom(
                    address(this),
                    msg.sender,
                    nfts[i].tokenId
                );
                emit NftPrizeClaimed(tournamentId, msg.sender, nfts[i].nftContract, nfts[i].tokenId);
            }
        }

        // Auto-unlock locked tokens after claim (H-01: always unlock if tokens exist;
        // bestiaryContract is guaranteed non-zero if playerTokens.length > 0 because
        // registerWithLock() enforces format != ARENA_APERTA → bestiaryContract != address(0))
        uint256[] storage playerTokens = lockedTokens[tournamentId][msg.sender];
        if (playerTokens.length > 0) {
            IBestiaryV4(t.bestiaryContract).setTokenLock(playerTokens, false);
            emit TokensUnlocked(tournamentId, msg.sender, playerTokens.length);
            delete lockedTokens[tournamentId][msg.sender];
        }
    }

    // =====================================================================
    //  TOURNAMENT — Chiusura
    // =====================================================================

    /// @notice Chiude il torneo dopo il claim period. Fondi non claimati tornano in treasury.
    function closeTournament(uint256 tournamentId) external onlyRole(ORGANIZER_ROLE) nonReentrant {
        Tournament storage t = tournaments[tournamentId];
        _requireStatus(t, TournamentStatus.CLAIMABLE);
        if (block.timestamp < t.claimDeadline) revert ClaimDeadlineNotReached();

        // ETH non claimato torna in treasury (disponibile per altri tornei)
        // NOTA: t.ethPrize e t.ethClaimed NON vengono azzerati intenzionalmente — restano
        // come storico on-chain. Il guard TournamentAlreadyClosed su emergencyWithdraw
        // impedisce il double-dipping su tornei CLOSED.
        uint256 unclaimedEth = t.ethPrize - t.ethClaimed;
        if (unclaimedEth > 0) {
            treasuryEthAllocated -= unclaimedEth;
            // treasuryEthBalance resta invariato — l'ETH è ancora nel contratto
        }

        // NFT non claimati tornano in treasury + clear H-02 tracking
        NftPrize[] storage nfts = tournamentNftPrizes[tournamentId];
        for (uint256 i; i < nfts.length; i++) {
            nftAllocatedToTournament[nfts[i].nftContract][nfts[i].tokenId] = 0; // H-02
            if (!nfts[i].claimed) {
                treasuryNfts[nfts[i].nftContract][nfts[i].tokenId] = true;
                treasuryNftCount++;
            }
        }
        delete tournamentNftPrizes[tournamentId]; // F-02: pulizia storage, gas refund

        t.status = TournamentStatus.CLOSED;

        emit TournamentClosed(tournamentId, unclaimedEth);
    }

    // =====================================================================
    //  EMERGENCY
    // =====================================================================

    /// @notice Prelievo di emergenza — evacua fondi FUORI dal contratto verso un wallet sicuro
    /// @dev A differenza di cancelTournament (che rimette in treasury interna), questa funzione
    ///      trasferisce fisicamente ETH e NFT all'indirizzo `to`. Usare se il contratto è compromesso.
    ///      H-01: unlock NON avviene qui. Player usano selfUnlock() o admin usa unlockBatch().
    function emergencyWithdraw(uint256 tournamentId, address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        Tournament storage t = tournaments[tournamentId];
        if (t.status == TournamentStatus.CLOSED) revert TournamentAlreadyClosed();

        // Evacua ETH residuo verso il wallet sicuro (NON treasury interna)
        uint256 evacuatedEth;
        if (t.ethPrize > 0) {
            uint256 remaining = t.ethPrize - t.ethClaimed;
            if (remaining > 0) {
                evacuatedEth = remaining;
                treasuryEthAllocated -= remaining;
                treasuryEthBalance -= remaining;
                (bool success, ) = to.call{value: remaining}("");
                if (!success) revert EthTransferFailed();
                emit TreasuryEthWithdrawn(to, remaining);
            }
            t.ethPrize = 0;
        }

        // Evacua NFT non claimed verso il wallet sicuro (NON treasury interna)
        uint256 evacuatedNfts = _evacuateNftsTo(tournamentId, to);

        t.status = TournamentStatus.CLOSED;
        t.endTime = uint64(block.timestamp);

        // F-08: evento dedicato per monitoring/alerting off-chain
        emit EmergencyEvacuated(tournamentId, to, evacuatedEth, evacuatedNfts);
    }

    /// @notice Pausa globale
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Riprendi
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // =====================================================================
    //  VIEW FUNCTIONS
    // =====================================================================

    /// @notice Ritorna lo stato di un torneo
    function getTournamentStatus(uint256 tournamentId) external view returns (TournamentStatus) {
        return tournaments[tournamentId].status;
    }

    /// @notice Ritorna i premi NFT di un torneo
    function getTournamentNftPrizes(uint256 tournamentId) external view returns (NftPrize[] memory) {
        return tournamentNftPrizes[tournamentId];
    }

    /// @notice Ritorna lo split dei premi
    function getPrizeSplit(uint256 tournamentId) external view returns (uint16[] memory) {
        return tournaments[tournamentId].prizeSplitBps;
    }

    /// @notice ETH disponibile in treasury (non allocato)
    function treasuryAvailableEth() external view returns (uint256) {
        return treasuryEthBalance - treasuryEthAllocated;
    }

    /// @notice Ritorna la posizione di un giocatore in un torneo (0 = non piazzato)
    function getPlacement(uint256 tournamentId, address player) external view returns (uint16) {
        return _getPlacement(tournamentId, player);
    }

    /// @notice Ritorna i token lockati di un giocatore
    function getLockedTokens(uint256 tournamentId, address player) external view returns (uint256[] memory) {
        return lockedTokens[tournamentId][player];
    }

    /// @notice Numero di giocatori che hanno lockato carte
    function getLockPlayersCount(uint256 tournamentId) external view returns (uint256) {
        return lockPlayers[tournamentId].length;
    }

    // =====================================================================
    //  INTERNAL
    // =====================================================================

    function _requireStatus(Tournament storage t, TournamentStatus expected) internal view {
        if (t.status != expected) revert WrongStatus(expected, t.status);
    }

    function _registerPlayer(uint256 tournamentId, Tournament storage t) internal {
        if (isRegistered[tournamentId][msg.sender]) revert AlreadyRegistered();
        if (t.maxPlayers > 0 && t.registeredCount >= t.maxPlayers) revert MaxPlayersReached();

        isRegistered[tournamentId][msg.sender] = true;
        t.registeredCount++;

        emit PlayerRegistered(tournamentId, msg.sender);
    }

    /// @dev O(n) linear scan. Accettabile perché placementCount è cappato a MAX_PRIZE_SPLIT_ENTRIES (32).
    ///      Il costo gas è pagato dal claimant, non dal contratto.
    function _getPlacement(uint256 tournamentId, address player) internal view returns (uint16) {
        uint16 count = placementCount[tournamentId];
        for (uint16 i = 1; i <= count; i++) {
            if (placements[tournamentId][i] == player) return i;
        }
        return 0;
    }

    /// @dev Restituisce NFT alla treasury interna + clear H-02 tracking. Usata da cancelTournament.
    function _returnNftsToTreasury(uint256 tournamentId) internal {
        NftPrize[] storage nfts = tournamentNftPrizes[tournamentId];
        for (uint256 i; i < nfts.length; i++) {
            nftAllocatedToTournament[nfts[i].nftContract][nfts[i].tokenId] = 0;
            if (!nfts[i].claimed) {
                treasuryNfts[nfts[i].nftContract][nfts[i].tokenId] = true;
                treasuryNftCount++;
            }
        }
        delete tournamentNftPrizes[tournamentId];
    }

    /// @dev Evacua NFT non claimed FUORI dal contratto verso un indirizzo esterno.
    ///      Usata SOLO da emergencyWithdraw — trasferisce fisicamente via safeTransferFrom.
    ///      NOTA: Non modifica treasuryNftCount perché gli NFT allocati a un torneo NON sono
    ///      nella treasury (treasuryNfts[]=false dal momento di allocateNftPrize).
    ///      treasuryNftCount riflette solo NFT liberi in treasury, non il totale nel contratto.
    function _evacuateNftsTo(uint256 tournamentId, address to) internal returns (uint256 count) {
        NftPrize[] storage nfts = tournamentNftPrizes[tournamentId];
        for (uint256 i; i < nfts.length; i++) {
            nftAllocatedToTournament[nfts[i].nftContract][nfts[i].tokenId] = 0;
            if (!nfts[i].claimed) {
                IERC721(nfts[i].nftContract).safeTransferFrom(address(this), to, nfts[i].tokenId);
                emit TreasuryNftWithdrawn(to, nfts[i].nftContract, nfts[i].tokenId);
                count++;
            }
        }
        delete tournamentNftPrizes[tournamentId];
    }

    /// @notice Verifica se il contratto supporta un'interfaccia (AccessControl + ERC721Receiver)
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return interfaceId == type(IERC721Receiver).interfaceId || super.supportsInterface(interfaceId);
    }
}
