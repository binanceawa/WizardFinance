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
        if (amount > WF_MAX_DEPOSIT_SINGLE) revert WF_DepositTooHigh();

        uint256 feeWei = (amount * WF_ADVISOR_FEE_BPS) / WF_BPS;
        uint256 platformWei = (amount * WF_PLATFORM_FEE_BPS) / WF_BPS;
        uint256 net = amount - feeWei - platformWei;
        totalFeesCollected += feeWei + platformWei;

        if (token == address(0)) {
            if (msg.value != amount) revert WF_TransferFailed();
            if (feeWei > 0) _sendEth(wfAdvisors[p.advisorId].wallet, feeWei);
            if (platformWei > 0) _sendEth(wfFeeVault, platformWei);
        } else {
            _pullToken(token, msg.sender, amount);
            if (feeWei > 0) _pushToken(token, wfAdvisors[p.advisorId].wallet, feeWei);
            if (platformWei > 0) _pushToken(token, wfFeeVault, platformWei);
        }

        p.totalDeposited += amount;
        totalDeposits += amount;
        portfolioTokenBalance[portfolioId][token] += net;
        portfolioAllocations[portfolioId].push(WFAllocation({ token: token, amount: net, atBlock: block.number }));
        _updateClientTier(msg.sender);
        wfAdvisors[p.advisorId].totalFeesEarned += feeWei;
        emit WF_Deposit(portfolioId, token, amount, feeWei + platformWei);
        emit WF_AllocationRecorded(portfolioId, token, net);
    }

    function withdraw(uint256 portfolioId, address token, uint256 amount) external nonReentrant {
        if (portfolioId == 0 || portfolioId > portfolioCount) revert WF_InvalidPortfolioId();
        WFPortfolio storage p = wfPortfolios[portfolioId];
        if (p.closed) revert WF_PortfolioClosed();
        if (p.client != msg.sender) revert WF_NotPortfolioClient();
        if (portfolioTokenBalance[portfolioId][token] < amount) revert WF_InsufficientBalance();

        p.totalWithdrawn += amount;
        totalWithdrawn += amount;
        portfolioTokenBalance[portfolioId][token] -= amount;

        if (token == address(0)) {
            _sendEth(msg.sender, amount);
        } else {
            _pushToken(token, msg.sender, amount);
        }
        emit WF_Withdraw(portfolioId, token, amount);
    }

    function closePortfolio(uint256 portfolioId) external {
        if (portfolioId == 0 || portfolioId > portfolioCount) revert WF_InvalidPortfolioId();
        WFPortfolio storage p = wfPortfolios[portfolioId];
        if (p.closed) revert WF_PortfolioClosed();
        if (msg.sender != owner && msg.sender != p.client && msg.sender != wfAdvisors[p.advisorId].wallet) revert WF_Unauthorized();
        p.closed = true;
        emit WF_PortfolioClosed(portfolioId);
    }

    function setPaused(bool p) external onlyOwner {
        wfPaused = p;
        emit WF_PauseToggled(p);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert WF_ZeroAddress();
        emit WF_OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function getPortfolio(uint256 portfolioId) external view returns (
        address client_,
        uint256 advisorId_,
        uint256 totalDeposited_,
        uint256 totalWithdrawn_,
        uint256 createdAtBlock_,
        bool closed_
    ) {
        if (portfolioId == 0 || portfolioId > portfolioCount) revert WF_InvalidPortfolioId();
        WFPortfolio storage p = wfPortfolios[portfolioId];
        return (p.client, p.advisorId, p.totalDeposited, p.totalWithdrawn, p.createdAtBlock, p.closed);
    }

    function getAdvisor(uint256 advisorId) external view returns (
        address wallet_,
        bool active_,
        uint256 totalClients_,
        uint256 totalFeesEarned_,
        uint256 registeredAtBlock_
    ) {
        if (advisorId == 0 || advisorId > advisorCount) revert WF_InvalidAdvisorId();
        WFAdvisor storage a = wfAdvisors[advisorId];
        return (a.wallet, a.active, a.totalClients, a.totalFeesEarned, a.registeredAtBlock);
    }

    function getPortfolioBalance(uint256 portfolioId, address token) external view returns (uint256) {
        return portfolioTokenBalance[portfolioId][token];
    }

