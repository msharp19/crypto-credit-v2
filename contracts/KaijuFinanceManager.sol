// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.21.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
//import "https://raw.githubusercontent.com/msharp19/crypto-credit/main/contracts/interfaces/IKaijuFinanceCreditLine.sol";
//import "https://raw.githubusercontent.com/msharp19/crypto-credit/main/contracts/interfaces/IKaijuFinanceLiquidStakingToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IKaijuFinanceCreditLine.sol";
import "./IKaijuFinanceLiquidStakingToken.sol";
import "https://raw.githubusercontent.com/aave-dao/aave-v3-origin/main/src/core/contracts/interfaces/IPool.sol";

contract KaijuFinanceManager is Ownable, ReentrancyGuard 
{
    struct Stake {
       uint256 Id;
       address Owner;
       uint256 AmountStaked;
       uint256 AmountSuppliedAsLiquicity;
       uint256 ExcessAmount;
       address TokenAddress;
       uint256 CreatedAt;
    }

    struct WithdrawnStake {
       uint256 Id;
       address Owner;
       uint256 AmountWithdrawn;
       uint256 CreatedAt;
    }

    struct SupportedToken {
       IERC20 Token;
       address TokenAddress;
       uint256 MinimumStakeAmount;
       uint256 DateAdded;
       bool Active;
    }

    struct StakeTotal {
       uint256 TotalAmount;
       uint256 AmountInLiquicity;
       uint256 AmountExcess;
       address TokenAddress;
    }

    uint256 private _currentStakeId = 1;
    uint256 private _currentWithdrawnStakeId = 1;
    
    uint256 private _aaveBorrowRate = 5;
    uint256 private _aavePercent = 50;
    address private _excessAdminAddress = 0x0000000000000000000000000000000000000000;
    address private _loanAddress = 0x0000000000000000000000000000000000000000;
    address private _poolAddress;
    IPool private _pool;

    Stake[] private _allStakes;
    WithdrawnStake[] private _allWithdrawnStakes;

    SupportedToken _supportedToken;

    mapping(address => uint256[]) private _allUsersStakeIndexs;
    mapping(address => uint256[]) private _allUsersWithdrawnStakeIndexs;
    mapping(address => StakeTotal) private _usersCurrentStakeTotals;

    IKaijuFinanceLiquidStakingToken private _kaijuFinanceLiquidStakingToken;
    IKaijuFinanceCreditLine private _kaijuFinanceCreditLine;

    event TokenStaked(uint256 indexed id, address indexed user, uint256 amountStaked, uint256 amountSuppliedAsLiquicity, uint256 excessAmount, uint256 createdAt);
    event StakeCollected(uint256 indexed id, address indexed user, uint256 amountReceived, uint256 collectedAt);
    event ExcessWithdrawn(address token, address to, uint256 amount, uint256 createdAt);
    event StakeWithdrawnFromPool(address indexed user, address indexed tokenAddress, uint256 amount, uint256 createdAt);
    event BorrowInitiated(address indexed user, address indexed tokenAddress, uint256 amount, uint256 paybackAmount, uint256 indexed paybackDate, uint256 timestamp);
    event BorrowPaidBack(address indexed user, address indexed tokenAddress, uint256 amount, uint256 fee,  uint256 timestamp);

    constructor(
        address excessAdminAddress,
        address loanAddress,
        uint256 aavePercent,
        address poolAddress,
        address supportedTokenAddress,
        address kaijuFinanceLiquidStakingTokenAddress, 
        address kaijuFinanceCreditLineAddress
    ) Ownable(msg.sender)
    {
        _aavePercent = aavePercent;
        _excessAdminAddress = excessAdminAddress;
        _pool = IPool(poolAddress);
        _poolAddress = poolAddress;
        _loanAddress = loanAddress;
        _supportedToken = SupportedToken(IERC20(supportedTokenAddress), supportedTokenAddress, 1000, block.timestamp, true);

        _kaijuFinanceLiquidStakingToken = IKaijuFinanceLiquidStakingToken(kaijuFinanceLiquidStakingTokenAddress);
        _kaijuFinanceCreditLine = IKaijuFinanceCreditLine(kaijuFinanceCreditLineAddress);
    }

    function getMaximumWithdrawalAmount(
        address user
    ) public view returns(uint256) 
    {
        // Get the users current staked amount
        StakeTotal memory currentStakeAmount = _usersCurrentStakeTotals[user];
        
        // Get the amount required for collateral
        uint256 amountRequiredForCollateral = _kaijuFinanceCreditLine.getRequiredCollateralAmount(user);

        // Get the amount left staked excluding the amount required for collateral
        return (currentStakeAmount.TotalAmount - amountRequiredForCollateral);
    }
 
    function stake(
        uint256 amount
    ) external nonReentrant
    {       
        // Validate stake amount
        require(amount >= _supportedToken.MinimumStakeAmount, 'Minimum stake amount not met');

        // Ensure is approved to take from sender
        require(_supportedToken.Token.allowance(msg.sender, address(this)) >= amount, 'Not allowed to take tokens, remember to allow this contract the amount specified');

        // Take the tokens
        _supportedToken.Token.transferFrom(msg.sender, address(this), amount);

        // Allow the send of tokens from this to pool (on our behalf)
        _supportedToken.Token.approve(_poolAddress, amount);

         // Ensure is approved to send
        require(_supportedToken.Token.allowance(address(this), _poolAddress) >= amount, 'Not allowed to take tokens from contract');

        // Send the value to AAVE
        uint256 amountToSend = (amount / 100) * _aavePercent;
        uint256 amountToKeep = amount - amountToSend;
        _pool.supply(_supportedToken.TokenAddress, amountToSend, address(this), 0);

        // Create new stake record and add it
        Stake memory newStake = Stake(_currentStakeId++, msg.sender, amount, amountToSend, amountToKeep, _supportedToken.TokenAddress, block.timestamp);
        _allStakes.push(newStake);

        // Calculate the new index and add index to users stakes
        uint256 newStakeIndex = _allStakes.length-1;
        _allUsersStakeIndexs[msg.sender].push(newStakeIndex);

        // Get the users current staked amount for all tokens + find the current stake for the specified user/token
        StakeTotal storage usersCurrentStakeTotal = _usersCurrentStakeTotals[msg.sender];
        usersCurrentStakeTotal.TotalAmount += amount;
        usersCurrentStakeTotal.AmountInLiquicity += amountToSend;
        usersCurrentStakeTotal.AmountExcess += amountToKeep;

        // Mint the liquid staking tokens
        _kaijuFinanceLiquidStakingToken.mint(msg.sender, amount);

        // Fire contract event indicatin Eth has been staked
        emit TokenStaked(newStake.Id, msg.sender, amount, amountToSend, amountToKeep, block.timestamp);
    }

    function issueCredit(
        uint256 amount, 
        uint256 paybackDate
    ) external nonReentrant 
    {
        // Ensure payback date is later than now
        require(paybackDate > block.timestamp, 'Pay back date must be later than now');
        
        // Ensure active loan is not out
        uint256 total = _kaijuFinanceCreditLine.getUsersActiveCreditIssuedTotal(msg.sender);
        require(total == 0, 'Active credit issuance needs to be settled before issuing more credit');

        StakeTotal storage usersStakingTotal = _usersCurrentStakeTotals[msg.sender];    
        require(amount <= usersStakingTotal.AmountInLiquicity);

       uint256 paybackAmount = ((amount / 100) * _aaveBorrowRate) + amount; 
       _kaijuFinanceCreditLine.issueCredit(msg.sender, amount, paybackAmount, paybackDate);

       // Borrow (sends here)
       _pool.borrow(_supportedToken.TokenAddress, amount, 1, 0, address(this));

       // Send from here onto the allocated loan address
       _supportedToken.Token.transfer(_loanAddress, amount);
 
       // Fire event
       emit BorrowInitiated(msg.sender, _supportedToken.TokenAddress, amount, paybackAmount, paybackDate, block.timestamp);
    }

    function paybackCredit(
        uint256 amount
    ) external nonReentrant 
    {
        IKaijuFinanceCreditLine.Credit memory creditToPayBack = _kaijuFinanceCreditLine.getUsersActiveCredit(msg.sender);
        require(creditToPayBack.AmountExpected > 0, 'No credit to pay back');

        uint256 fee = 0;
        if(creditToPayBack.PaybackDate < block.timestamp)
        {
            fee = _kaijuFinanceCreditLine.CalculateOutstandingCreditFee(msg.sender);
        }

        require(creditToPayBack.AmountExpected == amount, 'Exact amount must be provided');

        // Ensure is approved to take
        require(_supportedToken.Token.allowance(msg.sender, address(this)) >= amount, 'Must first allow tokens to be spent on behalf of pool address');
        
        // Take from user
        _supportedToken.Token.transferFrom(msg.sender, address(this), amount);

        // Allow pool to take from us
        _supportedToken.Token.approve(_poolAddress, amount);

        // Repay
        _pool.repay(_supportedToken.TokenAddress, amount, 1, address(this));

        // Mark paid back
        _kaijuFinanceCreditLine.payBackCredit(msg.sender, fee);

        emit BorrowPaidBack(msg.sender, _supportedToken.TokenAddress, amount, fee, block.timestamp);
    }

    // This allows admin to pay back a loan on behalf of a user
    function issueUserCredit(
        address user,
        uint256 amount, 
        uint256 paybackDate
    ) external onlyOwner nonReentrant 
    {
        // Ensure payback date is later than now
        require(paybackDate > block.timestamp, 'Pay back date must be later than now');
        
        // Ensure active loan is not out
        uint256 total = _kaijuFinanceCreditLine.getUsersActiveCreditIssuedTotal(user);
        require(total == 0, 'Active credit issuance needs to be settled before issuing more credit');

        StakeTotal storage usersStakingTotal = _usersCurrentStakeTotals[user];    
        require(amount <= usersStakingTotal.AmountInLiquicity);

       uint256 paybackAmount = ((amount / 100) * _aaveBorrowRate) + amount; 
       _kaijuFinanceCreditLine.issueCredit(user, amount, paybackAmount, paybackDate);

       // Borrow (sends here)
       _pool.borrow(_supportedToken.TokenAddress, amount, 1, 0, address(this));

       // Send from here onto the allocated loan address
       _supportedToken.Token.transfer(_loanAddress, amount);
 
       // Fire event
       emit BorrowInitiated(msg.sender, _supportedToken.TokenAddress, amount, paybackAmount, paybackDate, block.timestamp);
    }

    // This allows admin to pay back a loan on behalf of a user
    function paybackUsersCredit(
        address user,
        uint256 amount
    ) external onlyOwner nonReentrant 
    {
        IKaijuFinanceCreditLine.Credit memory creditToPayBack = _kaijuFinanceCreditLine.getUsersActiveCredit(user);
        require(creditToPayBack.AmountExpected > 0, 'No credit to pay back');

        uint256 fee = 0;
        if(creditToPayBack.PaybackDate < block.timestamp)
        {
            fee = _kaijuFinanceCreditLine.CalculateOutstandingCreditFee(user);
        }

        require(creditToPayBack.AmountExpected == amount, 'Exact amount must be provided');

        // Ensure is approved to take
        require(_supportedToken.Token.allowance(msg.sender, address(this)) >= amount, 'Must first allow tokens to be spent on behalf of pool address');
        
        // Take from user
        _supportedToken.Token.transferFrom(msg.sender, address(this), amount);

        // Allow pool to take from us
        _supportedToken.Token.approve(_poolAddress, amount);

        // Repay
        _pool.repay(_supportedToken.TokenAddress, amount, 1, address(this));

        // Mark paid back
        _kaijuFinanceCreditLine.payBackCredit(user, fee);

        emit BorrowPaidBack(user, _supportedToken.TokenAddress, amount, fee, block.timestamp);
    }

    function withdrawStake() external nonReentrant 
    {
        StakeTotal storage usersStakingTotal = _usersCurrentStakeTotals[msg.sender];
        require(usersStakingTotal.TotalAmount > 0, 'No stake to withdraw');

        // Ensure credit isnt already on loan
        uint256 maximumWithdrawAmount = getMaximumWithdrawalAmount(msg.sender);
        require(maximumWithdrawAmount == usersStakingTotal.AmountInLiquicity, 'The withdraw will reduce the collateral below what is required since there is an active loan. Please try a lower amount');

        // Ensure contract has enough to honor the withdraw
        require((address(this).balance + usersStakingTotal.AmountInLiquicity) >= usersStakingTotal.TotalAmount, 'The contract needs additional funding before this can be completed');

        // Ensure the user has the liquid staking tokens to burn
        uint256 liquidTokenBalance = _kaijuFinanceLiquidStakingToken.balanceOf(msg.sender);
        require(liquidTokenBalance >= usersStakingTotal.TotalAmount, 'User does not have the liquid stake token balance to complete the withdrawal');

        //Copy so we can use what the values were before resetting them
        uint256 usersStakingTotalAmount = usersStakingTotal.TotalAmount;
        uint256 usersStakingTotalAmountInLiquicity = usersStakingTotal.AmountInLiquicity;

        // Mark as collected
        usersStakingTotal.TotalAmount = 0;
        usersStakingTotal.AmountInLiquicity = 0;
        usersStakingTotal.AmountExcess = 0;

        // Collect our liquid tokens
        _kaijuFinanceLiquidStakingToken.burn(msg.sender, usersStakingTotalAmount);

        // Get back value from AAVE
        _pool.withdraw(_supportedToken.TokenAddress, usersStakingTotalAmount, address(this));
        emit StakeWithdrawnFromPool(msg.sender, _supportedToken.TokenAddress, usersStakingTotalAmountInLiquicity, block.timestamp);
        
        // Create a record
        WithdrawnStake memory stakeWithdrawal = WithdrawnStake(_currentWithdrawnStakeId++, msg.sender, usersStakingTotalAmount, block.timestamp);
        _allWithdrawnStakes.push(stakeWithdrawal);
        uint256 newWithdrawnStakeIndex = _allWithdrawnStakes.length-1;
        _allUsersWithdrawnStakeIndexs[msg.sender].push(newWithdrawnStakeIndex);

        // Send back to user
        _supportedToken.Token.transfer(msg.sender, usersStakingTotalAmount);

        // Fire contract event indication that a stake has been withdrawn by a user
        emit StakeCollected(stakeWithdrawal.Id, msg.sender, usersStakingTotalAmount, block.timestamp);
    }

    function WithdrawnExcessStake(
        address tokenAddress, 
        uint256 amount
    ) external onlyOwner
    {
        // Check is supported
        require(_supportedToken.Active, 'Token is not supported');

        _supportedToken.Token.transfer(_excessAdminAddress, amount);

        emit ExcessWithdrawn(tokenAddress, _excessAdminAddress, amount, block.timestamp);
    }

    // Get and return a users staked total
    function getStakeTotal(
        address user
    ) view external returns(StakeTotal memory)
    {
         return _usersCurrentStakeTotals[user];
    }

    // Get and return a stake by its id (id is +1 of index)
    function getStake(
        uint256 stakeId
    ) view external returns(Stake memory)
    {
         return _allStakes[stakeId - 1];
    }

    // Get and return a page of stakes
    function getPageOfStakesAscending(
        uint256 pageNumber, 
        uint256 perPage
    ) public view returns(Stake[] memory)
    {
        // Get the total amount remaining
        uint256 totalStakes = _allStakes.length;

        // Get the index to start from
        uint256 startingIndex = pageNumber * perPage;

        // The number of stakes that will be returned (to set array)
        uint256 remaining = totalStakes - startingIndex;
        uint256 pageSize = ((startingIndex+1)>totalStakes) ? 0 : (remaining < perPage) ? remaining : perPage;

        // Create the page
        Stake[] memory pageOfStakes = new Stake[](pageSize);

        // Add each item to the page
        uint256 pageItemIndex = 0;
        for(uint256 i = startingIndex;i < (startingIndex + pageSize);i++){
           
           // Get the stake 
           Stake memory addedStake = _allStakes[i];

           // Add to page
           pageOfStakes[pageItemIndex] = addedStake;

           // Increment page item index
           pageItemIndex++;
        }

        return pageOfStakes;
    }

    // Get and return a page of stakes
    function getPageOfStakesDescending(
        uint256 pageNumber, 
        uint256 perPage
    ) public view returns(Stake[] memory pageOfStakes)
    {
        // Get the total amount remaining
        uint256 totalWithdrawnStakes = _allStakes.length;

        // Calculate the starting index
        uint256 start = totalWithdrawnStakes > (pageNumber + 1) * perPage 
                        ? totalWithdrawnStakes - (pageNumber + 1) * perPage 
                        : 0;
                        
        // Calculate the end index
        uint256 end = totalWithdrawnStakes > pageNumber * perPage 
                    ? totalWithdrawnStakes - pageNumber * perPage 
                    : 0;

        // Calculate the size of the page
        uint256 pageSize = end - start;

        // Create the page array
        pageOfStakes = new Stake[](pageSize);

        // Populate the page array with the correct stakes
        for (uint256 i = 0; i < pageSize; i++) {
            pageOfStakes[pageSize - 1 - i] = _allStakes[start + i];
        }

        return pageOfStakes;
    }

    // Get and return a page of stakes
    function getPageOfUsersStakesAscending(
        address user, 
        uint256 pageNumber, 
        uint256 perPage
        ) public view returns(Stake[] memory)
    {    
        uint256[] memory usersStakeIndexes = _allUsersStakeIndexs[user];

        // Get the total amount remaining
        uint256 totalStakes = usersStakeIndexes.length;

        // Get the index to start from
        uint256 startingIndex = pageNumber * perPage;

        // The number of stakes that will be returned (to set array)
        uint256 remaining = totalStakes - startingIndex;
        uint256 pageSize = ((startingIndex+1)>totalStakes) ? 0 : (remaining < perPage) ? remaining : perPage;

        // Create the page
        Stake[] memory pageOfStakes = new Stake[](pageSize);

        // Add each item to the page
        uint256 pageItemIndex = 0;
        for(uint256 i = startingIndex;i < (startingIndex + pageSize);i++)
        {   
           // Get the stake 
           Stake memory usersStake = _allStakes[usersStakeIndexes[i]];

           // Add to page
           pageOfStakes[pageItemIndex] = usersStake;

           // Increment page item index
           pageItemIndex++;
        }

        return pageOfStakes;
    }

    function getPageOfUsersStakesDescending(
        address user, 
        uint256 pageNumber, 
        uint256 perPage
    ) public view returns(Stake[] memory pageOfStakes)
    {          
        // Get the total amount remaining
        uint256 totalStakes = _allUsersStakeIndexs[user].length;

        // Calculate the starting index
        uint256 start = totalStakes > (pageNumber + 1) * perPage 
                            ? totalStakes - (pageNumber + 1) * perPage 
                            : 0;
                            
        // Calculate the end index
        uint256 end = totalStakes > pageNumber * perPage 
                        ? totalStakes - pageNumber * perPage 
                        : 0;

        // Calculate the size of the page
        uint256 pageSize = end - start;

        // Create the page array
        pageOfStakes = new Stake[](pageSize);

        // Populate the page array with the correct stakes
        for (uint256 i = 0; i < pageSize; i++) {
           pageOfStakes[pageSize - 1 - i] = _allStakes[_allUsersStakeIndexs[user][start + i]];
        }

        return pageOfStakes;
    }
    
     // Get and return a page of withdrawn stakes
    function getPageOfWithdrawnStakesAscending(
        uint256 pageNumber, 
        uint256 perPage
    ) public view returns(WithdrawnStake[] memory)
    {
        // Get the total amount remaining
        uint256 totalWithdrawnStakes = _allWithdrawnStakes.length;

        // Get the index to start from
        uint256 startingIndex = pageNumber * perPage;

        // The number of stakes that will be returned (to set array)
        uint256 remaining = totalWithdrawnStakes - startingIndex;
        uint256 pageSize = ((startingIndex+1)>totalWithdrawnStakes) ? 0 : (remaining < perPage) ? remaining : perPage;

        // Create the page
        WithdrawnStake[] memory pageOfWithdrawnStakes = new WithdrawnStake[](pageSize);

        // Add each item to the page
        uint256 pageItemIndex = 0;
        for(uint256 i = startingIndex;i < (startingIndex + pageSize);i++){
           
           // Get the stake 
           WithdrawnStake memory addedStake = _allWithdrawnStakes[i];

           // Add to page
           pageOfWithdrawnStakes[pageItemIndex] = addedStake;

           // Increment page item index
           pageItemIndex++;
        }

        return pageOfWithdrawnStakes;
    }

    // Get and return a page of withdrawn stakes
    function getPageOfWithdrawnStakesDescending(
        uint256 pageNumber, 
        uint256 perPage
    ) public view returns(WithdrawnStake[] memory pageOfWithdrawnStakes)
    {
        // Get the total amount remaining
        uint256 totalWithdrawnStakes = _allWithdrawnStakes.length;

        // Calculate the starting index
        uint256 start = totalWithdrawnStakes > (pageNumber + 1) * perPage 
                        ? totalWithdrawnStakes - (pageNumber + 1) * perPage 
                        : 0;
                        
        // Calculate the end index
        uint256 end = totalWithdrawnStakes > pageNumber * perPage 
                    ? totalWithdrawnStakes - pageNumber * perPage 
                    : 0;

        // Calculate the size of the page
        uint256 pageSize = end - start;

        // Create the page array
        pageOfWithdrawnStakes = new WithdrawnStake[](pageSize);

        // Populate the page array with the correct stakes
        for (uint256 i = 0; i < pageSize; i++) {
            pageOfWithdrawnStakes[pageSize - 1 - i] = _allWithdrawnStakes[start + i];
        }

        return pageOfWithdrawnStakes;
    }

    // Get and return a page of stakes
    function getPageOfUsersWithdrawnStakesAscending(
        address user, 
        uint256 pageNumber, 
        uint256 perPage) public view returns(WithdrawnStake[] memory)
    {    
        uint256[] memory usersStakeIndexes = _allUsersWithdrawnStakeIndexs[user];

        // Get the total amount remaining
        uint256 totalStakes = usersStakeIndexes.length;

        // Get the index to start from
        uint256 startingIndex = pageNumber * perPage;

        // The number of stakes that will be returned (to set array)
        uint256 remaining = totalStakes - startingIndex;
        uint256 pageSize = ((startingIndex+1)>totalStakes) ? 0 : (remaining < perPage) ? remaining : perPage;

        // Create the page
        WithdrawnStake[] memory pageOfWithdrawnStakes = new WithdrawnStake[](pageSize);

        // Add each item to the page
        uint256 pageItemIndex = 0;
        for(uint256 i = startingIndex;i < (startingIndex + pageSize);i++)
        {   
           // Get the stake 
           WithdrawnStake memory usersStake = _allWithdrawnStakes[usersStakeIndexes[i]];

           // Add to page
           pageOfWithdrawnStakes[pageItemIndex] = usersStake;

           // Increment page item index
           pageItemIndex++;
        }

        return pageOfWithdrawnStakes;
    }

    // Get and return a page of stakes
    function getPageOfUsersWithdrawnStakesDescending(
        address user, 
        uint256 pageNumber, 
        uint256 perPage
    ) public view returns(WithdrawnStake[] memory pageOfWithdrawnStakes)
    {
        // Get the total amount remaining
        uint256 totalStakes = _allUsersWithdrawnStakeIndexs[user].length;

        // Calculate the starting index
        uint256 start = totalStakes > (pageNumber + 1) * perPage 
                        ? totalStakes - (pageNumber + 1) * perPage 
                        : 0;
                        
        // Calculate the end index
        uint256 end = totalStakes > pageNumber * perPage 
                    ? totalStakes - pageNumber * perPage 
                    : 0;

        // Calculate the size of the page
        uint256 pageSize = end - start;

        // Create the page array
        pageOfWithdrawnStakes = new WithdrawnStake[](pageSize);

        // Populate the page array with the correct stakes
        for (uint256 i = 0; i < pageSize; i++) {
            pageOfWithdrawnStakes[pageSize - 1 - i] = _allWithdrawnStakes[_allUsersWithdrawnStakeIndexs[user][start + i]];
        }

        return pageOfWithdrawnStakes;
    }
}