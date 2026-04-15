// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721C} from "./ERC721C.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

interface ISatoshiBestiary {
    function burn(uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function batchBurnFrom(address tokenOwner, uint256[] calldata tokenIds) external; // GAS-OPT
}

/**
 * @dev Interfaccia minima per il VRF Coordinator V2 Plus.
 *      Non ereditiamo VRFConsumerBaseV2Plus per evitare il conflitto
 *      ConfirmedOwner (Chainlink) vs Ownable (OpenZeppelin).
 */
interface IVRFCoordinatorV2Plus {
    function requestRandomWords(
        VRFV2PlusClient.RandomWordsRequest calldata req
    ) external returns (uint256 requestId);
}

/**
 * @title SatoshiForgeV4 — Template Parametrico
 * @notice Identico a V3 nella logica, ma con supply/range/forging parameters configurabili via constructor.
 *         Permette di deployare collection diverse con lo stesso contratto auditato.
 *
 * @dev Cambiamenti rispetto a V3:
 *      - Le costanti (MAX_RARE_FORGED, MAX_EPIC_FORGED, etc.) sono ora `immutable`
 *      - Constructor accetta struct ForgeParams + VRFParams
 *      - Tutta la logica (Forge, Sigillo, VRF, Refund) è IDENTICA a V3
 *
 *      INVARIANTI MANTENUTI:
 *      - 7 tipi forgiati (Rare, Epic, Legendary, MythicForged, MythicShard, APEX, Reliquia)
 *      - Sigillo dei Tipi Forgiati (reveal/seal per tipo, Sigillo Nero)
 *      - ERC-721C (Limit Break) + ERC-2981 royalties
 *      - VRF per Shard, deterministico per MythicForged
 *      - "Buco Nero" VRF protection (retry + refund)
 *      - God Mode (batchBurnFrom dal Bestiary)
 *      - Pausable
 */

contract SatoshiForgeV4 is ERC721C, ERC2981, Ownable, ReentrancyGuard, Pausable {
    using Strings for uint256;
    ISatoshiBestiary public bestiaryContract;

    // "Il Sigillo delle Fucine": una volta chiamato lockContracts(), l'indirizzo
    // del Bestiary è congelato per sempre. ZERO rischio rugpull.
    bool public contractsLocked = false;

    // =====================================================================
    //  FORGE PARAMS — Struct per constructor
    // =====================================================================

    struct ForgeParams {
        uint256 maxRareForged;
        uint256 maxEpicForged;
        uint256 maxLegendaryForged;
        uint256 maxMythicForged;
        uint256 maxReliquia;
        uint256 maxMythicShard;
        uint256 maxApex;
        uint256 mythicForgedStartId;     // base ID per MythicForged
        uint256 legendaryForgedStartId;
        uint256 epicForgedStartId;
        uint256 rareForgedStartId;
        uint256 mythicShardStartId;
        uint256 apexStartId;
        uint256 reliquiaStartId;
        uint256 rareForgedSpecies;       // es. 13
        uint256 epicForgedSpecies;       // es. 10
        uint256 legendaryForgedSpecies;  // es. 7
        uint256 mythicForgedSpecies;     // es. 2
        uint256 bestiaryCommonStart;     // start ID di common (es. 7351)
        uint256 bestiaryCommonEnd;       // end ID di common (es. 21000)
        uint256 bestiaryRareStart;       // start ID di rare (es. 3151)
        uint256 bestiaryRareEnd;         // end ID di rare (es. 7350)
        uint256 bestiaryEpicStart;       // start ID di epic (es. 1051)
        uint256 bestiaryEpicEnd;         // end ID di epic (es. 3150)
        uint256 bestiaryLegendaryStart;  // start ID di legendary (es. 22)
        uint256 bestiaryLegendaryEnd;    // end ID di legendary (es. 1050)
    }

    struct VRFParams {
        uint256 subscriptionId;
        address vrfCoordinator;
        bytes32 keyHash;
        string notRevealedURI;
    }

    // =====================================================================
    //  IMMUTABLE COLLECTION CONFIG — 0 gas read, set once in constructor
    // =====================================================================

    uint256 public immutable maxRareForged;
    uint256 public immutable maxEpicForged;
    uint256 public immutable maxLegendaryForged;
    uint256 public immutable maxMythicForged;
    uint256 public immutable maxReliquia;
    uint256 public immutable maxMythicShard;
    uint256 public immutable maxApex;

    // Start IDs per ogni forged type
    uint256 public immutable mythicForgedStartId;
    uint256 public immutable legendaryForgedStartId;
    uint256 public immutable epicForgedStartId;
    uint256 public immutable rareForgedStartId;
    uint256 public immutable mythicShardStartId;
    uint256 public immutable apexStartId;
    uint256 public immutable reliquiaStartId;

    // Base IDs (startId - 1)
    uint256 private immutable _mythicForgedBase;
    uint256 private immutable _legendaryForgedBase;
    uint256 private immutable _epicForgedBase;
    uint256 private immutable _rareForgedBase;
    uint256 private immutable _mythicShardBase;
    uint256 private immutable _apexBase;
    uint256 private immutable _reliquiaBase;

    // Species count per forged type
    uint256 public immutable rareForgedSpecies;
    uint256 public immutable epicForgedSpecies;
    uint256 public immutable legendaryForgedSpecies;
    uint256 public immutable mythicForgedSpecies;
    uint8 public immutable totalForgedTypes;

    // Bestiary tier boundaries
    uint256 public immutable bestiaryCommonStart;
    uint256 public immutable bestiaryCommonEnd;
    uint256 public immutable bestiaryRareStart;
    uint256 public immutable bestiaryRareEnd;
    uint256 public immutable bestiaryEpicStart;
    uint256 public immutable bestiaryEpicEnd;
    uint256 public immutable bestiaryLegendaryStart;
    uint256 public immutable bestiaryLegendaryEnd;

    // Hardcoded forge step requirements (identici a V3)
    uint256 public immutable rareInputCount = 20;       // 20 Common → 1 RareForged
    uint256 public immutable epicInputCount = 10;       // 10 Rare → 1 EpicForged
    uint256 public immutable legendaryInputCount = 5;   // 5 Epic → 1 LegendaryForged
    uint256 public immutable reliquiaInputCount = 7;    // 7 Legendary → 1 Reliquia

    // --- FORGE FEE & STEP CONTROL ---
    mapping(uint256 => uint256) public forgeFee;
    mapping(uint256 => bool) public forgeStepActive;

    // --- SIGILLO DEI TIPI FORGIATI ---
    // 7 tipi forgiati + speciali. Ogni tipo ha: URI, stato reveal, stato sigillo.
    mapping(uint8 => string) public forgedTypeURI;
    mapping(uint8 => bool) public forgedTypeRevealed;
    mapping(uint8 => bool) public forgedTypeSealed;
    uint8 public sealedCount;
    bool public sigilloNero;
    string public notRevealedURI;

    // --- FORGE COUNTERS & SUPPLY ---
    uint256 public rareForgedCount;
    uint256 public epicForgedCount;
    uint256 public legendaryForgedCount;
    uint256 public mythicForgedCount;
    uint256 public mythicShardCount;
    uint256 public apexCount;
    uint256 public reliquiaCount;

    mapping(uint256 => bool) public isReliquia;
    mapping(uint256 => uint256) public forgedSpeciesId;

    // --- MYTHIC SHARD POOL & VRF ---
    enum ShardType { IGNIS, FULMEN, UMBRA }

    struct ShardForgeRequest {
        address forger;
        bool fulfilled;
        uint256 shardTokenId;
        uint256 mythicForgedId1;
        uint256 mythicForgedId2;
        uint256 requestBlock;
        uint256 feePaid;
    }

    uint256[] private _availableShardIds;
    mapping(uint256 => ShardForgeRequest) private _shardRequests;
    mapping(uint256 => ShardType) public shardTypes;
    mapping(uint256 => bool) public shardUsedForApex;
    mapping(uint256 => bool) private _requestProcessed;
    uint256 public pendingShardRequests;

    uint256 public ignisShardCount;
    uint256 public fulmenShardCount;
    uint256 public umbraShardCount;

    uint256[] private _pendingShardRequestIds;

    // --- VRF COORDINATOR ---
    IVRFCoordinatorV2Plus public vrfCoordinator;
    uint256 public vrfSubscriptionId;
    bytes32 public vrfKeyHash;
    uint32 public shardCallbackGasLimit = 3_000_000;
    uint16 public shardRequestConfirmations = 3;
    bool public vrfNativePayment = true;

    // --- FEE MANAGEMENT ---
    uint256 public lockedForgeFees;
    mapping(address => uint256) public pendingRefunds;  // Failed push refunds — claimable by user
    uint256 public totalPendingRefunds;                 // Sum of all pendingRefunds (for safe withdraw)

    // --- VRF TIMEOUT (blocks) ---
    uint256 public constant VRF_TIMEOUT = 256;

    // --- TOURNAMENT LOCK — F0 ---
    address public tournamentContract;
    mapping(uint256 => bool) public tokenLocked;

    string private constant JSON_EXT = ".json";

    // =====================================================================
    //  CUSTOM ERRORS
    // =====================================================================

    error IncorrectTokenCount(uint256 expected, uint256 actual);
    error InvalidTokenTier(uint256 tokenId);
    error InvalidConfig();
    error NotRareForged(uint256 tokenId);
    error NotEpicForged(uint256 tokenId);
    error NotLegendaryForged(uint256 tokenId);
    error NotForgedToken(uint256 tokenId);
    error NotTokenOwner(uint256 tokenId);
    error MaxSupplyExceeded();
    error ReliquiaMaxSupplyExceeded();
    error ReliquiaNotFound(uint256 tokenId);
    error NotReliquiaOwner(uint256 tokenId);
    error RecipientDoesNotHaveAllShards();
    error InvalidForgedTypeId();
    error ForgedTypeAlreadyRevealed();
    error ForgedTypeNotRevealed();
    error ForgedTypeAlreadySealed();
    error ForgedTypeURISealed();
    error EmptyURI();
    error ForgeStepNotActive(uint256 step);
    error IncorrectForgePayment(uint256 expected, uint256 actual);
    error VRFCoordinatorNotSet();
    error OnlyVRFCoordinator();
    error InvalidShardVRFRequest();
    error DuplicateShardCallback();
    error ShardRequestNotFound();
    error NotRequestForger();
    error RequestAlreadyFulfilled();
    error RequestNotTimedOut();
    error RefundETHFailed();
    error SigilloNeroAlreadyDone();
    error SigilloNeroURIMissing(uint8 speciesId);
    error BestiaryContractNotSet();
    error ContractsAlreadyLocked();
    error OnlyOwner();
    error URINotSet();
    // F0 — Tournament Lock errors
    error TokenLocked(uint256 tokenId);
    error NotTournamentContract();
    error InvalidTournamentAddress();
    error NoTokensProvided();
    // H-03 — claimApex O(1) errors
    error NotOwnerOfToken(uint256 tokenId);
    error ShardAlreadyUsed(uint256 tokenId);
    error WrongShardType(uint256 tokenId);
    // Minor — fee cap
    error ForgeFeeTooHigh();

    // =====================================================================
    //  EVENTS
    // =====================================================================

    event RareForged(address indexed forger, uint256 tokenId);
    event EpicForged(address indexed forger, uint256 tokenId);
    event LegendaryForged(address indexed forger, uint256 tokenId);
    event ReliquiaForged(address indexed forger, uint256 tokenId, uint256[] inputTokenIds);
    event MythicForgedMinted(address indexed forger, uint256 tokenId);
    event ShardForgeRequested(address indexed forger, uint256 requestId, uint256 shardTokenId);
    event ShardForgeRetried(uint256 oldRequestId, uint256 newRequestId, address forger);
    event ShardForgeFulfilled(uint256 requestId, uint256 shardTokenId, ShardType shardType);
    event ShardForgeRefunded(uint256 requestId, address forger, uint256 mythicId1, uint256 mythicId2);
    event ShardRefundETHFailed(uint256 requestId, address forger, uint256 amount);
    event RefundCredited(address indexed forger, uint256 amount);
    event RefundClaimed(address indexed forger, uint256 amount);
    event MythicShardForged(address indexed forger, uint256 shardTokenId, ShardType shardType);
    event ApexAwarded(address indexed forger, uint256 apexTokenId, uint256 ignisId, uint256 fulmenId, uint256 umbraId);
    event ForgedSpeciesAssigned(uint256 tokenId, uint256 species);
    event ForgedTypeRevealed(uint8 forgedTypeId);
    event ForgedTypeSealed(uint8 forgedTypeId, uint8 sealedCount);
    event SigilloNeroEvent();
    event ForgeFeesWithdrawn(uint256 amount);
    event NotRevealedURIUpdated(string uri);
    event ContractsLocked();
    // F0 — Tournament Lock events
    event TokensLocked(uint256[] tokenIds, address indexed byContract);
    event TokensUnlocked(uint256[] tokenIds, address indexed byContract);
    event TournamentContractUpdated(address indexed oldAddr, address indexed newAddr);
    event BestiaryContractUpdated(address indexed oldAddr, address indexed newAddr);

    // =====================================================================
    //  CONSTRUCTOR
    // =====================================================================

    constructor(
        string memory name,
        string memory symbol,
        address bestiaryAddr,
        ForgeParams memory forgeParams,
        VRFParams memory vrfParams,
        uint96 royaltyBps
    ) ERC721C(name, symbol) Ownable(msg.sender) {
        if (bestiaryAddr == address(0)) revert BestiaryContractNotSet();

        // Validazioni parametri forge
        if (forgeParams.maxRareForged == 0) revert InvalidConfig();
        if (forgeParams.maxEpicForged == 0) revert InvalidConfig();
        if (forgeParams.maxLegendaryForged == 0) revert InvalidConfig();
        if (forgeParams.maxMythicForged == 0) revert InvalidConfig();
        if (forgeParams.maxReliquia == 0) revert InvalidConfig();
        if (forgeParams.maxMythicShard == 0) revert InvalidConfig();
        if (forgeParams.maxMythicShard % 3 != 0) revert InvalidConfig();
        if (forgeParams.maxApex == 0) revert InvalidConfig();

        // Validazioni boundary monotonic — ordine crescente dei startIds:
        // mythicForged < legendary < epic < rare < mythicShard < apex < reliquia
        if (forgeParams.mythicForgedStartId == 0) revert InvalidConfig();
        if (forgeParams.legendaryForgedStartId <= forgeParams.mythicForgedStartId) revert InvalidConfig();
        if (forgeParams.epicForgedStartId <= forgeParams.legendaryForgedStartId) revert InvalidConfig();
        if (forgeParams.rareForgedStartId <= forgeParams.epicForgedStartId) revert InvalidConfig();
        if (forgeParams.mythicShardStartId <= forgeParams.rareForgedStartId) revert InvalidConfig();
        if (forgeParams.apexStartId <= forgeParams.mythicShardStartId) revert InvalidConfig();
        if (forgeParams.reliquiaStartId <= forgeParams.apexStartId) revert InvalidConfig();

        // Validazioni bestiary tier boundaries
        if (forgeParams.bestiaryLegendaryStart == 0 || forgeParams.bestiaryLegendaryStart > forgeParams.bestiaryLegendaryEnd) revert InvalidConfig();
        if (forgeParams.bestiaryEpicStart == 0 || forgeParams.bestiaryEpicStart > forgeParams.bestiaryEpicEnd) revert InvalidConfig();
        if (forgeParams.bestiaryRareStart == 0 || forgeParams.bestiaryRareStart > forgeParams.bestiaryRareEnd) revert InvalidConfig();
        if (forgeParams.bestiaryCommonStart == 0 || forgeParams.bestiaryCommonStart > forgeParams.bestiaryCommonEnd) revert InvalidConfig();

        // Set bestiary
        bestiaryContract = ISatoshiBestiary(bestiaryAddr);

        // Set forge immutables
        maxRareForged = forgeParams.maxRareForged;
        maxEpicForged = forgeParams.maxEpicForged;
        maxLegendaryForged = forgeParams.maxLegendaryForged;
        maxMythicForged = forgeParams.maxMythicForged;
        maxReliquia = forgeParams.maxReliquia;
        maxMythicShard = forgeParams.maxMythicShard;
        maxApex = forgeParams.maxApex;

        // Set start IDs
        mythicForgedStartId = forgeParams.mythicForgedStartId;
        legendaryForgedStartId = forgeParams.legendaryForgedStartId;
        epicForgedStartId = forgeParams.epicForgedStartId;
        rareForgedStartId = forgeParams.rareForgedStartId;
        mythicShardStartId = forgeParams.mythicShardStartId;
        apexStartId = forgeParams.apexStartId;
        reliquiaStartId = forgeParams.reliquiaStartId;

        // Set base IDs (startId - 1)
        _mythicForgedBase = forgeParams.mythicForgedStartId - 1;
        _legendaryForgedBase = forgeParams.legendaryForgedStartId - 1;
        _epicForgedBase = forgeParams.epicForgedStartId - 1;
        _rareForgedBase = forgeParams.rareForgedStartId - 1;
        _mythicShardBase = forgeParams.mythicShardStartId - 1;
        _apexBase = forgeParams.apexStartId - 1;
        _reliquiaBase = forgeParams.reliquiaStartId - 1;

        // Set species counts
        rareForgedSpecies = forgeParams.rareForgedSpecies;
        epicForgedSpecies = forgeParams.epicForgedSpecies;
        legendaryForgedSpecies = forgeParams.legendaryForgedSpecies;
        mythicForgedSpecies = forgeParams.mythicForgedSpecies;
        totalForgedTypes = 7;

        // Set bestiary boundaries
        bestiaryCommonStart = forgeParams.bestiaryCommonStart;
        bestiaryCommonEnd = forgeParams.bestiaryCommonEnd;
        bestiaryRareStart = forgeParams.bestiaryRareStart;
        bestiaryRareEnd = forgeParams.bestiaryRareEnd;
        bestiaryEpicStart = forgeParams.bestiaryEpicStart;
        bestiaryEpicEnd = forgeParams.bestiaryEpicEnd;
        bestiaryLegendaryStart = forgeParams.bestiaryLegendaryStart;
        bestiaryLegendaryEnd = forgeParams.bestiaryLegendaryEnd;

        // Initialize shard pool with all available IDs
        for (uint256 i = 0; i < maxMythicShard;) {
            _availableShardIds.push(mythicShardStartId + i);
            unchecked { ++i; }
        }

        // Set default forge fees (can be updated by owner)
        forgeFee[0] = 0.01 ether; // Rare
        forgeFee[1] = 0.02 ether; // Epic
        forgeFee[2] = 0.03 ether; // Legendary
        forgeFee[3] = 0.04 ether; // Reliquia
        forgeFee[4] = 0.05 ether; // MythicForged
        forgeFee[5] = 0.06 ether; // MythicShard
        forgeFee[6] = 0 ether;    // APEX (free, no fee)

        // All forge steps start INACTIVE — owner activates them individually via setForgeStepActive()
        for (uint256 i = 0; i < 7;) {
            forgeStepActive[i] = false;
            unchecked { ++i; }
        }

        // Set VRF
        vrfCoordinator = IVRFCoordinatorV2Plus(vrfParams.vrfCoordinator);
        vrfSubscriptionId = vrfParams.subscriptionId;
        vrfKeyHash = vrfParams.keyHash;
        notRevealedURI = vrfParams.notRevealedURI;

        // Set royalty (capped at 10% = 1000 bps)
        if (royaltyBps > 1000) revert InvalidConfig();
        _setDefaultRoyalty(msg.sender, royaltyBps);
    }

    // =====================================================================
    //  FORGE STEPS 0-2: BESTIARY INPUTS
    // =====================================================================

    function forgeRare(uint256[] calldata commonTokenIds) external payable nonReentrant whenNotPaused {
        _checkForgeStepAndFee(0);
        if (commonTokenIds.length != rareInputCount) revert IncorrectTokenCount(rareInputCount, commonTokenIds.length);
        if (rareForgedCount >= maxRareForged) revert MaxSupplyExceeded();
        _verifyAndBurnBestiaryTokens(commonTokenIds, bestiaryCommonStart, bestiaryCommonEnd);

        // Minta 1 Rare Forged
        unchecked { rareForgedCount++; }
        uint256 newTokenId = _rareForgedBase + rareForgedCount;

        _finalizeForge(newTokenId, commonTokenIds, rareForgedCount, rareForgedSpecies);
        emit RareForged(msg.sender, newTokenId);
    }

    function forgeEpic(uint256[] calldata rareTokenIds) external payable nonReentrant whenNotPaused {
        _checkForgeStepAndFee(1);
        if (rareTokenIds.length != epicInputCount) revert IncorrectTokenCount(epicInputCount, rareTokenIds.length);
        if (epicForgedCount >= maxEpicForged) revert MaxSupplyExceeded();
        _verifyAndBurnBestiaryTokens(rareTokenIds, bestiaryRareStart, bestiaryRareEnd);

        // Minta 1 Epic Forged
        unchecked { epicForgedCount++; }
        uint256 newTokenId = _epicForgedBase + epicForgedCount;

        _finalizeForge(newTokenId, rareTokenIds, epicForgedCount, epicForgedSpecies);
        emit EpicForged(msg.sender, newTokenId);
    }

    function forgeLegendary(uint256[] calldata epicTokenIds) external payable nonReentrant whenNotPaused {
        _checkForgeStepAndFee(2);
        if (epicTokenIds.length != legendaryInputCount) revert IncorrectTokenCount(legendaryInputCount, epicTokenIds.length);
        if (legendaryForgedCount >= maxLegendaryForged) revert MaxSupplyExceeded();
        _verifyAndBurnBestiaryTokens(epicTokenIds, bestiaryEpicStart, bestiaryEpicEnd);

        // Minta 1 Legendary Forged
        unchecked { legendaryForgedCount++; }
        uint256 newTokenId = _legendaryForgedBase + legendaryForgedCount;

        _finalizeForge(newTokenId, epicTokenIds, legendaryForgedCount, legendaryForgedSpecies);
        emit LegendaryForged(msg.sender, newTokenId);
    }

    // Step 3b: 7 Legendary (originali) → 1 Reliquia Custodum
    function forgeReliquia(uint256[] calldata legendaryTokenIds) external payable nonReentrant whenNotPaused {
        _checkForgeStepAndFee(3);
        if (legendaryTokenIds.length != reliquiaInputCount) revert IncorrectTokenCount(reliquiaInputCount, legendaryTokenIds.length);
        if (reliquiaCount >= maxReliquia) revert ReliquiaMaxSupplyExceeded();
        _verifyAndBurnBestiaryTokens(legendaryTokenIds, bestiaryLegendaryStart, bestiaryLegendaryEnd);

        // Minta 1 Reliquia Custodum
        unchecked { reliquiaCount++; }
        uint256 newTokenId = _reliquiaBase + reliquiaCount;

        isReliquia[newTokenId] = true;

        _finalizeForge(newTokenId, legendaryTokenIds, reliquiaCount, 1);
        emit ReliquiaForged(msg.sender, newTokenId, legendaryTokenIds);
    }

    // Endgame: 5 Legendary Forged + 1 Reliquia → 1 Mythic Forged
    function forgeMythicForged(uint256[] calldata legendaryForgedIds, uint256 reliquiaTokenId) external payable nonReentrant whenNotPaused {
        _checkForgeStepAndFee(4);
        if (legendaryForgedIds.length != 5) revert IncorrectTokenCount(5, legendaryForgedIds.length);
        if (mythicForgedCount >= maxMythicForged) revert MaxSupplyExceeded();

        // Verifica Reliquia: deve essere una Reliquia Custodum valida
        if (!isReliquia[reliquiaTokenId]) revert ReliquiaNotFound(reliquiaTokenId);
        if (ownerOf(reliquiaTokenId) != msg.sender) revert NotReliquiaOwner(reliquiaTokenId);

        // Brucia i 5 Legendary Forged
        // Range: [legendaryForgedStartId, epicForgedStartId - 1]
        for (uint256 i = 0; i < legendaryForgedIds.length;) {
            if (!_inRange(legendaryForgedIds[i], legendaryForgedStartId, epicForgedStartId - 1)) revert NotForgedToken(legendaryForgedIds[i]);
            if (ownerOf(legendaryForgedIds[i]) != msg.sender) revert NotTokenOwner(legendaryForgedIds[i]);
            _burn(legendaryForgedIds[i]);
            unchecked { ++i; }
        }

        // Brucia la Reliquia Custodum
        _burn(reliquiaTokenId);

        unchecked { mythicForgedCount++; }
        uint256 newTokenId = _mythicForgedBase + mythicForgedCount;

        _finalizeForge(newTokenId, legendaryForgedIds, mythicForgedCount, mythicForgedSpecies);
        emit MythicForgedMinted(msg.sender, newTokenId);
    }

    function forgeMythicShard(uint256[] calldata mythicForgedIds) external payable nonReentrant whenNotPaused returns (uint256 requestId) {
        _checkForgeStepAndFee(5);
        if (mythicForgedIds.length != 2) revert IncorrectTokenCount(2, mythicForgedIds.length);
        if (_availableShardIds.length == 0) revert MaxSupplyExceeded();
        if (address(vrfCoordinator) == address(0)) revert VRFCoordinatorNotSet();

        // Range MythicForged: [mythicForgedStartId, legendaryForgedStartId - 1]
        for (uint256 i = 0; i < mythicForgedIds.length;) {
            if (!_inRange(mythicForgedIds[i], mythicForgedStartId, legendaryForgedStartId - 1)) revert NotForgedToken(mythicForgedIds[i]);
            if (ownerOf(mythicForgedIds[i]) != msg.sender) revert NotTokenOwner(mythicForgedIds[i]);
            _burn(mythicForgedIds[i]);
            unchecked { ++i; }
        }

        uint256 shardTokenId = _availableShardIds[_availableShardIds.length - 1];
        _availableShardIds.pop();

        requestId = _requestShardVRF();

        _shardRequests[requestId] = ShardForgeRequest({
            forger: msg.sender,
            fulfilled: false,
            shardTokenId: shardTokenId,
            mythicForgedId1: mythicForgedIds[0],
            mythicForgedId2: mythicForgedIds[1],
            requestBlock: block.number,
            feePaid: msg.value
        });

        unchecked { pendingShardRequests++; }
        lockedForgeFees += msg.value; // FIX "Pozzo Vuoto": blocca ETH in escrow
        _pendingShardRequestIds.push(requestId);

        emit ShardForgeRequested(msg.sender, requestId, shardTokenId);
        return requestId;
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(vrfCoordinator)) revert OnlyVRFCoordinator();

        // FIX AUDIT F-01/F-13: _requestProcessed previene double-mint dopo refund
        if (_requestProcessed[requestId]) revert DuplicateShardCallback();
        _requestProcessed[requestId] = true;

        ShardForgeRequest memory req = _shardRequests[requestId];
        if (req.forger == address(0)) revert ShardRequestNotFound();
        if (req.fulfilled) revert DuplicateShardCallback();

        _shardRequests[requestId].fulfilled = true;
        unchecked { pendingShardRequests--; }
        lockedForgeFees -= req.feePaid; // FIX "Pozzo Vuoto": sblocca escrow (VRF ok)

        uint256 newTokenId = req.shardTokenId;
        unchecked { mythicShardCount++; }

        ShardType sType = _assignShardType(randomWords[0]);
        shardTypes[newTokenId] = sType;

        _mint(req.forger, newTokenId);

        emit MythicShardForged(req.forger, newTokenId, sType);
        emit ShardForgeFulfilled(requestId, newTokenId, sType);
    }

