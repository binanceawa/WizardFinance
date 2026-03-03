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

