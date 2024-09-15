// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.21.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
//import "https://raw.githubusercontent.com/msharp19/crypto-credit/main/contracts/interfaces/IKaijuFinanceRewardToken.sol";
import "./IKaijuFinanceRewardToken.sol";
import "./IKaijuFinanceCreditLine.sol";

contract KaijuFinanceCreditLine is Ownable, ReentrancyGuard, IKaijuFinanceCreditLine
{
    uint256 private _currentCreditId = 1;
    uint256 private _collateralPercentToIssue = 20;
    uint256 private _feePercent = 30;
    uint256 private _rewardPercentToIssue = 5;

    Credit[] private _allCredit;
    mapping(address => uint256[]) private _usersCreditIndex;
    mapping(address => uint256) private _usersCurrentCreditIndex;
    IKaijuFinanceRewardToken private _kaijuFinanceRewardToken;

    event CreditCreated(uint256 indexed id, uint256 amountLent, uint256 amountExpected, uint256 paybackDate, uint256 createdAt);
    event CreditPaidBackAt(uint256 indexed id, uint256 lateFees, uint256 createdAt);
    event CollateralPercentToIssueUpdated(address indexed user, uint256 percent, uint256 timestamp);
    event RewardPercentToIssueUpdated(address indexed user, uint256 percent, uint256 timestamp);
    event RewardIssued(address indexed user, uint256 amountToReward, uint256 rewardPercentToIssue, uint256 timestamp);

    constructor(address kaijuFinanceRewardTokenAddress) Ownable(msg.sender){
        _kaijuFinanceRewardToken = IKaijuFinanceRewardToken(kaijuFinanceRewardTokenAddress);
    }

    function issueCredit(address user, uint256 amountLent, uint256 amountExpected, uint256 paybackDate) external onlyOwner nonReentrant
    {
        // Check there isn't outstanding credit
        uint256 usersCurrentIssuedCreditTotal = getUsersActiveCreditIssuedTotal(user);
        require(usersCurrentIssuedCreditTotal == 0,'User has outstanding loans');
        
        // Create credit line
        Credit memory credit = Credit(_currentCreditId++, amountLent, amountExpected, user, paybackDate, block.timestamp, true, 0, 0);
 
        // Add credit
        _allCredit.push(credit);

        // Map credit
        uint256 newIndex = _allCredit.length-1;
        _usersCreditIndex[user].push(newIndex);
        _usersCurrentCreditIndex[user] = newIndex;

        // Fire event
        emit CreditCreated(credit.Id, amountLent, amountExpected, paybackDate, credit.CreatedAt);
    }

    function payBackCredit(address user, uint256 lateFee) external nonReentrant onlyOwner 
    {
        // Check there are credit lines to pay back
        require(_allCredit.length > 0, 'No credits entered into system to pay');

        // Check the user has a current credit line to pay back
        uint256 usersCurrentCreditLineIndex = _usersCurrentCreditIndex[user];
        Credit storage usersCurrentCreditLine = _allCredit[usersCurrentCreditLineIndex];
        require(usersCurrentCreditLine.User == user, 'User has no credit to pay back');

        // Check credit exists
        require(usersCurrentCreditLine.Active, 'Credit doesnt exist');    

        // Check credit has not already been paid back
        require(usersCurrentCreditLine.PaidBackAt == 0, 'Credit doesnt require payback');  

        usersCurrentCreditLine.PaidBackAt = block.timestamp;
        usersCurrentCreditLine.LateFee = lateFee;
        usersCurrentCreditLine.Active = false;

        // Fire event
        emit CreditPaidBackAt(usersCurrentCreditLine.Id, lateFee, usersCurrentCreditLine.PaidBackAt);

        // Try to process reward
        _tryProcessReward(usersCurrentCreditLine, lateFee);
    }

    function getAmountToReward(uint256 amountLent) public view returns(uint256) 
    {
        // This is assuming 1:1 token to credit issuance 
        return (amountLent / 100) * _rewardPercentToIssue;
    }

    function updateCollateralPercentToIssue(uint256 percent) external onlyOwner 
    {
        // Ensure percent is between 0 and 100
        require(percent < 100, 'Value must be between 1 and 100');

        // Update
        _collateralPercentToIssue = percent;

        // Fire event
        emit CollateralPercentToIssueUpdated(msg.sender, percent, block.timestamp);
    }

    function updateRewardPercentToIssue(uint256 percent) external onlyOwner 
    {
        // Ensure percent is between 0 and 100
        require(percent < 100, 'Value must be between 1 and 100');

        // Update
        _rewardPercentToIssue = percent;

        // Fire event
        emit RewardPercentToIssueUpdated(msg.sender, percent, block.timestamp);
    }

    function getCollateralPercentToIssue() external view returns(uint256)
    {
        return _collateralPercentToIssue;
    }

    function getUsersActiveCreditIssuedTotal(address user) public view returns(uint256)
    {
        // If there are credit lines then check that there isnt a current active one (only allowed one active)
        if(_allCredit.length > 0)
        {
            // Check for users current credit
            uint256 usersCurrentCreditLineIndex = _usersCurrentCreditIndex[user];

            // Try to get the users current credit status
            Credit memory usersCurrentCreditLine = _allCredit[usersCurrentCreditLineIndex];
      
            // If the current credit line for a user doesnt already exist, then no need to do below
            // If no credit line exists then the credit line selected will be of index 0 BUT not the users
            if(usersCurrentCreditLine.User == user)
            {
                if(usersCurrentCreditLine.PaidBackAt > 0)
                {
                    return 0;
                }

                return usersCurrentCreditLine.AmountLent;
            }
        }

        return 0;
    }

    function CalculateOutstandingCreditFee(address user) external view returns(uint256)
    {
        Credit memory credit = getUsersActiveCredit(user);
        if(credit.PaidBackAt > 0)
        {
            return 0;
        }

        if(credit.PaybackDate > block.timestamp)
        {
            return ((credit.AmountExpected / 100) * _feePercent);
        }

        return 0;
    }

    function getUsersActiveCredit(address user) public view returns(Credit memory credit)
    {
        // If there are credit lines then check that there isnt a current active one (only allowed one active)
        if(_allCredit.length > 0)
        {
            // Check for users current credit
            uint256 usersCurrentCreditLineIndex = _usersCurrentCreditIndex[user];

            // Try to get the users current credit status
            Credit memory usersCurrentCreditLine = _allCredit[usersCurrentCreditLineIndex];
      
            // If the current credit line for a user doesnt already exist, then no need to do below
            // If no credit line exists then the credit line selected will be of index 0 BUT not the users
            if(usersCurrentCreditLine.User == user)
            {
                if(usersCurrentCreditLine.PaidBackAt == 0){
                    return usersCurrentCreditLine;
                }
            }
        }
    }

    function getRequiredCollateralAmount(address user) external view returns(uint256)
    {
        uint256 usersCreditTotal = getUsersActiveCreditIssuedTotal(user);
        
        return (usersCreditTotal / _collateralPercentToIssue) * 100;
    }

    function _tryProcessReward(Credit memory credit, uint256 lateFee) internal 
    {
        // If no late fees were incurred then tokens can be issued as reward
        if(lateFee == 0)
        {
            // Get amount to reward
            uint256 amountToReward = getAmountToReward(credit.AmountLent);

            // Reward user
            _kaijuFinanceRewardToken.mint(credit.User, amountToReward);

            // Fire event
            emit RewardIssued(credit.User, amountToReward, _rewardPercentToIssue, block.timestamp);
        }
    }
}