    function retryShardForge(uint256 requestId) external nonReentrant whenNotPaused returns (uint256 newRequestId) {
        if (address(vrfCoordinator) == address(0)) revert VRFCoordinatorNotSet();
        ShardForgeRequest storage req = _shardRequests[requestId];
        if (req.forger != msg.sender) revert NotRequestForger();
        if (req.fulfilled) revert RequestAlreadyFulfilled();
        if (_requestProcessed[requestId]) revert RequestAlreadyFulfilled(); // FIX AUDIT F-02
        if (block.number < req.requestBlock + VRF_TIMEOUT) revert RequestNotTimedOut();

        // FIX AUDIT F-01/F-02: marca vecchia request come processata PRIMA di tutto
        _requestProcessed[requestId] = true;

        newRequestId = _requestShardVRF();

        _shardRequests[newRequestId] = ShardForgeRequest({
            forger: msg.sender,
            fulfilled: false,
            shardTokenId: req.shardTokenId,
            mythicForgedId1: req.mythicForgedId1,
            mythicForgedId2: req.mythicForgedId2,
            requestBlock: block.number,
            feePaid: req.feePaid
        });

        _pendingShardRequestIds.push(newRequestId); // FIX: traccia il nuovo ID per batch refund admin
        emit ShardForgeRetried(requestId, newRequestId, msg.sender);
        delete _shardRequests[requestId]; // FIX N2: Pulizia storage
        return newRequestId;
    }

