// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LendingContract
 * @dev A simple lending contract that allows users to deposit collateral and borrow tokens
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
    
    /**
     * @dev Constructor that initializes the contract with an owner
     */
    constructor() Ownable(msg.sender) {}
    
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
        interestRate = newInterestRate;
    }
    
    /**
     * @dev Update collateral ratio
     * @param newCollateralRatio New collateral ratio (percentage * 100)
     */
    function updateCollateralRatio(uint newCollateralRatio) external onlyOwner {
        require(newCollateralRatio > 10000, "Collateral ratio must be > 100%");
        collateralRatio = newCollateralRatio;
    }
    
    /**
     * @dev Deposit collateral
     * @param token Address of the token to deposit
     * @param amount Amount to deposit
     */
    function depositCollateral(address token, uint amount) external nonReentrant {
        require(supportedTokens[token], "Token not supported");
        require(amount > 0, "Amount must be greater than 0");
        
        // Update interest for existing position
        _updateInterest(msg.sender, token);
        
        // Transfer tokens from user to contract
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        
        // Update user's collateral
        userPositions[msg.sender][token].collateralAmount += amount;
        
        emit Deposit(msg.sender, token, amount);
    }
    
    /**
     * @dev Withdraw collateral
     * @param token Address of the token to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawCollateral(address token, uint amount) external nonReentrant {
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
        
        // Transfer tokens back to user
        IERC20(token).transfer(msg.sender, amount);
        
        emit Withdraw(msg.sender, token, amount);
    }
    
    /**
     * @dev Borrow tokens against collateral
     * @param token Address of the token to borrow
     * @param amount Amount to borrow
     */
    function borrow(address token, uint amount) external nonReentrant {
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
        
        // Transfer tokens to user
        IERC20(token).transfer(msg.sender, amount);
        
        emit Borrow(msg.sender, token, amount);
    }
    
    /**
     * @dev Repay borrowed tokens
     * @param token Address of the token to repay
     * @param amount Amount to repay
     */
    function repay(address token, uint amount) external nonReentrant {
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
        
        // Update debt - first pay off interest, then principal
        if (repayAmount <= position.interestAccrued) {
            position.interestAccrued -= repayAmount;
        } else {
            uint remainingAfterInterest = repayAmount - position.interestAccrued;
            position.interestAccrued = 0;
            position.borrowedAmount -= remainingAfterInterest;
        }
        
        emit Repay(msg.sender, token, repayAmount);
    }
    
    /**
     * @dev Liquidate an under-collateralized position
     * @param user Address of the user to liquidate
     * @param token Address of the token
     */
    function liquidate(address user, address token) external nonReentrant {
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
        
        // Store liquidation amounts for events
        uint collateralToLiquidate = position.collateralAmount;
        uint debtToRepay = totalDebt;
        
        // Transfer debt amount from liquidator to contract
        IERC20(token).transferFrom(msg.sender, address(this), totalDebt);
        
        // Transfer collateral to liquidator with bonus
        IERC20(token).transfer(msg.sender, position.collateralAmount);
        
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
