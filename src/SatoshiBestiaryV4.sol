// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SatoshiBestiary V4 — Template Parametrico Multi-Collection
 * @notice Identico a V3 nella logica, ma con supply/tier/specie configurabili via constructor.
 *         Permette di deployare collection diverse (Genesis 21K, Epoch 42K, etc.)
 *         con lo stesso contratto auditato.
 *
 * @dev Cambiamenti rispetto a V3:
 *      - Le costanti (MAX_SUPPLY, TOTAL_SPECIES, tier ranges, etc.) sono ora `immutable`
 *      - getSpeciesId() usa i tier boundaries parametrici
 *      - Constructor accetta una struct CollectionParams
 *      - Tutta la logica (VRF, Sigillo, Forge God Mode, Refund, etc.) è IDENTICA a V3
 *
 *      INVARIANTI MANTENUTI:
 *      - Free mint + VRF random ID assignment
 *      - Sigillo delle Specie (reveal/seal per specie, Sigillo Nero)
 *      - ERC-721C (Limit Break) + ERC-2981 royalties
 *      - Anti-bot (EOA only, cooldown, max per wallet)
 *      - "Buco Nero" VRF protection (retry + refund)
 *      - God Mode Forge (batchBurnFrom)
 *      - Pausable
 */

import {ERC721C} from "./ERC721C.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract SatoshiBestiaryV4 is ERC721C, ERC2981, VRFConsumerBaseV2Plus, ReentrancyGuard, Pausable {
    using Strings for uint256;

    // =====================================================================
    //  COLLECTION PARAMS — Struct per constructor
    // =====================================================================

    struct CollectionParams {
        string name;
        string symbol;
        uint256 maxSupply;        // 21000 per Genesis, 42000 per Epoch, etc.
        uint256 devReserve;       // 2100 per Genesis
        uint256 maxPerWallet;     // 10 per Genesis
        uint256 mintBlock;        // 5 per Genesis (NFT per mint call)
        uint256 mintCooldown;     // 7200 per Genesis (~4h su Base)
        uint8 totalSpecies;       // 42 per Genesis
        uint256[5] tierBoundaries;  // [21, 1050, 3150, 7350, 21000] per Genesis — END IDs cumulativi
        uint8[5] speciesPerTier;    // [2, 7, 10, 10, 13] per Genesis
        uint96 royaltyBps;          // 500 = 5%
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

    uint256 public immutable maxSupply;
    uint256 public immutable devReserve;
    uint256 public immutable publicSupply;
    uint256 public immutable maxPerWallet;
    uint256 public immutable mintBlock;
    uint256 public immutable mintCooldown;
    uint8   public immutable totalSpecies;

    // Tier boundaries (end IDs, inclusive). tierBound0 = end of Mythic, etc.
    uint256 private immutable _tierBound0;
    uint256 private immutable _tierBound1;
    uint256 private immutable _tierBound2;
    uint256 private immutable _tierBound3;
    uint256 private immutable _tierBound4; // == maxSupply

    // Species offset per tier (cumulative species ID start)
    uint8 private immutable _speciesOffset0; // always 0
    uint8 private immutable _speciesOffset1;
    uint8 private immutable _speciesOffset2;
    uint8 private immutable _speciesOffset3;
    uint8 private immutable _speciesOffset4;

    // Cards per species per tier (ceil(tierCards / speciesPerTier))
    uint256 private immutable _cardsPerSpecies0;
    uint256 private immutable _cardsPerSpecies1;
    uint256 private immutable _cardsPerSpecies2;
    uint256 private immutable _cardsPerSpecies3;
    uint256 private immutable _cardsPerSpecies4;

    // Species per tier (for clamping in getSpeciesId)
    uint8 private immutable _speciesPerTier0;
    uint8 private immutable _speciesPerTier1;
    uint8 private immutable _speciesPerTier2;
    uint8 private immutable _speciesPerTier3;
    uint8 private immutable _speciesPerTier4;

    // =====================================================================
    //  VRF STATE
    // =====================================================================

    uint256 public s_subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 3000000;
    uint16 public requestConfirmations = 3;
    bool public vrfNativePayment = true;

    // =====================================================================
    //  SIGILLO DELLE SPECIE — Reveal + Seal per specie
    // =====================================================================

    mapping(uint8 => string) public speciesURI;
    mapping(uint8 => bool) public speciesRevealed;
    mapping(uint8 => bool) public speciesSealed;
    uint8 public sealedCount;
    bool public sigilloNero;
    string public notRevealedURI;

    // =====================================================================
    //  SUPPLY TRACKING
    // =====================================================================

    uint256 public totalSupply;
    uint256 private _remainingIds;

    mapping(uint256 => uint256) private _shuffledIds;

    struct MintRequest {
        address minter;
        uint32 amount;
        uint256 requestBlock;
        uint256 feePaid;       // ETH paid (0 for freeMint/preMint)
        bool isPreMint;        // true = premint request, false = public mint
    }
    mapping(uint256 => MintRequest) private _mintRequests;

    struct DevMintRequest {
        address to;
        uint32 amount;
        uint256 requestBlock;
    }
    mapping(uint256 => DevMintRequest) private _devMintRequests;

    mapping(uint256 => bool) private _requestProcessed;

    enum CallbackStatus { PENDING, SUCCESS, FAILED }
    mapping(uint256 => CallbackStatus) public requestStatus;

    uint256 public constant MINT_VRF_TIMEOUT = 256;

    mapping(address => uint256) public mintedPerWallet;
    mapping(address => uint256) public lastMintBlock;
    uint256 public devMinted;
    uint256 public publicMinted;
    uint256 public publicPending;
    mapping(address => uint256) public pendingPerWallet;
    uint256 public devPending;

    uint256[] private _pendingDevRequestIds;
    uint256[] private _pendingMintRequestIds;

    string private constant JSON_EXT = ".json";

    bool public publicMintActive = false;

    // =====================================================================
    //  PREMINT ALLOWLIST — 21 wallet max, on-chain gated
    // =====================================================================

    bool public preMintActive = false;
    uint256 public constant PREMINT_MAX_WALLETS = 21;
    uint256 public constant PREMINT_MAX_SUPPLY = 210; // 21 wallets × 10 max per wallet
    mapping(address => bool) public allowlisted;
    uint256 public allowlistCount;
    uint256 public preminted;                          // total preminted NFTs
    uint256 public premintPending;                     // pending VRF for premint
    mapping(address => uint256) public premintedPerWallet;
    mapping(address => uint256) public premintPendingPerWallet;

    // "God Mode" Forge
    address public forgeContract;
    bool public contractsLocked = false;

    // =====================================================================
    //  TOURNAMENT & PAID MINT — F0
    // =====================================================================

    uint256 public mintPrice;                        // 0 = free mint, >0 = paid mint (wei)
    address public tournamentContract;               // SatoshiTournament address
    uint16  public tournamentSplitBps = 3000;        // 30% default (basis points, max 10000)
    mapping(uint256 => bool) public tokenLocked;     // Tournament lock per token
    uint256 public lockedMintFees;                   // ETH in escrow (pending VRF)
    uint256 public tournamentBalance;                // Accrued tournament share (pull pattern)
    mapping(address => uint256) public pendingRefunds; // Failed push refunds — claimable by user
    uint256 public totalPendingRefunds;               // Sum of all pendingRefunds (for safe withdraw)

    // Dev batch max (~20 token x VRF callback)
    uint256 public constant DEV_BATCH_MAX = 20;

    // =====================================================================
    //  CUSTOM ERRORS
    // =====================================================================

    error MintInactive();
    error NothingToWithdraw();
    error InvalidVRFRequest();
    error NoMoreIdsAvailable();
    error DuplicateCallback();
    error WithdrawFailed();
    error URINotSet();
    error InvalidSubscriptionId();
    error EmptyNotRevealedURI();
    error GasLimitOutOfBounds();
    error ConfirmationsOutOfBounds();
    error InvalidRoyaltyReceiver();
    error RoyaltyTooHigh();
    error EmptyURI();
    error ExceededMaxBatchSize();
    error InvalidMintAmount();
    error NotApprovedOperator();
    error BatchBurnOwnerMismatch(uint256 tokenId);
    error InvalidForgeAddress();
    error ContractsAlreadyLocked();
    error MintRequestNotFound();
    error MintRequestAlreadyProcessed();
    error MintRequestNotTimedOut();
    error NotMintRequester();
    // Sigillo errors
    error InvalidSpeciesId();
    error SpeciesAlreadyRevealed();
    error SpeciesAlreadySealed();
    error SpeciesNotRevealed();
    error SpeciesURISealed();
    error SigilloNeroAlreadyDone();
    error SigilloNeroURIMissing(uint8 speciesId);
    // V4 constructor validation errors
    error InvalidMaxSupply();
    error InvalidDevReserve();
    error InvalidTierBoundaries();
    error InvalidSpeciesPerTier();
    error InvalidMintBlock();
    error InvalidMaxPerWallet();
    error InvalidRoyaltyBps();
    error TierBoundaryNotMonotonic();
    error TierBoundaryExceedsSupply();
    error SpeciesTotalMismatch();
    error ZeroSpeciesInTier();
    // F0 — Tournament & Paid Mint errors
    error TokenLocked(uint256 tokenId);
    error NotTournamentContract();
    error InvalidTournamentAddress();
    error SplitBpsTooHigh();
    error InsufficientMintPayment();
    error NoTokensProvided();
    error NoPendingRefund();
    // STEP 1: Custom errors per require testuali
    error EOAOnly();
    error MaxPerWallet();
    error CooldownActive();
    error SupplyExhausted();
    error InvalidConfig();
    error InvalidBatchSize();
    // Premint Allowlist errors
    error NotAllowlisted();
    error PreMintInactive();
    error PreMintSupplyExhausted();
    error AllowlistFull();
    error NotInAllowlist();
    error EmptyAllowlist();
    error AllowlistTooLarge();
    error BothMintsActive();

    // =====================================================================
    //  EVENTS
    // =====================================================================

    event MintRequested(address indexed minter, uint256 indexed requestId, uint256 valueSent);
    event MintFulfilled(address indexed minter, uint256 indexed tokenId);
    event DevMintRequested(address indexed to, uint256 indexed requestId, uint256 amount);
    event DevMintFulfilled(address indexed to, uint256 indexed tokenId);
    event DevMintRefunded(uint256 indexed requestId, address indexed to, uint256 amount);
    event CallbackGasLimitChanged(uint32 oldLimit, uint32 newLimit);
    event RequestConfirmationsChanged(uint16 oldConf, uint16 newConf);
    event MintStatusChanged(bool active);
    event NotRevealedURIUpdated(string newURI);
    event RoyaltyUpdated(address indexed newReceiver, uint96 newPercentage);
    event SubscriptionIdUpdated(uint256 oldId, uint256 newId);
    event CallbackProcessed(uint256 indexed requestId, CallbackStatus status);
    event MintRetried(uint256 indexed oldRequestId, uint256 indexed newRequestId, address indexed minter);
    event MintRefunded(uint256 indexed requestId, address indexed minter, uint256 amount);
    event ForgeContractUpdated(address indexed oldForge, address indexed newForge);
    event ContractsLocked();
    event VRFNativePaymentChanged(bool newValue);
    event SpeciesRevealed(uint8 indexed speciesId);
    event SpeciesSealed(uint8 indexed speciesId, uint8 totalSealed);
    event SpeciesURIUpdated(uint8 indexed speciesId);
    event SigilloNeroEvent();
    // F0 — Tournament & Paid Mint events
    event TokensLocked(uint256[] tokenIds, address indexed byContract);
    event TokensUnlocked(uint256[] tokenIds, address indexed byContract);
    event TournamentContractUpdated(address indexed oldAddr, address indexed newAddr);
    event MintPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event TournamentSplitUpdated(uint16 oldBps, uint16 newBps);
    event PaidMintRevenue(uint256 totalPaid, uint256 tournamentShare, uint256 retained);
    event RefundCredited(address indexed user, uint256 amount);
    event RefundClaimed(address indexed user, uint256 amount);
    // Premint Allowlist events
    event AllowlistUpdated(address[] wallets, bool added);
    event AllowlistRemoved(address indexed wallet);
    event PreMintStatusChanged(bool active);
    event PreMintRequested(address indexed minter, uint256 indexed requestId);

    // =====================================================================
    //  CONSTRUCTOR — Parametrico
    // =====================================================================

    constructor(
        CollectionParams memory cp,
        VRFParams memory vrf
    )
        ERC721C(cp.name, cp.symbol)
        VRFConsumerBaseV2Plus(vrf.vrfCoordinator)
    {
        // --- Validazione CollectionParams ---
        if (cp.maxSupply == 0) revert InvalidMaxSupply();
        if (cp.devReserve > cp.maxSupply) revert InvalidDevReserve();
        if (cp.mintBlock == 0) revert InvalidMintBlock();
        if (cp.maxPerWallet < cp.mintBlock) revert InvalidMaxPerWallet();
        if (cp.totalSpecies == 0) revert InvalidSpeciesPerTier();
        if (cp.royaltyBps > 1000) revert InvalidRoyaltyBps(); // max 10%

        // Validazione tier boundaries: monotonicamente crescenti, ultimo = maxSupply
        if (cp.tierBoundaries[4] != cp.maxSupply) revert TierBoundaryExceedsSupply();
        for (uint256 i = 1; i < 5; i++) {
            if (cp.tierBoundaries[i] <= cp.tierBoundaries[i - 1]) revert TierBoundaryNotMonotonic();
        }
        if (cp.tierBoundaries[0] == 0) revert InvalidTierBoundaries();

        // Validazione species per tier: nessun zero, somma = totalSpecies, max 255 (uint8 safety)
        if (cp.totalSpecies > 255) revert InvalidSpeciesPerTier();
        uint8 speciesSum = 0;
        for (uint256 i = 0; i < 5; i++) {
            if (cp.speciesPerTier[i] == 0) revert ZeroSpeciesInTier();
            if (cp.speciesPerTier[i] > 255) revert InvalidSpeciesPerTier();
            speciesSum += cp.speciesPerTier[i];
        }
        if (speciesSum != cp.totalSpecies) revert SpeciesTotalMismatch();

        // Validazione: ogni tier deve avere almeno 1 carta (previene divisione per zero)
        for (uint256 i = 0; i < 5; i++) {
            uint256 tierCards = (i == 0) ?
                cp.tierBoundaries[i] :
                cp.tierBoundaries[i] - cp.tierBoundaries[i-1];
            if (tierCards == 0) revert InvalidTierBoundaries();
        }

        // --- VRF validation ---
        if (vrf.subscriptionId == 0) revert InvalidSubscriptionId();
        if (bytes(vrf.notRevealedURI).length == 0) revert EmptyNotRevealedURI();

        // --- Set immutables ---
        maxSupply = cp.maxSupply;
        devReserve = cp.devReserve;
        publicSupply = cp.maxSupply - cp.devReserve;
        maxPerWallet = cp.maxPerWallet;
        mintBlock = cp.mintBlock;
        mintCooldown = cp.mintCooldown;
        totalSpecies = cp.totalSpecies;

        // Tier boundaries
        _tierBound0 = cp.tierBoundaries[0];
        _tierBound1 = cp.tierBoundaries[1];
        _tierBound2 = cp.tierBoundaries[2];
        _tierBound3 = cp.tierBoundaries[3];
        _tierBound4 = cp.tierBoundaries[4]; // == maxSupply

        // Species offsets (cumulative)
        _speciesOffset0 = 0;
        _speciesOffset1 = cp.speciesPerTier[0];
        _speciesOffset2 = cp.speciesPerTier[0] + cp.speciesPerTier[1];
        _speciesOffset3 = cp.speciesPerTier[0] + cp.speciesPerTier[1] + cp.speciesPerTier[2];
        _speciesOffset4 = cp.speciesPerTier[0] + cp.speciesPerTier[1] + cp.speciesPerTier[2] + cp.speciesPerTier[3];

        // Cards per species per tier: ceil(tierCards / speciesPerTier)
        // Tier 0 (Mythic): IDs 1 to tierBound0
        _cardsPerSpecies0 = _ceilDiv(cp.tierBoundaries[0], cp.speciesPerTier[0]);
        // Tier 1 (Legendary): IDs tierBound0+1 to tierBound1
        _cardsPerSpecies1 = _ceilDiv(cp.tierBoundaries[1] - cp.tierBoundaries[0], cp.speciesPerTier[1]);
        // Tier 2 (Epic): IDs tierBound1+1 to tierBound2
        _cardsPerSpecies2 = _ceilDiv(cp.tierBoundaries[2] - cp.tierBoundaries[1], cp.speciesPerTier[2]);
        // Tier 3 (Rare): IDs tierBound2+1 to tierBound3
        _cardsPerSpecies3 = _ceilDiv(cp.tierBoundaries[3] - cp.tierBoundaries[2], cp.speciesPerTier[3]);
        // Tier 4 (Common): IDs tierBound3+1 to tierBound4
        _cardsPerSpecies4 = _ceilDiv(cp.tierBoundaries[4] - cp.tierBoundaries[3], cp.speciesPerTier[4]);

        // Species per tier (for clamping in getSpeciesId)
        _speciesPerTier0 = cp.speciesPerTier[0];
        _speciesPerTier1 = cp.speciesPerTier[1];
        _speciesPerTier2 = cp.speciesPerTier[2];
        _speciesPerTier3 = cp.speciesPerTier[3];
        _speciesPerTier4 = cp.speciesPerTier[4];

        // --- Set state ---
        _remainingIds = cp.maxSupply;
        s_subscriptionId = vrf.subscriptionId;
        keyHash = vrf.keyHash;
        notRevealedURI = vrf.notRevealedURI;
        _setDefaultRoyalty(msg.sender, cp.royaltyBps);
    }

    /// @dev Ceiling division, safe for non-zero b (validated in constructor)
    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b - 1) / b;
    }

    // =====================================================================
    //  SPECIES ID — Parametric mapping tokenId -> speciesId
    // =====================================================================

    /**
     * @notice Calcola l'ID specie dal tokenId usando i tier boundaries parametrici.
     * @dev Logica identica a V3 ma con boundaries immutabili.
     *      Tier 0 (Mythic):    ID 1           → tierBound0
     *      Tier 1 (Legendary): ID tierBound0+1 → tierBound1
     *      Tier 2 (Epic):      ID tierBound1+1 → tierBound2
     *      Tier 3 (Rare):      ID tierBound2+1 → tierBound3
     *      Tier 4 (Common):    ID tierBound3+1 → tierBound4 (= maxSupply)
     */
    function getSpeciesId(uint256 tokenId) public view returns (uint8) {
        if (tokenId < 1 || tokenId > maxSupply) revert InvalidSpeciesId();

        uint256 idx;

        // Tier 0 (Mythic)
        if (tokenId <= _tierBound0) {
            idx = (tokenId - 1) / _cardsPerSpecies0;
            if (idx >= _speciesPerTier0) idx = _speciesPerTier0 - 1;
            return _speciesOffset0 + uint8(idx);
        }
        // Tier 1 (Legendary)
        if (tokenId <= _tierBound1) {
            idx = (tokenId - _tierBound0 - 1) / _cardsPerSpecies1;
            if (idx >= _speciesPerTier1) idx = _speciesPerTier1 - 1;
            return _speciesOffset1 + uint8(idx);
        }
        // Tier 2 (Epic)
        if (tokenId <= _tierBound2) {
            idx = (tokenId - _tierBound1 - 1) / _cardsPerSpecies2;
            if (idx >= _speciesPerTier2) idx = _speciesPerTier2 - 1;
            return _speciesOffset2 + uint8(idx);
        }
        // Tier 3 (Rare)
        if (tokenId <= _tierBound3) {
            idx = (tokenId - _tierBound2 - 1) / _cardsPerSpecies3;
            if (idx >= _speciesPerTier3) idx = _speciesPerTier3 - 1;
            return _speciesOffset3 + uint8(idx);
        }
        // Tier 4 (Common)
        idx = (tokenId - _tierBound3 - 1) / _cardsPerSpecies4;
        if (idx >= _speciesPerTier4) idx = _speciesPerTier4 - 1;
        return _speciesOffset4 + uint8(idx);
    }

    // =====================================================================
    //  PAUSABLE
    // =====================================================================

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // =====================================================================
    //  PUBLIC MINT — Identico a V3
    // =====================================================================

    function freeMint() external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (!publicMintActive) revert MintInactive();
        if (msg.sender != tx.origin) revert EOAOnly();
        if (mintedPerWallet[msg.sender] + pendingPerWallet[msg.sender] + mintBlock > maxPerWallet) revert MaxPerWallet();
        if (block.number < lastMintBlock[msg.sender] + mintCooldown) revert CooldownActive();
        if (publicMinted + publicPending + preminted + premintPending + mintBlock > publicSupply) revert SupplyExhausted();

        pendingPerWallet[msg.sender] += mintBlock;
        lastMintBlock[msg.sender] = block.number;
        publicPending += mintBlock;

        requestId = _requestVRF(uint32(mintBlock));

        _mintRequests[requestId] = MintRequest(msg.sender, uint32(mintBlock), block.number, 0, false);
        requestStatus[requestId] = CallbackStatus.PENDING;
        _pendingMintRequestIds.push(requestId);

        emit MintRequested(msg.sender, requestId, 0);
        return requestId;
    }

    // =====================================================================
    //  PREMINT — Allowlist-gated, free, same VRF flow
    // =====================================================================

    /**
     * @notice Pre-mint for allowlisted wallets only. Free, uses same VRF random ID.
     *         Active when preMintActive = true AND publicMintActive = false.
     *         Premint counts are SEPARATE from public mint counts.
     *         Premint supply capped at PREMINT_MAX_SUPPLY (210).
     *         Per-wallet limit follows the same maxPerWallet immutable (10).
     */
    function preMint() external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (!preMintActive) revert PreMintInactive();
        if (!allowlisted[msg.sender]) revert NotAllowlisted();
        if (msg.sender != tx.origin) revert EOAOnly();
        if (premintedPerWallet[msg.sender] + premintPendingPerWallet[msg.sender] + mintBlock > maxPerWallet)
            revert MaxPerWallet();
        if (block.number < lastMintBlock[msg.sender] + mintCooldown) revert CooldownActive();
        if (preminted + premintPending + mintBlock > PREMINT_MAX_SUPPLY) revert PreMintSupplyExhausted();
        if (publicMinted + publicPending + preminted + premintPending + mintBlock > publicSupply)
            revert SupplyExhausted();

        premintPendingPerWallet[msg.sender] += mintBlock;
        lastMintBlock[msg.sender] = block.number;
        premintPending += mintBlock;

        requestId = _requestVRF(uint32(mintBlock));

        // Reuse MintRequest struct — feePaid = 0 for free premint, isPreMint = true
        _mintRequests[requestId] = MintRequest(msg.sender, uint32(mintBlock), block.number, 0, true);
        requestStatus[requestId] = CallbackStatus.PENDING;
        _pendingMintRequestIds.push(requestId);

        emit PreMintRequested(msg.sender, requestId);
        return requestId;
    }

    /**
     * @notice Paid mint — parametric quantity (1 to mintBlock).
     *         Total cost = mintPrice × quantity. Exact payment required (no overpayment, no underpayment).
     *         Uses Escrow pattern: ETH held in lockedMintFees until VRF confirms.
     *         Tournament share accrued only on successful callback (pull pattern).
     *         Reverts if mintPrice == 0 (use freeMint).
     * @param quantity Number of tokens to mint (1 to mintBlock).
     */
    function paidMint(uint256 quantity) external payable nonReentrant whenNotPaused returns (uint256 requestId) {
        if (!publicMintActive) revert MintInactive();
        if (mintPrice == 0) revert MintInactive(); // use freeMint when price is 0
        if (quantity == 0 || quantity > mintBlock) revert InvalidMintAmount();
        uint256 totalCost = mintPrice * quantity;
        if (msg.value != totalCost) revert InsufficientMintPayment();
        if (msg.sender != tx.origin) revert EOAOnly();
        if (mintedPerWallet[msg.sender] + pendingPerWallet[msg.sender] + quantity > maxPerWallet) revert MaxPerWallet();
        // No cooldown for paid mints — paying users should not be throttled
        if (publicMinted + publicPending + preminted + premintPending + quantity > publicSupply) revert SupplyExhausted();

        // Escrow: lock the fee until VRF callback
        lockedMintFees += totalCost;

        pendingPerWallet[msg.sender] += quantity;
        publicPending += quantity;

        requestId = _requestVRF(uint32(quantity));

        _mintRequests[requestId] = MintRequest(msg.sender, uint32(quantity), block.number, totalCost, false);
        requestStatus[requestId] = CallbackStatus.PENDING;
        _pendingMintRequestIds.push(requestId);

        emit MintRequested(msg.sender, requestId, msg.value);
        return requestId;
    }

    function devMint(address to, uint256 quantity) external onlyOwner nonReentrant returns (uint256 requestId) {
        if (to == address(0)) revert InvalidForgeAddress();
        if (quantity == 0 || quantity > DEV_BATCH_MAX) revert InvalidBatchSize();
        if (devMinted + devPending + quantity > devReserve) revert SupplyExhausted();

        devPending += quantity;

        requestId = _requestVRF(uint32(quantity));

        _devMintRequests[requestId] = DevMintRequest(to, uint32(quantity), block.number);
        requestStatus[requestId] = CallbackStatus.PENDING;
        _pendingDevRequestIds.push(requestId);

        emit DevMintRequested(to, requestId, quantity);
        return requestId;
    }

    // =====================================================================
    //  VRF CALLBACK — Identico a V3
    // =====================================================================

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        if (_requestProcessed[requestId]) revert DuplicateCallback();
        _requestProcessed[requestId] = true;

        uint256 tokenId;

        // Path dev mint
        DevMintRequest memory devReq = _devMintRequests[requestId];
        if (devReq.to != address(0)) {
            delete _devMintRequests[requestId];
            requestStatus[requestId] = CallbackStatus.SUCCESS;
            emit CallbackProcessed(requestId, CallbackStatus.SUCCESS);

            devPending  -= devReq.amount;
            devMinted   += devReq.amount;
            totalSupply += devReq.amount;

            for (uint32 i = 0; i < devReq.amount;) {
                tokenId = _extractRandomId(randomWords[i]);
                _mint(devReq.to, tokenId);
                emit DevMintFulfilled(devReq.to, tokenId);
                unchecked { ++i; }
            }
            return;
        }

        // Path public mint
        MintRequest memory req = _mintRequests[requestId];
        if (req.minter == address(0)) {
            requestStatus[requestId] = CallbackStatus.FAILED;
            emit CallbackProcessed(requestId, CallbackStatus.FAILED);
            return;
        }

        delete _mintRequests[requestId];
        requestStatus[requestId] = CallbackStatus.SUCCESS;
        emit CallbackProcessed(requestId, CallbackStatus.SUCCESS);

        // Branch: premint vs public mint accounting
        // NOTE: We intentionally do NOT re-check allowlisted[req.minter] here.
        // The allowlist check happened at preMint() time (request creation).
        // If owner removes a wallet after request but before VRF callback,
        // the in-flight mint completes. This is by design — the VRF request
        // was validly authorized. Owner should wait for pending requests
        // before removing a wallet.
        if (req.isPreMint) {
            // Premint path — separate counters
            premintPendingPerWallet[req.minter] -= req.amount;
            premintPending                      -= req.amount;
            unchecked {
                premintedPerWallet[req.minter]  += req.amount;
                preminted                       += req.amount;
                totalSupply                     += req.amount;
            }
        } else {
            // Public mint path — original logic
            // Escrow release: fee confirmed, accrue tournament share (pull pattern)
            if (req.feePaid > 0) {
                lockedMintFees -= req.feePaid;
                if (tournamentContract != address(0) && tournamentSplitBps > 0) {
                    uint256 tShare = (req.feePaid * tournamentSplitBps) / 10000;
                    tournamentBalance += tShare;
                    emit PaidMintRevenue(req.feePaid, tShare, req.feePaid - tShare);
                }
            }

            pendingPerWallet[req.minter] -= req.amount;
            publicPending               -= req.amount;
            unchecked {
                mintedPerWallet[req.minter] += req.amount;
                publicMinted                += req.amount;
                totalSupply                 += req.amount;
            }
        }

        for (uint32 i = 0; i < req.amount;) {
            tokenId = _extractRandomId(randomWords[i]);
            _mint(req.minter, tokenId);
            emit MintFulfilled(req.minter, tokenId);
            unchecked { ++i; }
        }
    }

    function _extractRandomId(uint256 _random) private returns (uint256) {
        if (_remainingIds == 0) revert NoMoreIdsAvailable();

        uint256 randomIndex = _random % _remainingIds;
        uint256 tokenId = _shuffledIds[randomIndex];
        if (tokenId == 0) tokenId = randomIndex + 1;

        uint256 lastId = _shuffledIds[_remainingIds - 1];
        if (lastId == 0) lastId = _remainingIds;

        _shuffledIds[randomIndex] = lastId;
        _remainingIds--;
        return tokenId;
    }

    // =====================================================================
    //  BATCH BURN — Identico a V3
    // =====================================================================

    function batchBurnFrom(address tokenOwner, uint256[] calldata tokenIds) external whenNotPaused {
        if (tokenIds.length > 50) revert ExceededMaxBatchSize();
        if (msg.sender != forgeContract && !isApprovedForAll(tokenOwner, msg.sender)) {
            revert NotApprovedOperator();
        }

        for (uint256 i = 0; i < tokenIds.length;) {
            if (_ownerOf(tokenIds[i]) != tokenOwner) revert BatchBurnOwnerMismatch(tokenIds[i]);
            _update(address(0), tokenIds[i], address(0));
            unchecked { ++i; }
        }
        totalSupply -= tokenIds.length;
    }

    function burn(uint256 tokenId) public virtual {
        _update(address(0), tokenId, _msgSender());
        unchecked { totalSupply--; }
    }

    // =====================================================================
    //  TOKEN URI — Reveal per specie (identico a V3)
    // =====================================================================

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        uint8 speciesId = getSpeciesId(tokenId);
        if (!speciesRevealed[speciesId]) return notRevealedURI;
        string memory uri = speciesURI[speciesId];
        return string(abi.encodePacked(uri, tokenId.toString(), JSON_EXT));
    }

    // =====================================================================
    //  ADMIN: MINT STATUS
    // =====================================================================

    function setMintStatus(bool _public) external onlyOwner {
        if (_public && preMintActive) revert BothMintsActive();
        publicMintActive = _public;
        emit MintStatusChanged(_public);
    }

    // =====================================================================
    //  ADMIN: PREMINT ALLOWLIST
    // =====================================================================

    /**
     * @notice Toggle premint phase. PreMint and PublicMint are mutually exclusive:
     *         preMint works when preMintActive=true.
     *         freeMint/paidMint work when publicMintActive=true.
     *         Both can be false (no mint at all).
     */
    function setPreMintStatus(bool _active) external onlyOwner {
        if (_active && publicMintActive) revert BothMintsActive();
        preMintActive = _active;
        emit PreMintStatusChanged(_active);
    }

    /**
     * @notice Add wallets to the allowlist. Max 21 total. Skips duplicates & zero silently.
     *         Single-pass: writes to mapping, then checks total. Revert rolls back all writes.
     *         Input duplicates handled naturally — second write sees mapping already set, skips.
     * @param wallets Array of addresses to add.
     */
    function setAllowlist(address[] calldata wallets) external onlyOwner {
        if (wallets.length == 0) revert EmptyAllowlist();
        if (wallets.length > PREMINT_MAX_WALLETS) revert AllowlistTooLarge();

        uint256 added = 0;
        for (uint256 i = 0; i < wallets.length;) {
            if (wallets[i] != address(0) && !allowlisted[wallets[i]]) {
                allowlisted[wallets[i]] = true;
                unchecked { added++; }
            }
            unchecked { ++i; }
        }

        // Revert rolls back all mapping writes if over limit
        if (allowlistCount + added > PREMINT_MAX_WALLETS) revert AllowlistFull();
        allowlistCount += added;
        emit AllowlistUpdated(wallets, true);
    }

    /**
     * @notice Remove a single wallet from the allowlist.
     * @param wallet Address to remove.
     */
    function removeFromAllowlist(address wallet) external onlyOwner {
        if (!allowlisted[wallet]) revert NotInAllowlist();
        allowlisted[wallet] = false;
        allowlistCount--;
        emit AllowlistRemoved(wallet);
    }

    // isAllowlisted() REMOVED — use public mapping allowlisted(address) directly
    // premintStats() REMOVED — all fields are individually public: preminted, premintPending,
    //   PREMINT_MAX_SUPPLY, allowlistCount, preMintActive

    // =====================================================================
    //  SIGILLO DELLE SPECIE — Identico a V3 (usa totalSpecies parametrico)
    // =====================================================================

    function revealSpecies(uint8 speciesId) external onlyOwner {
        if (speciesId >= totalSpecies) revert InvalidSpeciesId();
        if (speciesRevealed[speciesId]) revert SpeciesAlreadyRevealed();
        if (bytes(speciesURI[speciesId]).length == 0) revert URINotSet();
        speciesRevealed[speciesId] = true;
        emit SpeciesRevealed(speciesId);
    }

    function sealSpecies(uint8 speciesId) external onlyOwner {
        if (speciesId >= totalSpecies) revert InvalidSpeciesId();
        if (!speciesRevealed[speciesId]) revert SpeciesNotRevealed();
        if (speciesSealed[speciesId]) revert SpeciesAlreadySealed();
        speciesSealed[speciesId] = true;
        unchecked { sealedCount++; }
        emit SpeciesSealed(speciesId, sealedCount);
        if (sealedCount == totalSpecies) {
            sigilloNero = true;
            emit SigilloNeroEvent();
        }
    }

    function sigilloNeroForceAll() external onlyOwner {
        if (sigilloNero) revert SigilloNeroAlreadyDone();
        for (uint8 i = 0; i < totalSpecies;) {
            if (bytes(speciesURI[i]).length == 0) revert SigilloNeroURIMissing(i);
            unchecked { ++i; }
        }
        uint8 runningCount = sealedCount;
        for (uint8 i = 0; i < totalSpecies;) {
            if (!speciesSealed[i]) {
                if (!speciesRevealed[i]) {
                    speciesRevealed[i] = true;
                    emit SpeciesRevealed(i);
                }
                speciesSealed[i] = true;
                unchecked { runningCount++; }
                emit SpeciesSealed(i, runningCount);
            }
            unchecked { ++i; }
        }
        sealedCount = totalSpecies;
        sigilloNero = true;
        emit SigilloNeroEvent();
    }

    // =====================================================================
    //  URI SETTERS — Identico a V3
    // =====================================================================

    function setSpeciesURI(uint8 speciesId, string calldata _uri) external onlyOwner {
        if (speciesId >= totalSpecies) revert InvalidSpeciesId();
        if (speciesSealed[speciesId]) revert SpeciesURISealed();
        if (bytes(_uri).length == 0) revert EmptyURI();
        speciesURI[speciesId] = _uri;
        emit SpeciesURIUpdated(speciesId);
    }

    function setNotRevealedURI(string calldata _uri) external onlyOwner {
        if (sigilloNero) revert SigilloNeroAlreadyDone();
        if (bytes(_uri).length == 0) revert EmptyURI();
        notRevealedURI = _uri;
        emit NotRevealedURIUpdated(_uri);
    }

    // =====================================================================
    //  WITHDRAW — Safe (escrow-aware)
    // =====================================================================

    /// @notice Owner withdraw — excludes escrowed mint fees, tournament balance, and pending refunds
    function withdraw() external onlyOwner nonReentrant {
        uint256 reserved = lockedMintFees + tournamentBalance + totalPendingRefunds;
        // FIX M-04: Anti-underflow — se balance <= reserved, niente da prelevare
        if (address(this).balance <= reserved) revert NothingToWithdraw();
        uint256 availableBalance = address(this).balance - reserved;
        (bool success, ) = payable(owner()).call{value: availableBalance}("");
        if (!success) revert WithdrawFailed();
    }

    /// @notice Pull tournament funds — callable by anyone, sends to tournamentContract
    function withdrawTournamentFunds() external nonReentrant {
        if (tournamentContract == address(0)) revert InvalidTournamentAddress();
        uint256 amount = tournamentBalance;
        if (amount == 0) revert NothingToWithdraw();
        tournamentBalance = 0;
        (bool success, ) = tournamentContract.call{value: amount}("");
        if (!success) revert WithdrawFailed();
    }

    // =====================================================================
    //  ERC721C + ERC2981 — Identico a V3
    // =====================================================================

    function supportsInterface(bytes4 interfaceId) public view override(ERC721C, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _requireCallerIsContractOwner() internal view virtual override {
        if (msg.sender != owner()) revert InvalidConfig();
    }

    // =====================================================================
    //  "GOD MODE" FORGE — Identico a V3
    // =====================================================================

    function setForgeContract(address _forge) external onlyOwner {
        if (contractsLocked) revert ContractsAlreadyLocked();
        if (_forge == address(0)) revert InvalidForgeAddress();
        address oldForge = forgeContract;
        forgeContract = _forge;
        emit ForgeContractUpdated(oldForge, _forge);
    }

    function lockContracts() external onlyOwner {
        if (contractsLocked) revert ContractsAlreadyLocked();
        contractsLocked = true;
        emit ContractsLocked();
    }

    // =====================================================================
    //  BATCH REFUND — Identico a V3
    // =====================================================================

    function refundAllExpiredDevMints() external onlyOwner nonReentrant returns (uint256 refunded) {
        uint256 len = _pendingDevRequestIds.length;
        uint256 i = 0;
        while (i < len) {
            uint256 reqId = _pendingDevRequestIds[i];
            DevMintRequest memory req = _devMintRequests[reqId];
            if (req.to == address(0) || _requestProcessed[reqId]) {
                _pendingDevRequestIds[i] = _pendingDevRequestIds[len - 1];
                _pendingDevRequestIds.pop();
                len--;
                continue;
            }
            if (block.number < req.requestBlock + MINT_VRF_TIMEOUT) { i++; continue; }
            _requestProcessed[reqId] = true;
            requestStatus[reqId] = CallbackStatus.FAILED;
            delete _devMintRequests[reqId];
            devPending -= req.amount;
            emit DevMintRefunded(reqId, req.to, req.amount);
            _pendingDevRequestIds[i] = _pendingDevRequestIds[len - 1];
            _pendingDevRequestIds.pop();
            len--;
            refunded++;
        }
    }

    function refundAllExpiredMints(uint256 maxIterations) external nonReentrant returns (uint256) {
        return _processBatchRefund(address(0), maxIterations);
    }

    function refundExpiredMintsForUser(address user, uint256 maxIterations) external onlyOwner nonReentrant returns (uint256) {
        return _processBatchRefund(user, maxIterations);
    }

    function _processBatchRefund(address userFilter, uint256 maxIterations) private returns (uint256 refunded) {
        uint256 len = _pendingMintRequestIds.length;
        uint256 i = 0;
        uint256 iterations = 0;

        while (i < len) {
            if (maxIterations > 0 && iterations >= maxIterations) break;
            unchecked { iterations++; }

            uint256 reqId = _pendingMintRequestIds[i];
            MintRequest memory req = _mintRequests[reqId];

            if (req.minter == address(0) || _requestProcessed[reqId]) {
                _pendingMintRequestIds[i] = _pendingMintRequestIds[len - 1];
                _pendingMintRequestIds.pop();
                len--;
                continue;
            }
            if (block.number < req.requestBlock + MINT_VRF_TIMEOUT) { i++; continue; }
            if (userFilter != address(0) && req.minter != userFilter) { i++; continue; }

            uint256 feeToRefund = req.feePaid;
            if (feeToRefund > 0) lockedMintFees -= feeToRefund;
            _requestProcessed[reqId] = true;
            requestStatus[reqId] = CallbackStatus.FAILED;
            delete _mintRequests[reqId];

            _releasePending(req.minter, req.amount, req.isPreMint);
            emit MintRefunded(reqId, req.minter, req.amount);

            if (feeToRefund > 0) {
                (bool ok, ) = payable(req.minter).call{value: feeToRefund}("");
                if (!ok) {
                    pendingRefunds[req.minter] += feeToRefund;
                    totalPendingRefunds += feeToRefund;
                    emit RefundCredited(req.minter, feeToRefund);
                }
            }

            _pendingMintRequestIds[i] = _pendingMintRequestIds[len - 1];
            _pendingMintRequestIds.pop();
            len--;
            refunded++;
        }
    }

    function pendingDevRequestCount() external view returns (uint256) { return _pendingDevRequestIds.length; }
    function pendingMintRequestCount() external view returns (uint256) { return _pendingMintRequestIds.length; }

    // =====================================================================
    //  VRF CONFIG — Identico a V3
    // =====================================================================

    function setCallbackGasLimit(uint32 _newLimit) external onlyOwner {
        if (_newLimit < 100000 || _newLimit > 5000000) revert GasLimitOutOfBounds();
        uint32 oldLimit = callbackGasLimit;
        callbackGasLimit = _newLimit;
        emit CallbackGasLimitChanged(oldLimit, _newLimit);
    }

    function setRequestConfirmations(uint16 _newConfirmations) external onlyOwner {
        if (_newConfirmations < 1 || _newConfirmations > 200) revert ConfirmationsOutOfBounds();
        uint16 oldConf = requestConfirmations;
        requestConfirmations = _newConfirmations;
        emit RequestConfirmationsChanged(oldConf, _newConfirmations);
    }

    function setVRFNativePayment(bool _nativePayment) external onlyOwner {
        vrfNativePayment = _nativePayment;
        emit VRFNativePaymentChanged(_nativePayment);
    }

    // =====================================================================
    //  ROYALTY — Identico a V3
    // =====================================================================

    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        if (receiver == address(0)) revert InvalidRoyaltyReceiver();
        if (feeNumerator > 1000) revert RoyaltyTooHigh();
        _setDefaultRoyalty(receiver, feeNumerator);
        emit RoyaltyUpdated(receiver, feeNumerator);
    }

    function updateSubscriptionId(uint256 newId) external onlyOwner {
        if (newId == 0) revert InvalidSubscriptionId();
        uint256 oldId = s_subscriptionId;
        s_subscriptionId = newId;
        emit SubscriptionIdUpdated(oldId, newId);
    }

    // =====================================================================
    //  "BUCO NERO" VRF PROTECTION — Retry & Refund (identico a V3)
    // =====================================================================

    /// @dev Shared validation for retry/refund dev mint.
    function _validateAndExpireDevMint(uint256 requestId) private returns (DevMintRequest memory req) {
        req = _devMintRequests[requestId];
        if (req.to == address(0)) revert MintRequestNotFound();
        if (_requestProcessed[requestId]) revert MintRequestAlreadyProcessed();
        if (block.number < req.requestBlock + MINT_VRF_TIMEOUT) revert MintRequestNotTimedOut();
        _requestProcessed[requestId] = true;
        requestStatus[requestId] = CallbackStatus.FAILED;
        delete _devMintRequests[requestId];
    }

    function retryDevMint(uint256 requestId) external onlyOwner nonReentrant returns (uint256 newRequestId) {
        DevMintRequest memory req = _validateAndExpireDevMint(requestId);
        newRequestId = _requestVRF(req.amount);
        _devMintRequests[newRequestId] = DevMintRequest(req.to, req.amount, block.number);
        requestStatus[newRequestId] = CallbackStatus.PENDING;
        _pendingDevRequestIds.push(newRequestId);
        emit MintRetried(requestId, newRequestId, req.to);
    }

    function refundFailedDevMint(uint256 requestId) external onlyOwner nonReentrant {
        DevMintRequest memory req = _validateAndExpireDevMint(requestId);
        devPending -= req.amount;
        emit DevMintRefunded(requestId, req.to, req.amount);
    }

    /// @dev Shared validation for retry/refund mint — loads, validates, marks failed, deletes.
    function _validateAndExpireMint(uint256 requestId) private returns (MintRequest memory req) {
        req = _mintRequests[requestId];
        if (req.minter == address(0)) revert MintRequestNotFound();
        if (_requestProcessed[requestId]) revert MintRequestAlreadyProcessed();
        if (block.number < req.requestBlock + MINT_VRF_TIMEOUT) revert MintRequestNotTimedOut();
        if (msg.sender != req.minter) revert NotMintRequester();
        _requestProcessed[requestId] = true;
        requestStatus[requestId] = CallbackStatus.FAILED;
        delete _mintRequests[requestId];
    }

    /// @dev Release pending counters for a mint request (premint or public).
    function _releasePending(address minter, uint32 amount, bool isPreMintReq) private {
        if (isPreMintReq) {
            premintPendingPerWallet[minter] -= amount;
            premintPending -= amount;
        } else {
            pendingPerWallet[minter] -= amount;
            publicPending -= amount;
        }
    }

    function retryMint(uint256 requestId) external nonReentrant returns (uint256 newRequestId) {
        MintRequest memory req = _validateAndExpireMint(requestId);
        newRequestId = _requestVRF(req.amount);
        _mintRequests[newRequestId] = MintRequest(req.minter, req.amount, block.number, req.feePaid, req.isPreMint);
        requestStatus[newRequestId] = CallbackStatus.PENDING;
        _pendingMintRequestIds.push(newRequestId);
        emit MintRetried(requestId, newRequestId, req.minter);
    }

    function refundFailedMint(uint256 requestId) external nonReentrant {
        MintRequest memory req = _validateAndExpireMint(requestId);
        uint256 feeToRefund = req.feePaid;
        if (feeToRefund > 0) lockedMintFees -= feeToRefund;
        _releasePending(req.minter, req.amount, req.isPreMint);
        emit MintRefunded(requestId, req.minter, req.amount);
        if (feeToRefund > 0) {
            (bool ok, ) = payable(req.minter).call{value: feeToRefund}("");
            if (!ok) {
                pendingRefunds[req.minter] += feeToRefund;
                totalPendingRefunds += feeToRefund;
                emit RefundCredited(req.minter, feeToRefund);
            }
        }
    }

    /// @notice Claim ETH from failed push refunds (multisig-safe)
    function claimRefund() external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender];
        if (amount == 0) revert NoPendingRefund();
        pendingRefunds[msg.sender] = 0;
        totalPendingRefunds -= amount;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert WithdrawFailed();
        emit RefundClaimed(msg.sender, amount);
    }

    // =====================================================================
    //  TOURNAMENT LOCK — F0
    // =====================================================================

    /**
     * @notice Lock or unlock tokens for tournament. Only callable by tournamentContract.
     * @param tokenIds Array of token IDs to lock/unlock.
     * @param locked true = lock, false = unlock.
     */
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
     * @notice Override _update to block transfer and burn of locked tokens.
     * @dev Mints (from == address(0)) are allowed. All other operations on locked tokens revert.
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);
        // Allow mints (from is zero), block everything else for locked tokens
        if (from != address(0) && tokenLocked[tokenId]) revert TokenLocked(tokenId);
        return super._update(to, tokenId, auth);
    }

    // =====================================================================
    //  TOURNAMENT & PAID MINT SETTERS — F0
    // =====================================================================

    function setMintPrice(uint256 _price) external onlyOwner {
        uint256 old = mintPrice;
        mintPrice = _price;
        emit MintPriceUpdated(old, _price);
    }

    function setTournamentContract(address _tournament) external onlyOwner {
        if (_tournament == address(0)) revert InvalidTournamentAddress();
        address old = tournamentContract;
        tournamentContract = _tournament;
        emit TournamentContractUpdated(old, _tournament);
    }

    function setTournamentSplitBps(uint16 _bps) external onlyOwner {
        if (_bps > 10000) revert SplitBpsTooHigh();
        uint16 old = tournamentSplitBps;
        tournamentSplitBps = _bps;
        emit TournamentSplitUpdated(old, _bps);
    }

    // =====================================================================
    //  INTERNAL: VRF REQUEST HELPER — STEP 1 size optimization
    // =====================================================================

    function _requestVRF(uint32 numWords) private returns (uint256) {
        uint256 reqId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: vrfNativePayment}))
            })
        );
        if (reqId == 0) revert InvalidVRFRequest();
        return reqId;
    }

    /// @notice Accept ETH (for tournament prize pool returns, etc.)
    receive() external payable {}
}