    function refundFailedShard(uint256 requestId) external nonReentrant {
        ShardForgeRequest storage req = _shardRequests[requestId];
        if (req.forger != msg.sender) revert NotRequestForger();
        if (req.fulfilled) revert RequestAlreadyFulfilled();
        if (_requestProcessed[requestId]) revert RequestAlreadyFulfilled(); // FIX AUDIT F-01
        if (block.number < req.requestBlock + VRF_TIMEOUT) revert RequestNotTimedOut();

        // FIX AUDIT F-01: marca come processata PRIMA di qualsiasi operazione (CEI)
        _requestProcessed[requestId] = true;

        unchecked { pendingShardRequests--; }
        lockedForgeFees -= req.feePaid; // FIX "Pozzo Vuoto": sblocca escrow (refund)

        _availableShardIds.push(req.shardTokenId);

        _mint(msg.sender, req.mythicForgedId1);
        _mint(msg.sender, req.mythicForgedId2);

        // FIX H-01: Salva in memoria PRIMA del delete (req è storage pointer, delete lo azzera)
        uint256 feeToRefund = req.feePaid;
        uint256 m1 = req.mythicForgedId1;
        uint256 m2 = req.mythicForgedId2;

        delete _shardRequests[requestId]; // Pulizia storage

        // FIX H-01: Usa le variabili locali salvate (non il puntatore storage azzerato)
        emit ShardForgeRefunded(requestId, msg.sender, m1, m2);

        if (feeToRefund > 0) {
            (bool success, ) = payable(msg.sender).call{value: feeToRefund}("");
            if (!success) revert RefundETHFailed();
        }
    }

