// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title WizardFinance — Advice and investment platform
/// @notice On-chain registry for advisors, client portfolios and allocations. Rhubarb quarter alignment for fee accrual.
/// @dev No delegatecall; reentrancy guard; immutable config; mainnet-safe.

contract WizardFinance {
    uint256 private _lock;

    uint256 public constant WF_BPS = 10000;
    uint256 public constant WF_MAX_ADVISORS = 128;
    uint256 public constant WF_MAX_PORTFOLIOS_PER_CLIENT = 24;
    uint256 public constant WF_ADVISOR_FEE_BPS = 200;
    uint256 public constant WF_PLATFORM_FEE_BPS = 50;
    uint256 public constant WF_MIN_DEPOSIT = 0.01 ether;
    uint256 public constant WF_MAX_DEPOSIT_SINGLE = 1000 ether;
    uint256 public constant WF_TIER_BRONZE_MIN = 0.1 ether;
    uint256 public constant WF_TIER_SILVER_MIN = 1 ether;
    uint256 public constant WF_TIER_GOLD_MIN = 10 ether;
    uint256 public constant WF_TIER_PLATINUM_MIN = 100 ether;
    uint256 public constant WF_SESSION_COOLDOWN_BLOCKS = 100;
    uint256 public constant WF_ADVICE_CAP_PER_SESSION = 50;
    bytes32 public constant WF_ADVISOR_REGISTER_TYPEHASH = keccak256("WF_AdvisorRegister(address advisor,uint256 nonce)");
    bytes32 public constant WF_ALLOCATE_TYPEHASH = keccak256("WF_Allocate(uint256 portfolioId,address token,uint256 amount,uint256 nonce)");

    address public immutable wfTreasury;
    address public immutable wfRegistryKeeper;
    address public immutable wfFeeVault;
    uint256 public immutable wfGenesisBlock;
    bytes32 public immutable wfDomainSeparator;

    address public owner;
    bool public wfPaused;
    uint256 public advisorCount;
    uint256 public portfolioCount;
    uint256 public totalDeposits;
    uint256 public totalWithdrawn;
    uint256 public totalFeesCollected;

    struct WFAdvisor {
        address wallet;
        bool active;
        uint256 totalClients;
        uint256 totalFeesEarned;
        uint256 registeredAtBlock;
    }
    mapping(uint256 => WFAdvisor) public wfAdvisors;
    mapping(address => uint256) public advisorIdByWallet;

    struct WFPortfolio {
        address client;
        uint256 advisorId;
        uint256 totalDeposited;
        uint256 totalWithdrawn;
        uint256 createdAtBlock;
        bool closed;
    }
    mapping(uint256 => WFPortfolio) public wfPortfolios;
    mapping(address => uint256[]) public clientPortfolioIds;

    struct WFAllocation {
        address token;
        uint256 amount;
        uint256 atBlock;
    }
    mapping(uint256 => WFAllocation[]) public portfolioAllocations;
    mapping(uint256 => mapping(address => uint256)) public portfolioTokenBalance;

    mapping(address => uint256) public clientNonce;
    mapping(uint256 => uint256) public lastAdviceBlockByAdvisor;
    mapping(address => uint8) public clientTier;

    error WF_Unauthorized();
    error WF_Paused();
    error WF_Reentrancy();
    error WF_ZeroAddress();
    error WF_ZeroAmount();
    error WF_AdvisorNotFound();
    error WF_AdvisorInactive();
    error WF_PortfolioNotFound();
    error WF_PortfolioClosed();
    error WF_NotPortfolioClient();
    error WF_NotPortfolioAdvisor();
    error WF_MaxAdvisorsReached();
    error WF_MaxPortfoliosReached();
    error WF_DepositTooLow();
    error WF_DepositTooHigh();
    error WF_InsufficientBalance();
    error WF_TransferFailed();
    error WF_CooldownActive();
    error WF_InvalidAdvisorId();
    error WF_InvalidPortfolioId();
    error WF_AlreadyAdvisor();

    event WF_AdvisorRegistered(uint256 indexed advisorId, address indexed advisor, uint256 atBlock);
    event WF_AdvisorDeactivated(uint256 indexed advisorId);
    event WF_PortfolioCreated(uint256 indexed portfolioId, address indexed client, uint256 advisorId, uint256 atBlock);
    event WF_PortfolioClosed(uint256 indexed portfolioId);
    event WF_Deposit(uint256 indexed portfolioId, address indexed token, uint256 amount, uint256 feeWei);
    event WF_Withdraw(uint256 indexed portfolioId, address indexed token, uint256 amount);
    event WF_AllocationRecorded(uint256 indexed portfolioId, address indexed token, uint256 amount);
    event WF_PauseToggled(bool paused);
    event WF_OwnershipTransferred(address indexed previous, address indexed next);
    event WF_ClientTierUpdated(address indexed client, uint8 tier);

    modifier onlyOwner() {
        if (msg.sender != owner) revert WF_Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (wfPaused) revert WF_Paused();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 0) revert WF_Reentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }

    constructor() {
        wfTreasury = 0xf4e5d6c7b8a9012345678901234567890abcdef01;
        wfRegistryKeeper = 0xe5d6c7b8a9012345678901234567890abcdef01234;
        wfFeeVault = 0xd6c7b8a9012345678901234567890abcdef0123456;
        wfGenesisBlock = block.number;
        wfDomainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("WizardFinance"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        owner = msg.sender;
    }

    function registerAdvisor() external whenNotPaused nonReentrant returns (uint256 advisorId) {
        if (advisorIdByWallet[msg.sender] != 0) revert WF_AlreadyAdvisor();
        if (advisorCount >= WF_MAX_ADVISORS) revert WF_MaxAdvisorsReached();
        advisorCount++;
        advisorId = advisorCount;
        wfAdvisors[advisorId] = WFAdvisor({
            wallet: msg.sender,
            active: true,
            totalClients: 0,
            totalFeesEarned: 0,
            registeredAtBlock: block.number
        });
        advisorIdByWallet[msg.sender] = advisorId;
        emit WF_AdvisorRegistered(advisorId, msg.sender, block.number);
        return advisorId;
    }

    function deactivateAdvisor(uint256 advisorId) external onlyOwner {
        if (advisorId == 0 || advisorId > advisorCount) revert WF_InvalidAdvisorId();
        wfAdvisors[advisorId].active = false;
        emit WF_AdvisorDeactivated(advisorId);
    }

    function createPortfolio(uint256 advisorId) external whenNotPaused nonReentrant returns (uint256 portfolioId) {
        if (advisorId == 0 || advisorId > advisorCount) revert WF_InvalidAdvisorId();
        if (!wfAdvisors[advisorId].active) revert WF_AdvisorInactive();
        uint256[] storage ids = clientPortfolioIds[msg.sender];
        if (ids.length >= WF_MAX_PORTFOLIOS_PER_CLIENT) revert WF_MaxPortfoliosReached();
        portfolioCount++;
        portfolioId = portfolioCount;
        wfPortfolios[portfolioId] = WFPortfolio({
            client: msg.sender,
            advisorId: advisorId,
            totalDeposited: 0,
            totalWithdrawn: 0,
            createdAtBlock: block.number,
            closed: false
        });
        clientPortfolioIds[msg.sender].push(portfolioId);
        wfAdvisors[advisorId].totalClients++;
        emit WF_PortfolioCreated(portfolioId, msg.sender, advisorId, block.number);
        return portfolioId;
    }

    function deposit(uint256 portfolioId, address token, uint256 amount) external payable whenNotPaused nonReentrant {
        if (portfolioId == 0 || portfolioId > portfolioCount) revert WF_InvalidPortfolioId();
        WFPortfolio storage p = wfPortfolios[portfolioId];
        if (p.closed) revert WF_PortfolioClosed();
        if (p.client != msg.sender) revert WF_NotPortfolioClient();
        if (amount < WF_MIN_DEPOSIT) revert WF_DepositTooLow();
