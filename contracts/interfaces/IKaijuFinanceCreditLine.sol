// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.21.0;

interface IKaijuFinanceCreditLine 
{
    struct Credit {
        uint256 Id;
        uint256 AmountLent;
        uint256 AmountExpected;
        address User;
        uint256 PaybackDate;
        uint256 CreatedAt;
        bool Active;        
        uint256 PaidBackAt;
        uint256 LateFee;
    }

    function getRequiredCollateralAmount(address user) external view returns(uint256);
    function issueCredit(address user, uint256 amountLent, uint256 amountExpected, uint256 paybackDate) external;
    function payBackCredit(address user, uint256 lateFee) external;
    function getAmountToReward(uint256 amountLent) external returns(uint256);
    function getUsersActiveCreditIssuedTotal(address user) external returns(uint256);
    function getUsersActiveCredit(address user) external returns(Credit memory credit);
    function CalculateOutstandingCreditFee(address user) external returns(uint256);
}