    /// @notice Claim ETH from failed push refunds (Pull pattern — salvadanaio)
    function claimRefund() external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender];
        if (amount == 0) revert NoPendingRefund();
        pendingRefunds[msg.sender] = 0;
        totalPendingRefunds -= amount;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert WithdrawFailed();
        emit RefundClaimed(msg.sender, amount);
    }

    /// @notice Sblocca tutte le shard request scadute. Paginated to avoid gas bomb.
    function refundAllExpiredShards(uint256 maxIterations) external onlyOwner nonReentrant returns (uint256 refunded) {
        uint256 len = _pendingShardRequestIds.length;
        uint256 i = 0;
        uint256 iterations = 0;
        while (i < len) {
            if (maxIterations > 0 && iterations >= maxIterations) break;
            unchecked { iterations++; }
            uint256 reqId = _pendingShardRequestIds[i];
            ShardForgeRequest storage req = _shardRequests[reqId];

            // Gia' processato → rimuovi
            if (req.forger == address(0) || req.fulfilled || _requestProcessed[reqId]) {
                _pendingShardRequestIds[i] = _pendingShardRequestIds[len - 1];
                _pendingShardRequestIds.pop();
                len--;
                continue;
            }

            // Non scaduto → skip
            if (block.number < req.requestBlock + VRF_TIMEOUT) {
                i++;
                continue;
            }

            // Scaduto → refund (CEI pattern)
            _requestProcessed[reqId] = true; // FIX AUDIT F-01: previene callback post-refund
            unchecked { pendingShardRequests--; }
            lockedForgeFees -= req.feePaid;
            _availableShardIds.push(req.shardTokenId);
            _mint(req.forger, req.mythicForgedId1);
            _mint(req.forger, req.mythicForgedId2);

            uint256 feeToRefund = req.feePaid;
            address forger = req.forger;
            uint256 m1 = req.mythicForgedId1;
            uint256 m2 = req.mythicForgedId2;
            delete _shardRequests[reqId];

            emit ShardForgeRefunded(reqId, forger, m1, m2);

            if (feeToRefund > 0) {
                (bool success, ) = payable(forger).call{value: feeToRefund}("");
                if (!success) {
                    // FIX CRITICO "Buco Nero": la request è già cancellata,
                    // refundFailedShard() non può più funzionare.
                    // Accreditiamo nel salvadanaio → l'utente chiama claimRefund().
                    pendingRefunds[forger] += feeToRefund;
                    totalPendingRefunds += feeToRefund;
                    emit RefundCredited(forger, feeToRefund);
                    emit ShardRefundETHFailed(reqId, forger, feeToRefund);
                }
            }

            _pendingShardRequestIds[i] = _pendingShardRequestIds[len - 1];
            _pendingShardRequestIds.pop();
            len--;
            refunded++;
        }
    }

    function pendingShardRequestCount() external view returns (uint256) {
        return _pendingShardRequestIds.length;
    }

    function _assignShardType(uint256 entropy) private returns (ShardType) {
        uint256 maxPerShard = maxMythicShard / 3;
        uint256 igRemain = maxPerShard - ignisShardCount;
        uint256 fuRemain = maxPerShard - fulmenShardCount;
        uint256 umRemain = maxPerShard - umbraShardCount;
        uint256 totalRemain = igRemain + fuRemain + umRemain;

        if (totalRemain == igRemain) { unchecked { ignisShardCount++; } return ShardType.IGNIS; }
        if (totalRemain == fuRemain) { unchecked { fulmenShardCount++; } return ShardType.FULMEN; }
        if (totalRemain == umRemain) { unchecked { umbraShardCount++; } return ShardType.UMBRA; }

        uint256 rand = entropy % totalRemain;

        if (rand < igRemain) {
            unchecked { ignisShardCount++; }
            return ShardType.IGNIS;
        }
        unchecked { rand -= igRemain; }
        if (rand < fuRemain) {
            unchecked { fulmenShardCount++; }
            return ShardType.FULMEN;
        }
        unchecked { umbraShardCount++; }
        return ShardType.UMBRA;
    }

    // FIX AUDIT F-11: payable + _checkForgeStepAndFee per coerenza (fee step 6 = 0)
    // FIX AUDIT H-03: O(1) parameter-based validation — no more O(N) loop over all shards
    function claimApex(uint256 ignisId, uint256 fulmenId, uint256 umbraId) external payable nonReentrant whenNotPaused {
        _checkForgeStepAndFee(6);
        if (apexCount >= maxApex) revert MaxSupplyExceeded();

        // Validate all 3 are valid shards in range
        if (!_inRange(ignisId, mythicShardStartId, mythicShardStartId + maxMythicShard - 1)) revert NotForgedToken(ignisId);
        if (!_inRange(fulmenId, mythicShardStartId, mythicShardStartId + maxMythicShard - 1)) revert NotForgedToken(fulmenId);
        if (!_inRange(umbraId, mythicShardStartId, mythicShardStartId + maxMythicShard - 1)) revert NotForgedToken(umbraId);

        // Validate ownership
        if (_ownerOf(ignisId) != msg.sender) revert NotOwnerOfToken(ignisId);
        if (_ownerOf(fulmenId) != msg.sender) revert NotOwnerOfToken(fulmenId);
        if (_ownerOf(umbraId) != msg.sender) revert NotOwnerOfToken(umbraId);

        // Validate not already used
        if (shardUsedForApex[ignisId]) revert ShardAlreadyUsed(ignisId);
        if (shardUsedForApex[fulmenId]) revert ShardAlreadyUsed(fulmenId);
        if (shardUsedForApex[umbraId]) revert ShardAlreadyUsed(umbraId);

        // Validate correct types (one of each)
        if (shardTypes[ignisId] != ShardType.IGNIS) revert WrongShardType(ignisId);
        if (shardTypes[fulmenId] != ShardType.FULMEN) revert WrongShardType(fulmenId);
        if (shardTypes[umbraId] != ShardType.UMBRA) revert WrongShardType(umbraId);

        // Le Shard restano nel wallet come trofei inerti (Doc_13: "Shard NON bruciate").
        // La marcatura on-chain previene il riutilizzo; il tokenURI mostra "_depleted".
        shardUsedForApex[ignisId] = true;
        shardUsedForApex[fulmenId] = true;
        shardUsedForApex[umbraId] = true;

        unchecked { apexCount++; }
        uint256 newTokenId = _apexBase + apexCount;

        _safeMint(msg.sender, newTokenId);
        emit ApexAwarded(msg.sender, newTokenId, ignisId, fulmenId, umbraId);
    }

    // =====================================================================
    //  SIGILLO DEI TIPI FORGIATI — Reveal + Seal per tipo (0-6)
    // =====================================================================

    /**
     * @notice Rivela un tipo forgiato — i suoi metadata diventano visibili.
     * @param forgedTypeId ID del tipo (0=MythicForged, 1=LegendaryForged, 2=EpicForged,
     *                     3=RareForged, 4=MythicShard, 5=APEX, 6=Reliquia)
     */
    function revealForgedType(uint8 forgedTypeId) external onlyOwner {
        if (forgedTypeId >= totalForgedTypes) revert InvalidForgedTypeId();
        if (forgedTypeRevealed[forgedTypeId]) revert ForgedTypeAlreadyRevealed();
        if (bytes(forgedTypeURI[forgedTypeId]).length == 0) revert URINotSet();

        forgedTypeRevealed[forgedTypeId] = true;
        emit ForgedTypeRevealed(forgedTypeId);
    }

    /**
     * @notice Sigilla un tipo forgiato — i suoi metadata diventano IMMUTABILI per sempre.
     * @dev Il tipo deve essere gia' rivelato. Quando tutti i 7 tipi sono sigillati,
     *      scatta il Sigillo Nero automaticamente.
     */
    function sealForgedType(uint8 forgedTypeId) external onlyOwner {
        if (forgedTypeId >= totalForgedTypes) revert InvalidForgedTypeId();
        if (!forgedTypeRevealed[forgedTypeId]) revert ForgedTypeNotRevealed();
        if (forgedTypeSealed[forgedTypeId]) revert ForgedTypeAlreadySealed();

        forgedTypeSealed[forgedTypeId] = true;
        unchecked { sealedCount++; }

        emit ForgedTypeSealed(forgedTypeId, sealedCount);

        if (sealedCount == totalForgedTypes) {
            sigilloNero = true;
            emit SigilloNeroEvent();
        }
    }

    // =====================================================================
    //  URI SETTERS — Per tipo forgiato, con protezione sigillo
    // =====================================================================

    function setForgedTypeURI(uint8 forgedTypeId, string calldata _uri) external onlyOwner {
        if (forgedTypeId >= totalForgedTypes) revert InvalidForgedTypeId();
        if (forgedTypeSealed[forgedTypeId]) revert ForgedTypeURISealed();
        if (bytes(_uri).length == 0) revert EmptyURI();

        forgedTypeURI[forgedTypeId] = _uri;
    }

    function setNotRevealedURI(string calldata _uri) external onlyOwner {
        if (sigilloNero) revert SigilloNeroAlreadyDone();
        if (bytes(_uri).length == 0) revert EmptyURI();
        notRevealedURI = _uri;
        emit NotRevealedURIUpdated(_uri);
    }

    // =====================================================================
    //  SIGILLO NERO — Freeze globale (IRREVERSIBILE)
    // =====================================================================

    /**
     * @notice Il Sigillo Nero: sigilla tutti i tipi forgiati in un colpo solo. IRREVERSIBILE.
     * @dev "Il Vetro di Sicurezza": reverta se QUALUNQUE tipo forgiato non ha un URI assegnato.
     *      Questo previene la sigillazione accidentale di tipi senza metadata.
     */
    function sigilloNeroForceAll() external onlyOwner {
        if (sigilloNero) revert SigilloNeroAlreadyDone();

        // "Il Vetro di Sicurezza" — verifica che TUTTI i tipi forgiati abbiano un URI
        for (uint8 i = 0; i < totalForgedTypes;) {
            if (bytes(forgedTypeURI[i]).length == 0) revert SigilloNeroURIMissing(i);
            unchecked { ++i; }
        }

        uint8 runningCount = sealedCount;
        for (uint8 i = 0; i < totalForgedTypes;) {
            if (!forgedTypeSealed[i]) {
                if (!forgedTypeRevealed[i]) {
                    forgedTypeRevealed[i] = true;
                    emit ForgedTypeRevealed(i);
                }
                forgedTypeSealed[i] = true;
                unchecked { runningCount++; }
                emit ForgedTypeSealed(i, runningCount);
            }
            unchecked { ++i; }
        }

        sealedCount = totalForgedTypes;
        sigilloNero = true;
        emit SigilloNeroEvent();
    }

    // =====================================================================
    //  TOKEN URI — Reveal per tipo forgiato
    // =====================================================================

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        uint8 forgedTypeId = getForgedTypeId(tokenId);

        if (!forgedTypeRevealed[forgedTypeId]) return notRevealedURI;

        string memory uri = forgedTypeURI[forgedTypeId];

        // Shard (tipo 4) usata per APEX → metadata "depleted" (immagine scarica)
        // Previene frodi su mercato secondario: il compratore vede subito lo stato
        if (forgedTypeId == 4 && shardUsedForApex[tokenId]) {
            return string(abi.encodePacked(uri, tokenId.toString(), "_depleted", JSON_EXT));
        }

        return string(abi.encodePacked(uri, tokenId.toString(), JSON_EXT));
    }

    // =====================================================================
    //  FORGED TYPE ID GETTER
    // =====================================================================

    /**
     * @notice Calcola il tipo forgiato (0-6) dal tokenId.
     * @dev Cascade decrescente: dal startId PIU' ALTO al PIU' BASSO.
     *      Ordine verificato nel constructor:
     *      reliquiaStart (21601) > apexStart (21598) > mythicShardStart (21589) >
     *      rareStart (21337) > epicStart (21127) > legendaryStart (21022) > mythicStart (21001)
     */
    function getForgedTypeId(uint256 tokenId) public view returns (uint8) {
        if (tokenId >= reliquiaStartId) return 6;              // Reliquia (21601+)
        if (tokenId >= apexStartId) return 5;                  // APEX (21598+)
        if (tokenId >= mythicShardStartId) return 4;           // Mythic Shard (21589+)
        if (tokenId >= rareForgedStartId) return 3;            // Rare Forged (21337+, highest of 4 tiers)
        if (tokenId >= epicForgedStartId) return 2;            // Epic Forged (21127+)
        if (tokenId >= legendaryForgedStartId) return 1;       // Legendary Forged (21022+)
        if (tokenId >= mythicForgedStartId) return 0;          // Mythic Forged (21001+, lowest of 4 tiers)
        revert InvalidForgedTypeId();
    }

    // =====================================================================
    //  Counter Views
    // =====================================================================

    /**
     * @notice Totale cumulativo di forgiature (include carte poi bruciate per forgiature successive).
     * NON rappresenta la supply circolante. Per la supply reale usare ERC721.balanceOf o totalSupply.
     */
    function getTotalForgedCumulative() public view returns (uint256) {
        return rareForgedCount + epicForgedCount + legendaryForgedCount
             + mythicForgedCount + mythicShardCount + apexCount + reliquiaCount;
    }

    function availableShardSlots() external view returns (uint256) {
        return _availableShardIds.length;
    }

    // =====================================================================
    //  INTERNAL HELPER FUNCTIONS
    // =====================================================================

    function _checkForgeStepAndFee(uint256 step) private {
        if (!forgeStepActive[step]) revert ForgeStepNotActive(step);
        if (msg.value != forgeFee[step]) revert IncorrectForgePayment(forgeFee[step], msg.value);
    }

    /// @dev Consolidated range check — replaces 8 individual tier helpers (~160 bytes saved)
    function _inRange(uint256 id, uint256 lo, uint256 hi) private pure returns (bool) {
        return id >= lo && id <= hi;
    }

    /// @dev Verify all tokens are in the given tier range, then batch burn from Bestiary
    function _verifyAndBurnBestiaryTokens(uint256[] calldata tokenIds, uint256 startId, uint256 endId) private {
        for (uint256 i = 0; i < tokenIds.length;) {
            if (!_inRange(tokenIds[i], startId, endId)) revert InvalidTokenTier(tokenIds[i]);
            unchecked { ++i; }
        }
        bestiaryContract.batchBurnFrom(msg.sender, tokenIds);
    }

    /// @dev Consolidated VRF request for Shard forging — replaces 2 duplicate blocks
    function _requestShardVRF() private returns (uint256) {
        uint256 reqId = vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: shardRequestConfirmations,
                callbackGasLimit: shardCallbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: vrfNativePayment})
                )
            })
        );
        if (reqId == 0) revert InvalidShardVRFRequest();
        return reqId;
    }

    function _finalizeForge(uint256 newTokenId, uint256[] calldata inputIds, uint256 counter, uint256 speciesCount) private {
        uint256 species = _computeSpecies(inputIds, msg.sender, counter, speciesCount);
        forgedSpeciesId[newTokenId] = species;
        _safeMint(msg.sender, newTokenId);
        emit ForgedSpeciesAssigned(newTokenId, species);
    }

    function _computeSpecies(uint256[] calldata tokenIds, address user, uint256 counter, uint256 speciesModulo) private view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(
            tokenIds,
            user,
            counter,
            block.timestamp
        ))) % speciesModulo;
    }

    // =====================================================================
    //  ADMIN FUNCTIONS
    // =====================================================================

    function setForgeFee(uint256 step, uint256 amount) external onlyOwner {
        if (amount > 1 ether) revert ForgeFeeTooHigh(); // Safety cap: max 1 ETH per forge step
        forgeFee[step] = amount;
    }

    function setForgeStepActive(uint256 step, bool active) external onlyOwner {
        forgeStepActive[step] = active;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function pauseAllForge() external onlyOwner {
        for (uint256 i = 0; i < 7;) {
            forgeStepActive[i] = false;
            unchecked { ++i; }
        }
        _pause();
    }

    function withdrawForgeFees() external onlyOwner nonReentrant {
        uint256 bal = address(this).balance;
        uint256 reserved = lockedForgeFees + totalPendingRefunds;
        if (bal <= reserved) revert NothingToWithdraw();
        uint256 withdrawable = bal - reserved;

        (bool success, ) = payable(msg.sender).call{value: withdrawable}("");
        if (!success) revert WithdrawFailed();
        emit ForgeFeesWithdrawn(withdrawable);
    }

    function setVRFConfig(uint256 subscriptionId, address coordinator, bytes32 keyHash) external onlyOwner {
        if (subscriptionId == 0) revert InvalidConfig();
        if (coordinator == address(0)) revert InvalidConfig();
        if (keyHash == bytes32(0)) revert InvalidConfig();
        vrfSubscriptionId = subscriptionId;
        vrfCoordinator = IVRFCoordinatorV2Plus(coordinator);
        vrfKeyHash = keyHash;
    }

    /// @notice Consolidated VRF tuning — replaces 3 individual setters (~140 bytes saved)
    function setVRFTuning(uint32 gasLimit, uint16 confirmations, bool useNative) external onlyOwner {
        if (gasLimit < 100_000 || gasLimit > 2_500_000) revert InvalidConfig();
        if (confirmations < 1 || confirmations > 200) revert InvalidConfig();
        shardCallbackGasLimit = gasLimit;
        shardRequestConfirmations = confirmations;
        vrfNativePayment = useNative;
    }

    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        if (feeNumerator > 1000) revert InvalidConfig();
        if (receiver == address(0)) revert InvalidConfig();
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    /// @notice Update the Bestiary contract address. Blocked after lockContracts().
    function setBestiaryContract(address _bestiary) external onlyOwner {
        if (contractsLocked) revert ContractsAlreadyLocked();
        if (_bestiary == address(0)) revert InvalidConfig();
        address old = address(bestiaryContract);
        bestiaryContract = ISatoshiBestiary(_bestiary);
        emit BestiaryContractUpdated(old, _bestiary);
    }

    function lockContracts() external onlyOwner {
        if (contractsLocked) revert ContractsAlreadyLocked();
        contractsLocked = true;
        emit ContractsLocked();
    }

    // =====================================================================
    //  TOURNAMENT LOCK — F0
    // =====================================================================

    function setTournamentContract(address _tournament) external onlyOwner {
        if (_tournament == address(0)) revert InvalidTournamentAddress();
        address old = tournamentContract;
        tournamentContract = _tournament;
        emit TournamentContractUpdated(old, _tournament);
    }

    /// @notice Consolidated lock/unlock — same pattern as BestiaryV4 (~100 bytes saved)
    function setTokenLock(uint256[] calldata tokenIds, bool locked) external {
        if (msg.sender != tournamentContract) revert NotTournamentContract();
        if (tokenIds.length == 0) revert NoTokensProvided();
        for (uint256 i = 0; i < tokenIds.length;) {
            tokenLocked[tokenIds[i]] = locked;
            unchecked { ++i; }
        }
        if (locked) { emit TokensLocked(tokenIds, msg.sender); }
        else { emit TokensUnlocked(tokenIds, msg.sender); }
    }

    /**
     * @notice Override _update to block transfer/burn of locked tokens.
     * @dev Mints (from == address(0)) are allowed — _ownerOf returns zero for new tokens.
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && tokenLocked[tokenId]) revert TokenLocked(tokenId);
        return super._update(to, tokenId, auth);
    }

    // =====================================================================
    //  ERC721C & OVERRIDES
    // =====================================================================

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721C, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // =====================================================================
    //  ERROR HELPERS
    // =====================================================================

    error NothingToWithdraw();
    error WithdrawFailed();
    error NoPendingRefund();

    function _requireCallerIsContractOwner() internal view virtual override {
        if (msg.sender != owner()) revert OnlyOwner();
    }
}