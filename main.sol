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

    function getClientPortfolioIds(address client) external view returns (uint256[] memory) {
        return clientPortfolioIds[client];
    }

    function getGlobalStats() external view returns (
        uint256 totalDeposits_,
        uint256 totalWithdrawn_,
        uint256 totalFeesCollected_,
        uint256 advisorCount_,
        uint256 portfolioCount_,
        bool paused_
    ) {
        return (totalDeposits, totalWithdrawn, totalFeesCollected, advisorCount, portfolioCount, wfPaused);
    }

    function _updateClientTier(address client) internal {
        uint256 total = 0;
        uint256[] storage ids = clientPortfolioIds[client];
        for (uint256 i = 0; i < ids.length; i++) {
            total += wfPortfolios[ids[i]].totalDeposited - wfPortfolios[ids[i]].totalWithdrawn;
        }
        uint8 newTier = 0;
        if (total >= WF_TIER_PLATINUM_MIN) newTier = 4;
        else if (total >= WF_TIER_GOLD_MIN) newTier = 3;
        else if (total >= WF_TIER_SILVER_MIN) newTier = 2;
        else if (total >= WF_TIER_BRONZE_MIN) newTier = 1;
        if (newTier != clientTier[client]) {
            clientTier[client] = newTier;
            emit WF_ClientTierUpdated(client, newTier);
        }
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert WF_TransferFailed();
    }

    function _pullToken(address token, address from, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Min.transferFrom.selector, from, address(this), amount));
        if (!ok || (data.length >= 32 && abi.decode(data, (bool)) == false)) revert WF_TransferFailed();
    }

    function _pushToken(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Min.transfer.selector, to, amount));
        if (!ok || (data.length >= 32 && abi.decode(data, (bool)) == false)) revert WF_TransferFailed();
    }

    uint256 public constant WF_ADVISOR_NAME_MAX_LEN = 64;
    uint256 public constant WF_PORTFOLIO_NOTE_MAX_LEN = 256;
    uint256 public constant WF_TIER_NONE = 0;
    uint256 public constant WF_TIER_BRONZE_ID = 1;
    uint256 public constant WF_TIER_SILVER_ID = 2;
    uint256 public constant WF_TIER_GOLD_ID = 3;
    uint256 public constant WF_TIER_PLATINUM_ID = 4;
    bytes32 public constant WF_PORTFOLIO_CREATE_TYPEHASH = keccak256("WF_PortfolioCreate(address client,uint256 advisorId,uint256 nonce)");

    function getPortfolioNet(uint256 portfolioId) external view returns (uint256) {
        if (portfolioId == 0 || portfolioId > portfolioCount) revert WF_InvalidPortfolioId();
        WFPortfolio storage p = wfPortfolios[portfolioId];
        return p.totalDeposited - p.totalWithdrawn;
    }

    function getClientTier(address client) external view returns (uint8) {
        return clientTier[client];
    }

    function getTierForTotal(uint256 totalWei) external pure returns (uint8) {
        if (totalWei >= WF_TIER_PLATINUM_MIN) return 4;
        if (totalWei >= WF_TIER_GOLD_MIN) return 3;
        if (totalWei >= WF_TIER_SILVER_MIN) return 2;
        if (totalWei >= WF_TIER_BRONZE_MIN) return 1;
        return 0;
    }

    function getAdvisorId(address wallet) external view returns (uint256) {
        return advisorIdByWallet[wallet];
    }

    function isAdvisorActive(uint256 advisorId) external view returns (bool) {
        if (advisorId == 0 || advisorId > advisorCount) return false;
        return wfAdvisors[advisorId].active;
    }

    function getAdvisorWallet(uint256 advisorId) external view returns (address) {
        if (advisorId == 0 || advisorId > advisorCount) return address(0);
        return wfAdvisors[advisorId].wallet;
    }

    function getPortfolioClient(uint256 portfolioId) external view returns (address) {
        if (portfolioId == 0 || portfolioId > portfolioCount) revert WF_InvalidPortfolioId();
        return wfPortfolios[portfolioId].client;
    }

    function getPortfolioAdvisorId(uint256 portfolioId) external view returns (uint256) {
        if (portfolioId == 0 || portfolioId > portfolioCount) revert WF_InvalidPortfolioId();
        return wfPortfolios[portfolioId].advisorId;
    }

    function getPortfolioClosed(uint256 portfolioId) external view returns (bool) {
        if (portfolioId == 0 || portfolioId > portfolioCount) return true;
        return wfPortfolios[portfolioId].closed;
    }

    function getAllocationCount(uint256 portfolioId) external view returns (uint256) {
        return portfolioAllocations[portfolioId].length;
    }

    function getAllocationAt(uint256 portfolioId, uint256 index) external view returns (address token_, uint256 amount_, uint256 atBlock_) {
        WFAllocation storage a = portfolioAllocations[portfolioId][index];
        return (a.token, a.amount, a.atBlock);
    }

    function getImmutableAddresses() external view returns (address treasury_, address keeper_, address feeVault_) {
        return (wfTreasury, wfRegistryKeeper, wfFeeVault);
    }

    function getGenesisBlock() external view returns (uint256) {
        return wfGenesisBlock;
    }

    function getDomainSeparator() external view returns (bytes32) {
        return wfDomainSeparator;
    }

    function getConstantsBundle() external pure returns (
        uint256 bps,
        uint256 maxAdvisors,
        uint256 maxPortfoliosPerClient,
        uint256 advisorFeeBps,
        uint256 platformFeeBps,
        uint256 minDeposit,
        uint256 maxDepositSingle,
        uint256 tierBronzeMin,
        uint256 tierSilverMin,
        uint256 tierGoldMin,
        uint256 tierPlatinumMin
    ) {
        return (
            WF_BPS,
            WF_MAX_ADVISORS,
            WF_MAX_PORTFOLIOS_PER_CLIENT,
            WF_ADVISOR_FEE_BPS,
            WF_PLATFORM_FEE_BPS,
            WF_MIN_DEPOSIT,
            WF_MAX_DEPOSIT_SINGLE,
            WF_TIER_BRONZE_MIN,
            WF_TIER_SILVER_MIN,
            WF_TIER_GOLD_MIN,
            WF_TIER_PLATINUM_MIN
        );
    }

    function getDepositFeeWei(uint256 amount) external pure returns (uint256 advisorFee, uint256 platformFee) {
        advisorFee = (amount * WF_ADVISOR_FEE_BPS) / WF_BPS;
        platformFee = (amount * WF_PLATFORM_FEE_BPS) / WF_BPS;
    }

    function getNetDepositAmount(uint256 amount) external pure returns (uint256) {
        uint256 advisorFee = (amount * WF_ADVISOR_FEE_BPS) / WF_BPS;
        uint256 platformFee = (amount * WF_PLATFORM_FEE_BPS) / WF_BPS;
        return amount - advisorFee - platformFee;
    }

    function getAdvisorIdsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        if (offset >= advisorCount) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > advisorCount) end = advisorCount;
        uint256 len = end - offset;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) ids[i] = offset + i + 1;
    }

    function getPortfolioIdsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        if (offset >= portfolioCount) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > portfolioCount) end = portfolioCount;
        uint256 len = end - offset;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) ids[i] = offset + i + 1;
    }

    function getActiveAdvisorIds() external view returns (uint256[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 1; i <= advisorCount; i++) {
            if (wfAdvisors[i].active) count++;
        }
        ids = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 1; i <= advisorCount; i++) {
            if (wfAdvisors[i].active) {
                ids[j] = i;
                j++;
            }
        }
    }

    function getPortfoliosForAdvisor(uint256 advisorId) external view returns (uint256[] memory portfolioIds) {
        if (advisorId == 0 || advisorId > advisorCount) return new uint256[](0);
        uint256 count = 0;
        for (uint256 i = 1; i <= portfolioCount; i++) {
            if (wfPortfolios[i].advisorId == advisorId) count++;
        }
        portfolioIds = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 1; i <= portfolioCount; i++) {
            if (wfPortfolios[i].advisorId == advisorId) {
                portfolioIds[j] = i;
                j++;
            }
        }
    }

    function getClientTotalDeposited(address client) external view returns (uint256 total) {
        uint256[] storage ids = clientPortfolioIds[client];
        for (uint256 i = 0; i < ids.length; i++) {
            total += wfPortfolios[ids[i]].totalDeposited;
        }
    }

    function getClientTotalWithdrawn(address client) external view returns (uint256 total) {
        uint256[] storage ids = clientPortfolioIds[client];
        for (uint256 i = 0; i < ids.length; i++) {
            total += wfPortfolios[ids[i]].totalWithdrawn;
        }
    }

    function getClientNetTotal(address client) external view returns (uint256) {
        return getClientTotalDeposited(client) - getClientTotalWithdrawn(client);
    }

    function getOwner() external view returns (address) { return owner; }
    function getPaused() external view returns (bool) { return wfPaused; }
    function getAdvisorCount() external view returns (uint256) { return advisorCount; }
    function getPortfolioCount() external view returns (uint256) { return portfolioCount; }
    function getTotalDeposits() external view returns (uint256) { return totalDeposits; }
    function getTotalWithdrawn() external view returns (uint256) { return totalWithdrawn; }
    function getTotalFeesCollected() external view returns (uint256) { return totalFeesCollected; }

    function getAdvisorTotalFeesEarned(uint256 advisorId) external view returns (uint256) {
        if (advisorId == 0 || advisorId > advisorCount) return 0;
        return wfAdvisors[advisorId].totalFeesEarned;
    }

    function getAdvisorTotalClients(uint256 advisorId) external view returns (uint256) {
        if (advisorId == 0 || advisorId > advisorCount) return 0;
        return wfAdvisors[advisorId].totalClients;
    }

    function getPortfolioCreatedAtBlock(uint256 portfolioId) external view returns (uint256) {
        if (portfolioId == 0 || portfolioId > portfolioCount) revert WF_InvalidPortfolioId();
        return wfPortfolios[portfolioId].createdAtBlock;
    }

    function getPortfolioTotalDeposited(uint256 portfolioId) external view returns (uint256) {
        if (portfolioId == 0 || portfolioId > portfolioCount) return 0;
        return wfPortfolios[portfolioId].totalDeposited;
    }

    function getPortfolioTotalWithdrawn(uint256 portfolioId) external view returns (uint256) {
        if (portfolioId == 0 || portfolioId > portfolioCount) return 0;
        return wfPortfolios[portfolioId].totalWithdrawn;
    }

    function canDeposit(uint256 portfolioId, address client, uint256 amount) external view returns (bool) {
        if (portfolioId == 0 || portfolioId > portfolioCount) return false;
        WFPortfolio storage p = wfPortfolios[portfolioId];
        if (p.closed || p.client != client) return false;
        if (amount < WF_MIN_DEPOSIT || amount > WF_MAX_DEPOSIT_SINGLE) return false;
        if (!wfAdvisors[p.advisorId].active) return false;
        return true;
    }

    function canWithdraw(uint256 portfolioId, address client, address token, uint256 amount) external view returns (bool) {
        if (portfolioId == 0 || portfolioId > portfolioCount) return false;
        WFPortfolio storage p = wfPortfolios[portfolioId];
        if (p.closed || p.client != client) return false;
        return portfolioTokenBalance[portfolioId][token] >= amount;
    }

    function getAdvisorRegisteredAtBlock(uint256 advisorId) external view returns (uint256) {
        if (advisorId == 0 || advisorId > advisorCount) return 0;
        return wfAdvisors[advisorId].registeredAtBlock;
    }

    function getChainId() external view returns (uint256) { return block.chainid; }
    function getBlockNumber() external view returns (uint256) { return block.number; }

    function getAdvisorBatch(uint256[] calldata advisorIds) external view returns (
        address[] memory wallets,
        bool[] memory actives,
        uint256[] memory totalClients,
        uint256[] memory totalFeesEarned
    ) {
        uint256 n = advisorIds.length;
        wallets = new address[](n);
        actives = new bool[](n);
        totalClients = new uint256[](n);
        totalFeesEarned = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = advisorIds[i];
            if (id != 0 && id <= advisorCount) {
                WFAdvisor storage a = wfAdvisors[id];
                wallets[i] = a.wallet;
                actives[i] = a.active;
                totalClients[i] = a.totalClients;
                totalFeesEarned[i] = a.totalFeesEarned;
            }
        }
    }

    function getPortfolioBatch(uint256[] calldata portfolioIds) external view returns (
        address[] memory clients,
        uint256[] memory advisorIds,
        uint256[] memory totalDepositeds,
        uint256[] memory totalWithdrawns,
        bool[] memory closeds
    ) {
        uint256 n = portfolioIds.length;
        clients = new address[](n);
        advisorIds = new uint256[](n);
        totalDepositeds = new uint256[](n);
        totalWithdrawns = new uint256[](n);
        closeds = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = portfolioIds[i];
            if (id != 0 && id <= portfolioCount) {
                WFPortfolio storage p = wfPortfolios[id];
                clients[i] = p.client;
                advisorIds[i] = p.advisorId;
                totalDepositeds[i] = p.totalDeposited;
                totalWithdrawns[i] = p.totalWithdrawn;
                closeds[i] = p.closed;
            }
        }
    }

    function getPortfolioBalanceBatch(uint256 portfolioId, address[] calldata tokens) external view returns (uint256[] memory balances) {
        uint256 n = tokens.length;
        balances = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            balances[i] = portfolioTokenBalance[portfolioId][tokens[i]];
        }
    }

    function getFullAdvisor(uint256 advisorId) external view returns (
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

    function getFullPortfolio(uint256 portfolioId) external view returns (
        address client_,
        uint256 advisorId_,
        uint256 totalDeposited_,
        uint256 totalWithdrawn_,
        uint256 net_,
        uint256 createdAtBlock_,
        bool closed_,
        uint256 allocationCount_
    ) {
        if (portfolioId == 0 || portfolioId > portfolioCount) revert WF_InvalidPortfolioId();
        WFPortfolio storage p = wfPortfolios[portfolioId];
        return (
            p.client,
            p.advisorId,
            p.totalDeposited,
            p.totalWithdrawn,
            p.totalDeposited - p.totalWithdrawn,
            p.createdAtBlock,
            p.closed,
            portfolioAllocations[portfolioId].length
        );
    }

    uint256 public constant WF_VERSION = 1;
    uint256 public constant WF_MAX_ALLOCATIONS_PER_PORTFOLIO = 500;

    function getMinDepositConstant() external pure returns (uint256) { return WF_MIN_DEPOSIT; }
    function getMaxDepositSingleConstant() external pure returns (uint256) { return WF_MAX_DEPOSIT_SINGLE; }
    function getAdvisorFeeBpsConstant() external pure returns (uint256) { return WF_ADVISOR_FEE_BPS; }
    function getPlatformFeeBpsConstant() external pure returns (uint256) { return WF_PLATFORM_FEE_BPS; }
    function getBpsConstant() external pure returns (uint256) { return WF_BPS; }
    function getMaxAdvisorsConstant() external pure returns (uint256) { return WF_MAX_ADVISORS; }
    function getMaxPortfoliosPerClientConstant() external pure returns (uint256) { return WF_MAX_PORTFOLIOS_PER_CLIENT; }

    function getTreasuryAddress() external view returns (address) { return wfTreasury; }
    function getRegistryKeeperAddress() external view returns (address) { return wfRegistryKeeper; }
    function getFeeVaultAddress() external view returns (address) { return wfFeeVault; }

    function isOwner(address account) external view returns (bool) { return account == owner; }
    function isTreasury(address account) external view returns (bool) { return account == wfTreasury; }
    function isRegistryKeeper(address account) external view returns (bool) { return account == wfRegistryKeeper; }
    function isFeeVault(address account) external view returns (bool) { return account == wfFeeVault; }

    function getActiveAdvisorCount() external view returns (uint256 count) {
        for (uint256 i = 1; i <= advisorCount; i++) {
            if (wfAdvisors[i].active) count++;
        }
    }

    function getOpenPortfolioCount() external view returns (uint256 count) {
        for (uint256 i = 1; i <= portfolioCount; i++) {
            if (!wfPortfolios[i].closed) count++;
        }
    }

    function getClosedPortfolioCount() external view returns (uint256 count) {
        for (uint256 i = 1; i <= portfolioCount; i++) {
            if (wfPortfolios[i].closed) count++;
        }
    }

    function advisorExists(uint256 advisorId) external view returns (bool) {
        return advisorId != 0 && advisorId <= advisorCount;
    }

    function portfolioExists(uint256 portfolioId) external view returns (bool) {
        return portfolioId != 0 && portfolioId <= portfolioCount;
    }

    function computeAdvisorFee(uint256 amount) external pure returns (uint256) {
        return (amount * WF_ADVISOR_FEE_BPS) / WF_BPS;
    }

    function computePlatformFee(uint256 amount) external pure returns (uint256) {
        return (amount * WF_PLATFORM_FEE_BPS) / WF_BPS;
    }

    function computeTotalFee(uint256 amount) external pure returns (uint256) {
        return (amount * (WF_ADVISOR_FEE_BPS + WF_PLATFORM_FEE_BPS)) / WF_BPS;
    }

    function computeNetAfterFees(uint256 amount) external pure returns (uint256) {
        uint256 totalFee = (amount * (WF_ADVISOR_FEE_BPS + WF_PLATFORM_FEE_BPS)) / WF_BPS;
        return amount - totalFee;
    }

    function getClientPortfolioCount(address client) external view returns (uint256) {
        return clientPortfolioIds[client].length;
    }

    function getClientPortfolioIdAt(address client, uint256 index) external view returns (uint256) {
        return clientPortfolioIds[client][index];
    }

    function getTotalNetDeposits() external view returns (uint256) {
        return totalDeposits > totalWithdrawn ? totalDeposits - totalWithdrawn : 0;
    }

    function getDomainInfo() external view returns (bytes32 domainSep_, uint256 genesis_) {
        return (wfDomainSeparator, wfGenesisBlock);
    }

    function getFullGlobalStats() external view returns (
        uint256 totalDeposits_,
        uint256 totalWithdrawn_,
        uint256 totalFeesCollected_,
        uint256 advisorCount_,
        uint256 portfolioCount_,
        bool paused_,
        address owner_,
        uint256 chainId_
    ) {
        return (
            totalDeposits,
            totalWithdrawn,
            totalFeesCollected,
            advisorCount,
            portfolioCount,
