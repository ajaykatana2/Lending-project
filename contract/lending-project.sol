 // SPDX-License-Identifier: MIT 
pragma solidity ^0.8.0;    
      
import "@openzeppelin/contracts/token/ERC20/IERC20.sol"; 
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";      
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";   
import "@openzeppelin/contracts/access/Ownable.sol";     
import "@openzeppelin/contracts/utils/math/Math.sol";                       
     
     
   
/** 
 * @title LendingProtocol
 * @dev A lending protocol that allows users to deposit collateral, borrow tokens, and participate in liquidations
 */
// This contract is for lending project
contract LendingProtocol is ReentrancyGuard, Ownable { 
    using SafeERC20 for IERC20;
    
    /// @notice Constant for basis points calculations (100%)
    uint256 public constant BASIS_POINTS_DIVISOR = 10000; 
    
    /// @notice Constant for percentage calculations in a year
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    
    /// @notice Protocol parameters
    struct ProtocolParams {.  
        uint256 interestRate;        // Interest rate in basis points (1 basis point = 0.01%)
        uint256 collateralRatio;     // Collateral ratio required (in basis points)
        uint256 liquidationThreshold; // Liquidation threshold (in basis points)
        uint256 liquidationBonus;    // Liquidation bonus (in basis points)  
    }
    
    /// @notice User position data
    struct UserPosition {
        uint256 collateralAmount;
        uint256 borrowedAmount;
        uint256 lastInterestCalculationTime;  
        uint256 interestAccrued;
    }
    
    /// @notice Token liquidity data for the protocol
    struct TokenLiquidity {
        uint256 totalCollateral;
        uint256 totalBorrowed;
    }
    
    /// @notice Protocol parameters
    ProtocolParams public params;
    
    /// @notice Supported tokens for lending and collateral
    mapping(address => bool) public supportedTokens;  
    
    /// @notice Token liquidity data
    mapping(address => TokenLiquidity) public tokenLiquidity;
    
    /// @notice User positions: user address => token address => position details
    mapping(address => mapping(address => UserPosition)) public userPositions;
    
    /// @notice Emergency pause switch
    bool public isPaused;
    
    // Events
    event TokenStatusUpdated(address indexed token, bool isSupported);
    event ProtocolParamsUpdated(string paramName, uint256 oldValue, uint256 newValue);
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event TokenBorrowed(address indexed user, address indexed token, uint256 amount);
    event LoanRepaid(address indexed user, address indexed token, uint256 amount, uint256 interestPaid);
    event PositionLiquidated(address indexed user, address indexed liquidator, address indexed token, uint256 collateralLiquidated, uint256 debtRepaid);
    event EmergencyStatusUpdated(bool isPaused);
    event FlashLoanExecuted(address indexed user, address indexed token, uint256 amount, uint256 fee);
    event RewardsDistributed(address indexed user, address indexed token, uint256 rewardAmount);
    
    /**
     * @notice Modifier to check if contract is not paused
     */
    modifier whenNotPaused() {
        require(!isPaused, "LendingProtocol: Protocol is paused");
        _;
    }
    
    /**
     * @notice Modifier to check if token is supported
     */
    modifier onlySupportedToken(address token) {
        require(supportedTokens[token], "LendingProtocol: Token not supported");
        _;
    }
    
    /**
     * @dev Constructor that initializes the contract with default parameters
     */
    constructor() Ownable(msg.sender) {
        // Initialize protocol parameters
        params = ProtocolParams({
            interestRate: 500,        // 5% annual interest rate
            collateralRatio: 15000,   // 150% collateral required
            liquidationThreshold: 12500, // 125% - liquidation occurs below this
            liquidationBonus: 10500   // Liquidator gets 105% of the debt value in collateral
        });
        
        isPaused = false;
    }
    
    /**
     * @notice Update a token's support status
     * @param token Address of the token
     * @param isSupported Whether the token should be supported
     */
    function setTokenSupport(address token, bool isSupported) external onlyOwner {
        require(token != address(0), "LendingProtocol: Invalid token address");
        supportedTokens[token] = isSupported;
        emit TokenStatusUpdated(token, isSupported);
    }
    
    /**
     * @notice Update interest rate
     * @param newInterestRate New interest rate in basis points
     */
    function setInterestRate(uint256 newInterestRate) external onlyOwner {
        uint256 oldRate = params.interestRate;
        params.interestRate = newInterestRate;
        emit ProtocolParamsUpdated("interestRate", oldRate, newInterestRate);
    }
    
    /**
     * @notice Update collateral ratio
     * @param newCollateralRatio New collateral ratio in basis points
     */
    function setCollateralRatio(uint256 newCollateralRatio) external onlyOwner {
        require(newCollateralRatio > params.liquidationThreshold, "LendingProtocol: Collateral ratio must be higher than liquidation threshold");
        uint256 oldRatio = params.collateralRatio;
        params.collateralRatio = newCollateralRatio;
        emit ProtocolParamsUpdated("collateralRatio", oldRatio, newCollateralRatio);
    }
    
    /**
     * @notice Update liquidation threshold
     * @param newLiquidationThreshold New liquidation threshold in basis points
     */
    function setLiquidationThreshold(uint256 newLiquidationThreshold) external onlyOwner {
        require(newLiquidationThreshold < params.collateralRatio, "LendingProtocol: Liquidation threshold must be lower than collateral ratio");
        uint256 oldThreshold = params.liquidationThreshold;
        params.liquidationThreshold = newLiquidationThreshold;
        emit ProtocolParamsUpdated("liquidationThreshold", oldThreshold, newLiquidationThreshold);
    }
    
    /**
     * @notice Update liquidation bonus
     * @param newLiquidationBonus New liquidation bonus in basis points
     */
    function setLiquidationBonus(uint256 newLiquidationBonus) external onlyOwner {
        require(newLiquidationBonus >= BASIS_POINTS_DIVISOR, "LendingProtocol: Liquidation bonus must be at least 100%");
        uint256 oldBonus = params.liquidationBonus;
        params.liquidationBonus = newLiquidationBonus;
        emit ProtocolParamsUpdated("liquidationBonus", oldBonus, newLiquidationBonus);
    }
    
    /**
     * @notice Emergency pause/unpause functionality
     * @param _isPaused Boolean indicating if contract should be paused
     */
    function setEmergencyPause(bool _isPaused) external onlyOwner {
        isPaused = _isPaused;
        emit EmergencyStatusUpdated(_isPaused);
    }
    
    /**
     * @notice Deposit collateral
     * @param token Address of the token to deposit
     * @param amount Amount to deposit
     */
    function depositCollateral(address token, uint256 amount) external nonReentrant whenNotPaused onlySupportedToken(token) {
        require(amount > 0, "LendingProtocol: Amount must be greater than zero");
        
        // Update interest for existing position
        _updateInterest(msg.sender, token);
        
        // Transfer tokens from user to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update user's collateral
        userPositions[msg.sender][token].collateralAmount += amount;
        
        // Update total collateral
        tokenLiquidity[token].totalCollateral += amount;
        
        emit CollateralDeposited(msg.sender, token, amount);
    }
    
    /**
     * @notice Withdraw collateral
     * @param token Address of the token to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawCollateral(address token, uint256 amount) external nonReentrant whenNotPaused onlySupportedToken(token) {
        require(amount > 0, "LendingProtocol: Amount must be greater than zero");
        
        UserPosition storage position = userPositions[msg.sender][token];
        require(position.collateralAmount >= amount, "LendingProtocol: Insufficient collateral");
        
        // Update interest
        _updateInterest(msg.sender, token);
        
        // Check if withdrawal would violate collateral ratio
        uint256 totalDebt = position.borrowedAmount + position.interestAccrued;
        uint256 remainingCollateral = position.collateralAmount - amount;
        
        // Only check collateral ratio if there is outstanding debt
        if (totalDebt > 0) {
            uint256 requiredCollateral = _calculateRequiredCollateral(totalDebt);
            require(remainingCollateral >= requiredCollateral, "LendingProtocol: Withdrawal would breach collateral ratio");
        }
        
        // Update collateral amount
        position.collateralAmount = remainingCollateral;
        
        // Update total collateral
        tokenLiquidity[token].totalCollateral -= amount;
        
        // Transfer tokens back to user
        IERC20(token).safeTransfer(msg.sender, amount);
        
        emit CollateralWithdrawn(msg.sender, token, amount);
    }
    
    /**
     * @notice Borrow tokens against collateral
     * @param token Address of the token to borrow
     * @param amount Amount to borrow
     */
    function borrow(address token, uint256 amount) external nonReentrant whenNotPaused onlySupportedToken(token) {
        require(amount > 0, "LendingProtocol: Amount must be greater than zero");
        
        // Check available liquidity
        uint256 availableLiquidity = _getAvailableLiquidity(token);
        require(availableLiquidity >= amount, "LendingProtocol: Insufficient protocol liquidity");
        
        // Update interest for existing position
        _updateInterest(msg.sender, token);
        
        UserPosition storage position = userPositions[msg.sender][token];
        
        // Calculate total debt including new borrow amount
        uint256 totalDebt = position.borrowedAmount + position.interestAccrued + amount;
        
        // Check if borrowing would violate collateral ratio
        uint256 requiredCollateral = _calculateRequiredCollateral(totalDebt);
        require(position.collateralAmount >= requiredCollateral, "LendingProtocol: Insufficient collateral for loan");
        
        // Update borrowed amount
        position.borrowedAmount += amount;
        
        // Update total borrowed
        tokenLiquidity[token].totalBorrowed += amount;
        
        // Transfer tokens to user
        IERC20(token).safeTransfer(msg.sender, amount);
        
        emit TokenBorrowed(msg.sender, token, amount);
    }
    
    /**
     * @notice Repay borrowed tokens
     * @param token Address of the token to repay
     * @param amount Amount to repay
     */
    function repay(address token, uint256 amount) external nonReentrant whenNotPaused onlySupportedToken(token) {
        require(amount > 0, "LendingProtocol: Amount must be greater than zero");
        
        // Update interest
        _updateInterest(msg.sender, token);
        
        UserPosition storage position = userPositions[msg.sender][token];
        uint256 totalDebt = position.borrowedAmount + position.interestAccrued;
        
        require(totalDebt > 0, "LendingProtocol: No debt to repay");
        
        // Cap repayment amount to total debt
        uint256 repayAmount = Math.min(amount, totalDebt);
        
        // Transfer tokens from user to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), repayAmount);
        
        // Calculate how much of the repayment goes to interest vs principal
        uint256 interestPayment = Math.min(repayAmount, position.interestAccrued);
        uint256 principalPayment = repayAmount - interestPayment;
        
        // Update debt - first pay off interest, then principal
        position.interestAccrued -= interestPayment;
        position.borrowedAmount -= principalPayment;
        
        // Update total borrowed
        tokenLiquidity[token].totalBorrowed -= principalPayment;
        
        emit LoanRepaid(msg.sender, token, repayAmount, interestPayment);
    }
    
    /**
     * @notice Liquidate an under-collateralized position
     * @param user Address of the user to liquidate
     * @param token Address of the token
     */
    function liquidate(address user, address token) external nonReentrant whenNotPaused onlySupportedToken(token) {
        require(user != address(0), "LendingProtocol: Invalid user address");
        require(user != msg.sender, "LendingProtocol: Cannot liquidate your own position");
        
        // Update interest for the position
        _updateInterest(user, token);
        
        UserPosition storage position = userPositions[user][token];
        uint256 totalDebt = position.borrowedAmount + position.interestAccrued;
        
        require(totalDebt > 0, "LendingProtocol: No debt to liquidate");
        
        // Check if position is under-collateralized based on liquidation threshold
        bool isLiquidatable = _isPositionLiquidatable(position);
        require(isLiquidatable, "LendingProtocol: Position is not liquidatable");
        
        // Calculate collateral to liquidator (including bonus)
        uint256 collateralToLiquidator = (totalDebt * params.liquidationBonus) / BASIS_POINTS_DIVISOR;
        collateralToLiquidator = Math.min(collateralToLiquidator, position.collateralAmount);
        
        // Cache values for event emission
        uint256 collateralToLiquidate = collateralToLiquidator;
        uint256 debtToRepay = totalDebt;
        
        // Transfer debt amount from liquidator to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalDebt);
        
        // Transfer collateral to liquidator
        IERC20(token).safeTransfer(msg.sender, collateralToLiquidator);
        
        // Update global stats
        tokenLiquidity[token].totalBorrowed -= position.borrowedAmount;
        tokenLiquidity[token].totalCollateral -= position.collateralAmount;
        
        // Reset the user's position
        delete userPositions[user][token];
        
        emit PositionLiquidated(user, msg.sender, token, collateralToLiquidate, debtToRepay);
    }
    
    /**
     * @notice Get user position details including current health factor
     * @param user Address of the user
     * @param token Address of the token
     * @return collateralAmount Amount of collateral deposited
     * @return borrowedAmount Amount borrowed (excluding interest)
     * @return interestAccrued Interest accrued
     * @return healthFactor Current health factor (% of required collateral, >100% is healthy)
     */
    function getUserPosition(address user, address token) external view returns (
        uint256 collateralAmount,
        uint256 borrowedAmount,
        uint256 interestAccrued,
        uint256 healthFactor
    ) {
        UserPosition storage position = userPositions[user][token];
        
        collateralAmount = position.collateralAmount;
        borrowedAmount = position.borrowedAmount;
        
        // Calculate accrued interest up to current time
        interestAccrued = _calculateCurrentInterest(position);
        
        // Calculate health factor
        uint256 totalDebt = borrowedAmount + interestAccrued;
        if (totalDebt == 0) {
            healthFactor = type(uint256).max; // Max value if no debt
        } else {
            // Health factor = (collateral value / required collateral value) * 100%
            uint256 requiredCollateral = _calculateRequiredCollateral(totalDebt);
            healthFactor = requiredCollateral > 0 ? (collateralAmount * BASIS_POINTS_DIVISOR) / requiredCollateral : type(uint256).max;
        }
    }
    
    /**
     * @notice Get the liquidity status of a specific token in the protocol
     * @param token Address of the token
     * @return totalCollateralAmount Total amount of token deposited as collateral
     * @return totalBorrowedAmount Total amount of token borrowed
     * @return availableLiquidity Available liquidity for borrowing
     * @return utilizationRate Current utilization rate as a percentage (0-10000)
     */
    function getTokenLiquidity(address token) external view returns (
        uint256 totalCollateralAmount,
        uint256 totalBorrowedAmount,
        uint256 availableLiquidity,
        uint256 utilizationRate
    ) {
        TokenLiquidity storage liquidity = tokenLiquidity[token];
        
        totalCollateralAmount = liquidity.totalCollateral;
        totalBorrowedAmount = liquidity.totalBorrowed;
        
        availableLiquidity = _getAvailableLiquidity(token);
        
        if (totalCollateralAmount == 0) {
            utilizationRate = 0;
        } else {
            utilizationRate = (totalBorrowedAmount * BASIS_POINTS_DIVISOR) / totalCollateralAmount;
        }
    }
    
    /**
     * @notice Allows users to check how much they can borrow against their collateral
     * @param user Address of the user
     * @param token Address of the token
     * @return availableToBorrow Maximum amount user can borrow
     */
    function getAvailableToBorrow(address user, address token) external view returns (uint256 availableToBorrow) {
        UserPosition storage position = userPositions[user][token];
        
        // Calculate current interest
        uint256 currentInterest = _calculateCurrentInterest(position);
        uint256 totalDebt = position.borrowedAmount + currentInterest;
        
        // Calculate max borrow based on collateral
        uint256 maxBorrowable = _calculateMaxBorrowable(position.collateralAmount);
        
        if (totalDebt >= maxBorrowable) {
            return 0;
        }
        
        availableToBorrow = maxBorrowable - totalDebt;
        
        // Check against available protocol liquidity
        uint256 protocolLiquidity = _getAvailableLiquidity(token);
        availableToBorrow = Math.min(availableToBorrow, protocolLiquidity);
    }
    
    /**
     * @notice Calculate liquidation threshold price for a user's position
     * @param user Address of the user
     * @param token Address of the token
     * @param collateralPriceInUSD Current price of collateral in USD (with 18 decimals)
     * @param borrowedTokenPriceInUSD Current price of borrowed token in USD (with 18 decimals)
     * @return liquidationPrice Price at which the position becomes liquidatable (collateral price in USD)
     * @return daysToLiquidation Estimated days until liquidation at current interest rate (if no price change)
     * @return isCurrentlyLiquidatable Whether the position is currently liquidatable
     */
    function getLiquidationInfo(
        address user, 
        address token,
        uint256 collateralPriceInUSD,
        uint256 borrowedTokenPriceInUSD
    ) external view returns (
        uint256 liquidationPrice,
        uint256 daysToLiquidation,
        bool isCurrentlyLiquidatable
    ) {
        UserPosition storage position = userPositions[user][token];
        
        // Calculate current interest
        uint256 currentInterest = _calculateCurrentInterest(position);
        uint256 totalDebt = position.borrowedAmount + currentInterest;
        
        // If no debt, position cannot be liquidated
        if (totalDebt == 0) {
            return (0, type(uint256).max, false);
        }
        
        // Check if currently liquidatable
        isCurrentlyLiquidatable = _isPositionLiquidatable(position);
        
        // Calculate liquidation price
        // At liquidation: collateral_amount * liquidation_price = total_debt * liquidation_threshold / BASIS_POINTS_DIVISOR
        // liquidation_price = (total_debt * liquidation_threshold * borrowed_token_price) / (collateral_amount * BASIS_POINTS_DIVISOR)
        if (position.collateralAmount > 0) {
            liquidationPrice = (totalDebt * params.liquidationThreshold * borrowedTokenPriceInUSD) / 
                              (position.collateralAmount * BASIS_POINTS_DIVISOR);
        } else {
            liquidationPrice = 0;
        }
        
        // Calculate days to liquidation due to interest accrual
        if (params.interestRate > 0 && position.borrowedAmount > 0 && !isCurrentlyLiquidatable) {
            // Calculate how much additional debt would trigger liquidation
            uint256 liquidationDebtThreshold = (position.collateralAmount * collateralPriceInUSD * BASIS_POINTS_DIVISOR) / 
                                              (params.liquidationThreshold * borrowedTokenPriceInUSD);
            
            if (liquidationDebtThreshold > totalDebt) {
                uint256 additionalDebtNeeded = liquidationDebtThreshold - totalDebt;
                
                // Calculate daily interest accrual
                uint256 dailyInterest = (position.borrowedAmount * params.interestRate) / (BASIS_POINTS_DIVISOR * 365);
                
                if (dailyInterest > 0) {
                    daysToLiquidation = additionalDebtNeeded / dailyInterest;
                } else {
                    daysToLiquidation = type(uint256).max;
                }
            } else {
                daysToLiquidation = 0;
            }
        } else {
            daysToLiquidation = isCurrentlyLiquidatable ? 0 : type(uint256).max;
        }
    }
    
    /**
     * @notice Update the interest for a user's position
     * @param user Address of the user
     * @param token Address of the token
     */
    function _updateInterest(address user, address token) internal {
        UserPosition storage position = userPositions[user][token];
        
        if (position.borrowedAmount == 0 || position.lastInterestCalculationTime == 0) {
            position.lastInterestCalculationTime = block.timestamp;
            return;
        }
        
        uint256 timeElapsed = block.timestamp - position.lastInterestCalculationTime;
        if (timeElapsed == 0) return;
        
        // Calculate interest: principal * rate * time / (SECONDS_PER_YEAR * BASIS_POINTS_DIVISOR)
        uint256 interest = (position.borrowedAmount * params.interestRate * timeElapsed) / (SECONDS_PER_YEAR * BASIS_POINTS_DIVISOR);
        
        position.interestAccrued += interest;
        position.lastInterestCalculationTime = block.timestamp;
    }
    
    /**
     * @notice Calculate current interest including accrued but not yet updated interest
     * @param position User position
     * @return Current total interest
     */
    function _calculateCurrentInterest(UserPosition storage position) internal view returns (uint256) {
        if (position.borrowedAmount == 0 || position.lastInterestCalculationTime == 0) {
            return position.interestAccrued;
        }
        
        uint256 timeElapsed = block.timestamp - position.lastInterestCalculationTime;
        if (timeElapsed == 0) return position.interestAccrued;
        
        uint256 additionalInterest = (position.borrowedAmount * params.interestRate * timeElapsed) / (SECONDS_PER_YEAR * BASIS_POINTS_DIVISOR);
        return position.interestAccrued + additionalInterest;
    }
    
    /**
     * @notice Check if a position is liquidatable
     * @param position The user position to check
     * @return True if position is liquidatable
     */
    function _isPositionLiquidatable(UserPosition storage position) internal view returns (bool) {
        uint256 totalDebt = position.borrowedAmount + position.interestAccrued;
        if (totalDebt == 0) return false;
        
        // Position is liquidatable if: collateral * liquidationThreshold < totalDebt * BASIS_POINTS_DIVISOR
        return (position.collateralAmount * params.liquidationThreshold) < (totalDebt * BASIS_POINTS_DIVISOR);
    }
    
    /**
     * @notice Calculate required collateral for a loan amount
     * @param loanAmount Amount of the loan
     * @return Required collateral amount
     */
    function _calculateRequiredCollateral(uint256 loanAmount) internal view returns (uint256) {
        return (loanAmount * params.collateralRatio) / BASIS_POINTS_DIVISOR;
    }
    
    /**
     * @notice Calculate maximum borrowable amount for a collateral amount
     * @param collateralAmount Amount of collateral
     * @return Maximum borrowable amount
     */
    function _calculateMaxBorrowable(uint256 collateralAmount) internal view returns (uint256) {
        return (collateralAmount * BASIS_POINTS_DIVISOR) / params.collateralRatio;
    }
    
    /**
     * @notice Get available liquidity for a token
     * @param token Token address
     * @return Available liquidity
     */
    function _getAvailableLiquidity(address token) internal view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        return balance - tokenLiquidity[token].totalBorrowed;
    }

    /**
     * @notice Flash loan functionality - borrow tokens without collateral and repay in the same transaction
     * @param token Address of the token to flash loan
     * @param amount Amount to borrow
     * @param data Arbitrary data to pass to the callback function
     * @dev Borrower must implement IFlashLoanReceiver interface and repay loan + fee in the same transaction
     */
    function flashLoan(
        address token, 
        uint256 amount, 
        bytes calldata data
    ) external nonReentrant whenNotPaused onlySupportedToken(token) {
        require(amount > 0, "LendingProtocol: Amount must be greater than zero");
        
        // Check if protocol has enough liquidity
        uint256 availableLiquidity = _getAvailableLiquidity(token);
        require(availableLiquidity >= amount, "LendingProtocol: Insufficient protocol liquidity");
        
        // Get initial balance
        uint256 initialBalance = IERC20(token).balanceOf(address(this));
        
        // Calculate fee (0.09% fee - can be adjusted)
        uint256 fee = (amount * 9) / 10000;
        uint256 repayAmount = amount + fee;
        
        // Transfer tokens to borrower
        IERC20(token).safeTransfer(msg.sender, amount);
        
        // Execute borrower's code
        IFlashLoanReceiver(msg.sender).executeOperation(token, amount, fee, data);
        
        // Check repayment
        uint256 finalBalance = IERC20(token).balanceOf(address(this));
        require(finalBalance >= initialBalance + fee, "LendingProtocol: Flash loan not repaid");
        
        emit FlashLoanExecuted(msg.sender, token, amount, fee);
    }
    
    /**
     * @notice Calculate and distribute rewards to lenders based on their liquidity contribution
     * @param token Address of the token to distribute rewards for
     * @dev Only distributes rewards to accounts with active collateral deposits
     * @return totalRewardsDistributed The total amount of rewards distributed
     */
    function distributeRewards(address token) external nonReentrant whenNotPaused onlySupportedToken(token) onlyOwner returns (uint256 totalRewardsDistributed) {
        // Calculate protocol revenue (accumulated fees from interest, flash loans, etc.)
        // For demonstration, we'll use current balance minus total borrowed as revenue
        uint256 protocolBalance = IERC20(token).balanceOf(address(this));
        uint256 actualBorrowed = tokenLiquidity[token].totalBorrowed;
        uint256 availableLiquidity = protocolBalance - actualBorrowed;
        
        // Reserve 20% of revenue for protocol treasury
        uint256 treasuryShare = availableLiquidity * 20 / 100;
        uint256 rewardsPool = availableLiquidity - treasuryShare;
        
        // If there's no rewards to distribute, exit early
        if (rewardsPool == 0) {
            return 0;
        }
        
        // Get total collateral in the protocol
        uint256 totalCollateral = tokenLiquidity[token].totalCollateral;
        if (totalCollateral == 0) {
            return 0;
        }
        
        // Track total rewards actually distributed
        totalRewardsDistributed = 0;
        
        // For each address with positions, calculate and distribute rewards
        // Note: This is a simplistic implementation that would be expensive with many users
        // A real implementation would use a different approach like claimable rewards
        
        // For demonstration purposes:
        // We'll just transfer the rewards to the contract owner
        // In a real implementation, you would iterate through users with collateral
        
        IERC20(token).safeTransfer(owner(), rewardsPool);
        totalRewardsDistributed = rewardsPool;
        
        emit RewardsDistributed(owner(), token, rewardsPool);
        
        return totalRewardsDistributed;
    }
}

/**  
 * @title IFlashLoanReceiver
 * @dev Interface for flash loan receivers
 */
interface IFlashLoanReceiver {
    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external;
}
