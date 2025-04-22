// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LendingContract
 * @dev A lending contract that allows users to deposit collateral, borrow tokens, and more
 */
contract LendingContract is ReentrancyGuard, Ownable {
    // Supported tokens for lending and collateral
    mapping(address => bool) public supportedTokens;
    
    // Interest rate in basis points (1 basis point = 0.01%)
    uint public interestRate = 500; // 5% annual interest rate
    
    // Collateral ratio required (in percentage * 100)
    uint public collateralRatio = 15000; // 150% collateral required
    
    // Liquidation threshold (in percentage * 100)
    uint public liquidationThreshold = 12500; // 125% - liquidation occurs below this
    
    // Liquidation bonus (in percentage * 100)
    uint public liquidationBonus = 10500; // Liquidator gets 105% of the debt value in collateral
    
    // Total amount of tokens borrowed
    mapping(address => uint) public totalBorrowed;
    
    // Total amount of tokens deposited as collateral
    mapping(address => uint) public totalCollateral;
    
    // User deposit and loan data
    struct UserPosition {
        uint collateralAmount;
        uint borrowedAmount;
        uint lastInterestCalculationTime;
        uint interestAccrued;
    }
    
    // Maps user address => token address => position details
    mapping(address => mapping(address => UserPosition)) public userPositions;
    
    // Events
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event Deposit(address indexed user, address indexed token, uint amount);
    event Withdraw(address indexed user, address indexed token, uint amount);
    event Borrow(address indexed user, address indexed token, uint amount);
    event Repay(address indexed user, address indexed token, uint amount);
    event Liquidated(address indexed user, address indexed token, uint collateralAmount, uint debtAmount);
    event InterestRateUpdated(uint oldRate, uint newRate);
    event EmergencyPaused(bool isPaused);
    
    // Emergency pause switch
    bool public isPaused;
    
    // Modifier to check if contract is not paused
    modifier whenNotPaused() {
        require(!isPaused, "Contract is paused");
        _;
    }
    
    /**
     * @dev Constructor that initializes the contract with an owner
     */
    constructor() Ownable(msg.sender) {
        isPaused = false;
    }
    
    /**
     * @dev Add a token to the list of supported tokens
     * @param token Address of the token to add
     */
    function addSupportedToken(address token) external onlyOwner {
        require(token != address(0), "Invalid token address");
        supportedTokens[token] = true;
        emit TokenAdded(token);
    }
    
    /**
     * @dev Remove a token from the list of supported tokens
     * @param token Address of the token to remove
     */
    function removeSupportedToken(address token) external onlyOwner {
        supportedTokens[token] = false;
        emit TokenRemoved(token);
    }
    
    /**
     * @dev Update interest rate
     * @param newInterestRate New interest rate in basis points
     */
    function updateInterestRate(uint newInterestRate) external onlyOwner {
        uint oldRate = interestRate;
        interestRate = newInterestRate;
        emit InterestRateUpdated(oldRate, newInterestRate);
    }
    
    /**
     * @dev Emergency pause/unpause functionality
     * @param _isPaused Boolean indicating if contract should be paused
     */
    function setEmergencyPause(bool _isPaused) external onlyOwner {
        isPaused = _isPaused;
        emit EmergencyPaused(_isPaused);
    }
    
    /**
     * @dev Deposit collateral
     * @param token Address of the token to deposit
     * @param amount Amount to deposit
     */
    function depositCollateral(address token, uint amount) external nonReentrant whenNotPaused {
        require(supportedTokens[token], "Token not supported");
        require(amount > 0, "Amount must be greater than 0");
        
        // Update interest for existing position
        _updateInterest(msg.sender, token);
        
        // Transfer tokens from user to contract
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        
        // Update user's collateral
        userPositions[msg.sender][token].collateralAmount += amount;
        
        // Update total collateral
        totalCollateral[token] += amount;
        
        emit Deposit(msg.sender, token, amount);
    }
    
    /**
     * @dev Withdraw collateral
     * @param token Address of the token to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawCollateral(address token, uint amount) external nonReentrant whenNotPaused {
        require(supportedTokens[token], "Token not supported");
        require(amount > 0, "Amount must be greater than 0");
        
        UserPosition storage position = userPositions[msg.sender][token];
        require(position.collateralAmount >= amount, "Insufficient collateral");
        
        // Update interest
        _updateInterest(msg.sender, token);
        
        // Check if withdrawal would violate collateral ratio
        uint totalDebt = position.borrowedAmount + position.interestAccrued;
        uint remainingCollateral = position.collateralAmount - amount;
        
        // Only check collateral ratio if there is outstanding debt
        if (totalDebt > 0) {
            require(_getCollateralValue(remainingCollateral) >= _getLoanValue(totalDebt), 
                    "Withdrawal would violate collateral ratio");
        }
        
        // Update collateral amount
        position.collateralAmount = remainingCollateral;
        
        // Update total collateral
        totalCollateral[token] -= amount;
        
        // Transfer tokens back to user
        IERC20(token).transfer(msg.sender, amount);
        
        emit Withdraw(msg.sender, token, amount);
    }
    
    /**
     * @dev Borrow tokens against collateral
     * @param token Address of the token to borrow
     * @param amount Amount to borrow
     */
    function borrow(address token, uint amount) external nonReentrant whenNotPaused {
        require(supportedTokens[token], "Token not supported");
        require(amount > 0, "Amount must be greater than 0");
        
        // Update interest for existing position
        _updateInterest(msg.sender, token);
        
        UserPosition storage position = userPositions[msg.sender][token];
        
        // Calculate total debt including new borrow amount
        uint totalDebt = position.borrowedAmount + position.interestAccrued + amount;
        
        // Check if borrowing would violate collateral ratio
        require(_getCollateralValue(position.collateralAmount) >= _getLoanValue(totalDebt), 
                "Insufficient collateral for loan");
        
        // Update borrowed amount
        position.borrowedAmount += amount;
        
        // Update total borrowed
        totalBorrowed[token] += amount;
        
        // Transfer tokens to user
        IERC20(token).transfer(msg.sender, amount);
        
        emit Borrow(msg.sender, token, amount);
    }
    
    /**
     * @dev Repay borrowed tokens
     * @param token Address of the token to repay
     * @param amount Amount to repay
     */
    function repay(address token, uint amount) external nonReentrant whenNotPaused {
        require(supportedTokens[token], "Token not supported");
        require(amount > 0, "Amount must be greater than 0");
        
        // Update interest
        _updateInterest(msg.sender, token);
        
        UserPosition storage position = userPositions[msg.sender][token];
        uint totalDebt = position.borrowedAmount + position.interestAccrued;
        
        require(totalDebt > 0, "No debt to repay");
        
        // Cap repayment amount to total debt
        uint repayAmount = amount > totalDebt ? totalDebt : amount;
        
        // Transfer tokens from user to contract
        IERC20(token).transferFrom(msg.sender, address(this), repayAmount);
        
        // Calculate how much of the repayment goes to interest vs principal
        uint interestPayment = repayAmount > position.interestAccrued ? position.interestAccrued : repayAmount;
        uint principalPayment = repayAmount - interestPayment;
        
        // Update debt - first pay off interest, then principal
        position.interestAccrued -= interestPayment;
        position.borrowedAmount -= principalPayment;
        
        // Update total borrowed
        totalBorrowed[token] -= principalPayment;
        
        emit Repay(msg.sender, token, repayAmount);
    }
    
    /**
     * @dev Liquidate an under-collateralized position
     * @param user Address of the user to liquidate
     * @param token Address of the token
     */
    function liquidate(address user, address token) external nonReentrant whenNotPaused {
        require(supportedTokens[token], "Token not supported");
        require(user != address(0), "Invalid user address");
        require(user != msg.sender, "Cannot liquidate self");
        
        // Update interest for the position
        _updateInterest(user, token);
        
        UserPosition storage position = userPositions[user][token];
        uint totalDebt = position.borrowedAmount + position.interestAccrued;
        
        require(totalDebt > 0, "No debt to liquidate");
        
        // Check if position is under-collateralized based on liquidation threshold
        uint collateralValue = (position.collateralAmount * 10000) / liquidationThreshold;
        require(collateralValue < totalDebt, "Position is not liquidatable");
        
        // Calculate collateral to liquidator (including bonus)
        uint collateralToLiquidator = (totalDebt * liquidationBonus) / 10000;
        if (collateralToLiquidator > position.collateralAmount) {
            collateralToLiquidator = position.collateralAmount;
        }
        
        // Store for events
        uint collateralToLiquidate = collateralToLiquidator;
        uint debtToRepay = totalDebt;
        
        // Transfer debt amount from liquidator to contract
        IERC20(token).transferFrom(msg.sender, address(this), totalDebt);
        
        // Transfer collateral to liquidator
        IERC20(token).transfer(msg.sender, collateralToLiquidator);
        
        // Update global stats
        totalBorrowed[token] -= position.borrowedAmount;
        totalCollateral[token] -= position.collateralAmount;
        
        // Reset the user's position
        delete userPositions[user][token];
        
        emit Liquidated(user, token, collateralToLiquidate, debtToRepay);
    }
    
    /**
     * @dev Get user position details including current health factor
     * @param user Address of the user
     * @param token Address of the token
     * @return collateralAmount Amount of collateral deposited
     * @return borrowedAmount Amount borrowed (excluding interest)
     * @return interestAccrued Interest accrued
     * @return healthFactor Current health factor (% of required collateral, >100% is healthy)
     */
    function getUserPosition(address user, address token) external view returns (
        uint collateralAmount,
        uint borrowedAmount,
        uint interestAccrued,
        uint healthFactor
    ) {
        UserPosition storage position = userPositions[user][token];
        
        collateralAmount = position.collateralAmount;
        borrowedAmount = position.borrowedAmount;
        
        // Calculate accrued interest up to current time
        interestAccrued = position.interestAccrued;
        
        if (position.borrowedAmount > 0 && position.lastInterestCalculationTime > 0) {
            uint timeElapsed = block.timestamp - position.lastInterestCalculationTime;
            uint additionalInterest = (position.borrowedAmount * interestRate * timeElapsed) / (365 days * 10000);
            interestAccrued += additionalInterest;
        }
        
        // Calculate health factor
        uint totalDebt = borrowedAmount + interestAccrued;
        if (totalDebt == 0) {
            healthFactor = type(uint).max; // Max value if no debt
        } else {
            // Health factor = (collateral value / debt value) * 100%
            healthFactor = (collateralAmount * 10000) / (totalDebt * collateralRatio / 10000);
        }
    }
    
    /**
     * @dev Get the liquidity status of a specific token in the protocol
     * @param token Address of the token
     * @return totalCollateralAmount Total amount of token deposited as collateral
     * @return totalBorrowedAmount Total amount of token borrowed
     * @return availableLiquidity Available liquidity for borrowing
     * @return utilizationRate Current utilization rate as a percentage (0-10000)
     */
    function getTokenLiquidity(address token) external view returns (
        uint totalCollateralAmount,
        uint totalBorrowedAmount,
        uint availableLiquidity,
        uint utilizationRate
    ) {
        totalCollateralAmount = totalCollateral[token];
        totalBorrowedAmount = totalBorrowed[token];
        
        uint tokenBalance = IERC20(token).balanceOf(address(this));
        availableLiquidity = tokenBalance - totalBorrowedAmount;
        
        if (totalCollateralAmount == 0) {
            utilizationRate = 0;
        } else {
            utilizationRate = (totalBorrowedAmount * 10000) / totalCollateralAmount;
        }
    }
    
    /**
     * @dev Allows users to check how much they can borrow against their collateral
     * @param user Address of the user
     * @param token Address of the token
     * @return availableToBorrow Maximum amount user can borrow
     */
    function getAvailableToBorrow(address user, address token) external view returns (uint availableToBorrow) {
        UserPosition storage position = userPositions[user][token];
        
        // Calculate accrued interest up to current time
        uint currentInterest = position.interestAccrued;
        
        if (position.borrowedAmount > 0 && position.lastInterestCalculationTime > 0) {
            uint timeElapsed = block.timestamp - position.lastInterestCalculationTime;
            uint additionalInterest = (position.borrowedAmount * interestRate * timeElapsed) / (365 days * 10000);
            currentInterest += additionalInterest;
        }
        
        uint totalDebt = position.borrowedAmount + currentInterest;
        uint maxBorrow = _getCollateralValue(position.collateralAmount);
        
        if (totalDebt >= maxBorrow) {
            return 0;
        }
        
        availableToBorrow = maxBorrow - totalDebt;
        
        // Check against available protocol liquidity
        uint protocolLiquidity = IERC20(token).balanceOf(address(this)) - totalBorrowed[token];
        if (availableToBorrow > protocolLiquidity) {
            availableToBorrow = protocolLiquidity;
        }
    }
    
    /**
     * @dev Update the interest for a user's position
     * @param user Address of the user
     * @param token Address of the token
     */
    function _updateInterest(address user, address token) internal {
        UserPosition storage position = userPositions[user][token];
        
        if (position.borrowedAmount == 0 || position.lastInterestCalculationTime == 0) {
            position.lastInterestCalculationTime = block.timestamp;
            return;
        }
        
        uint timeElapsed = block.timestamp - position.lastInterestCalculationTime;
        if (timeElapsed == 0) return;
        
        // Calculate interest: principal * rate * time / (365 days * 10000)
        // Where rate is in basis points (1bp = 0.01%)
        uint interest = (position.borrowedAmount * interestRate * timeElapsed) / (365 days * 10000);
        
        position.interestAccrued += interest;
        position.lastInterestCalculationTime = block.timestamp;
    }
    
    /**
     * @dev Get collateral value adjusted by collateral ratio
     * @param collateralAmount Amount of collateral
     * @return Required loan value to maintain collateral ratio
     */
    function _getCollateralValue(uint collateralAmount) internal view returns (uint) {
        return (collateralAmount * 10000) / collateralRatio;
    }
    
    /**
     * @dev Get required collateral value for a loan
     * @param loanAmount Amount of the loan
     * @return Required collateral value
     */
    function _getLoanValue(uint loanAmount) internal pure returns (uint) {
        return loanAmount;
    }
}
