// SPDX-License-Identifier: MIT

pragma solidity 0.8.0;

import "./dct.sol";

contract StakingDCT {
    address public owner;
    mapping (address => bool) public isAdministrator;
    uint256 public totalStaked;
    uint256 public totalPendingStaked;
    mapping (address => Staker) public stakers;
    mapping (address => uint256) public pendingStaking;
    mapping (address => uint256) public stakerMinted;

    mapping (address => bool) public oldStaker;
    mapping (address => bool) public importStaker;
    mapping (address => uint256) public oldStakerValidUntil;

    // miner price, payout per claim, total payout
    mapping (address => uint8) public minerType;  // miner type : 1, 2, 3
    mapping (address => uint256) public minerPrice;
    mapping (uint8 => uint256) public setupMinerPrice;
    // cycle start 0 until 11
    mapping (address => uint8) public minerCycle;
    mapping (address => uint16) public minerRoundCycle;
    mapping (address => uint256) public minerLastPayout;
    mapping (address => uint256) public minerFirstTimeFee;

    mapping (uint8 => uint256) public maxStaking;

    struct Staker {
        uint8 status;   // 0:inactive; 1:active; 2:unstake; 3:burned;
        uint256 lockSetup; // set lock amount when staker claim stake capital
        uint256 lockAmount;
        uint256 amountStaked;
        uint256 lastRewardTime;
        uint256 stakedTimestamp;
        uint256 minerBurnedTimestamp;
    }

    mapping(uint8 => uint64) public stageSchedule;
    mapping(uint8 => uint16) public rewardPercentage; // div 10000

    // address to collect miner usage fee -- tron
    address payable public addrminerfee;
    // address to collect first staking fee -- tron
    address payable public immutable addrfirststakingfee;
    // amount first staking fee;
    uint256 public firststakingfee;
    // address to collect claim transaction fee -- token
    address public addrfee;
    // address to collect claim transaction tax -- token
    address public immutable addrtax;
    uint64 public constant rewardInterval = 8 days;
    uint64 public constant burnedDuration = 90 days;
    // max claim in a row, reset to 0 after 11
    uint8 public constant maxCycle = 11;
    // active stage
    uint8 public nowStage = 2;
    // max stage available
    uint8 public constant maxStage = 7;
    // set up fee each claim token reward
    uint16 public constant claimfee = 100; // 10 div 1000 = 10%
    // set up tax each claim token reward
    uint8 public constant claimtax = 11; // 11 div 1000 = 1.1%
    uint64 public tronRate;    // 1 IDR = xxx trx div 1000000 (6 decimal places)
    // uint256 public flatRate;    
    DegreeCryptoToken public token;

    event Staked(address staker, uint256 amount);
    event ImportStaked(address staker, uint256 amount);
    event Unstaked(address staker, uint256 amount);
    event ClaimedReward(address staker, uint256 reward);
    event ChangeContractOwner(address staker);
    event ChangeTronRate(uint256 amount);
    event ChangeFirstStakingFee(uint256 amount);
    event ChangeMinerPrice(uint256 price, uint8 typeminer);
    event ChangeAdministratorStatus(address adminAddr, bool status);

    modifier onlyOwner() {
        require(msg.sender == owner, "ACCESS_DENIED");
        _;
    }

    modifier onlyAdmin() {
        require(isAdministrator[msg.sender], "ADMIN_ONLY");
        _;
    }

    bool public isOpenImport = true;
    // check import still allowed
    modifier openImport() {
        require(isOpenImport, "IMPORT_CLOSED");
        _;
    }

    constructor(address tokenAddress, address addrfeeinp, address addrtaxinp, address payable addrminerfeeinp, address payable addrfirststakingfeeinp) {
        require(addrfeeinp != address(0), "Invalid address");
        require(addrtaxinp != address(0), "Invalid address");
        require(addrminerfeeinp != address(0), "Invalid address");
        require(addrfirststakingfeeinp != address(0), "Invalid address");
        
        owner = msg.sender;
        token = DegreeCryptoToken(tokenAddress);
        addrfee = addrfeeinp;
        addrtax = addrtaxinp;
        addrminerfee = addrminerfeeinp;
        addrfirststakingfee = addrfirststakingfeeinp;

        rewardPercentage[1] = 375;  // 375 div 10000 = 3.75%
        rewardPercentage[2] = 300;  // 300 div 10000 = 3%
        rewardPercentage[3] = 250;  // 250 div 10000 = 2.5%
        rewardPercentage[4] = 200;  // 200 div 10000 = 2%
        rewardPercentage[5] = 150;  // 150 div 10000 = 1.5%
        rewardPercentage[6] = 100;  // 100 div 10000 = 1%
        rewardPercentage[7] = 50;  // 50 div 10000 = 0.5%

        stageSchedule[1] = 1680282001;  // Saturday, April 1, 2023 0:00:01 AM GMT+07:00
        stageSchedule[2] = 1743354001;  // Monday, March 31, 2025 0:00:01 AM GMT+07:00
        stageSchedule[3] = 1806426001;  // Wednesday, March 31, 2027 0:00:01 AM GMT+07:00
        stageSchedule[4] = 1869498001;  // Friday, March 30, 2029 0:00:01 AM GMT+07:00
        stageSchedule[5] = 1932570001;  // Sunday, March 30, 2031 0:00:01 AM GMT+07:00
        stageSchedule[6] = 1995642001;  // Tuesday, March 29, 2033 0:00:01 AM GMT+07:00
        stageSchedule[7] = 2058714001;  // Thursday, March 29, 2035 0:00:01 AM GMT+07:00

        uint256 decimaldigit = 10 ** uint256(token.decimals());
        // max staking by type
        maxStaking[1] = 10 * decimaldigit;
        maxStaking[2] = 50 * decimaldigit;
        maxStaking[3] = 200 * decimaldigit;
        // miner pcice by type (IDR currency)
        setupMinerPrice[1] = 1650000;
        setupMinerPrice[2] = 7770000;
        setupMinerPrice[3] = 31080000;

        firststakingfee = 50000;
    }

    //update stage when now time > schedule and nowstage < maxstage
    function _checkStage() internal virtual {
        if((nowStage < maxStage) && (block.timestamp > stageSchedule[nowStage])) {
            nowStage = nowStage + 1;
        }
    }

    // calc reward
    function _calcReward(address staker) internal view returns (uint256){
        uint256 dailyReward = (stakers[staker].amountStaked * rewardPercentage[nowStage]) / (10000);
        return dailyReward;
    }

    function _calcFirstStakingFee() internal view returns (uint256){
        uint256 resFee = (firststakingfee * 1000000 * tronRate) / 1000000;
        return resFee;
    }

    function _calcMinerClaimPayout(address staker) internal view returns (uint256){
        uint256 claimPayout = ((minerPrice[staker] * 1000000 * tronRate) / 1000000) / maxCycle; // tron rate 6 decimal point
        return claimPayout;
    }

    function _calcResMinerClaimPayout(address staker) internal view returns (uint256){
        uint256 nextshare = stakers[staker].lastRewardTime + rewardInterval;
        uint256 payoutLeft;
        if(minerRoundCycle[staker] > 0 && minerCycle[staker] == 0 && block.timestamp < nextshare) {
            payoutLeft = 0;
        } else {
            uint256 minerClaimPayout = _calcMinerClaimPayout(staker);
            payoutLeft = (maxCycle - minerCycle[staker]) * minerClaimPayout;
         }        
        return payoutLeft;
    }

    function _burnStaker(address staker) internal virtual {
        uint256 amount = stakers[staker].amountStaked + pendingStaking[staker];
        uint256 toburn = 0;
        uint256 totallocked = (stakers[staker].lockAmount) + (stakers[staker].lockSetup);
        if(amount <= totallocked) {
            // burn amount
            toburn = amount;
            require(token.burn(amount), "Failed staker burned");
        } else {
            // transfer rest token
            require(token.transfer(staker, (amount - totallocked)), "Failed transfer token!");
            toburn = totallocked;
            // burn lock
            require(token.burn(toburn), "Failed staker burned");
        }

        totalStaked = totalStaked - toburn;
        
        // reset all data
        stakers[staker].status = 0;
        stakers[staker].lockAmount = 0;
        stakers[staker].amountStaked = 0;
        stakers[staker].lastRewardTime = 0;
        stakers[staker].stakedTimestamp = 0;
        stakers[staker].minerBurnedTimestamp = 0;

        pendingStaking[staker] = 0;

        stakerMinted[staker] = 0;
        minerLastPayout[staker] = 0;

        minerCycle[staker] = 0;
        minerRoundCycle[staker] = 0;

        oldStaker[staker] = false;
        importStaker[staker] = false;
        oldStakerValidUntil[staker] = 0;
    }

    function calcFirstStakingFee() public view returns (uint256){
        return _calcFirstStakingFee();
    }

    function calcMinerClaimPayout() public view returns (uint256){
        require(minerPrice[msg.sender] > 0, "Miner price not set");
        return _calcMinerClaimPayout(msg.sender);
    }

    function calcResMinerClaimPayout() public view returns (uint256){
        require(minerPrice[msg.sender] > 0, "Miner price not set");
        uint256 payoutLeft = _calcResMinerClaimPayout(msg.sender);
        return payoutLeft;
    }

    // do stake
    function stake(uint256 amount) payable public returns (bool) {
        uint256 allowance = token.allowance(msg.sender, address(this));
        // validate allowance
        require(allowance >= amount, "Invalid allowance");
        require(stakers[msg.sender].status<=2, "Staker stoped/burned");

        if(!(stakers[msg.sender].status == 2 && minerCycle[msg.sender] == 11) && stakers[msg.sender].amountStaked > 0) {
            require(block.timestamp <= (stakers[msg.sender].lastRewardTime + rewardInterval), "There are rewards that have not been claimed");
        }

        if(stakers[msg.sender].minerBurnedTimestamp > 0 && block.timestamp >= stakers[msg.sender].minerBurnedTimestamp) {
            _burnStaker(msg.sender);
        }

        // amount gt 0
        require(amount > 0, "Amount to stake must be greater than 0");
        // tokenSuply + amount should be less than maxSupply
        require((token.totalSupply() + amount) < token.maxSupply(), "Amount to stake must be less than maxSupply");
        // amountStaked+amount lt or the same with maxStaking
        if(stakers[msg.sender].amountStaked == 0) {
            minerType[msg.sender] = 1;
        }
        require((stakers[msg.sender].amountStaked + pendingStaking[msg.sender] + amount) <= maxStaking[minerType[msg.sender]], string(abi.encodePacked("Maximum staking ", maxStaking[minerType[msg.sender]])));

        _checkStage();

        // staking for the first time
        if(stakers[msg.sender].amountStaked==0 && minerCycle[msg.sender]==0) {
            minerFirstTimeFee[msg.sender] = _calcFirstStakingFee();
        }

        // pay only once every round cycle
        if(minerFirstTimeFee[msg.sender] > 0 && minerCycle[msg.sender] == 0) {
            addrfirststakingfee.transfer(minerFirstTimeFee[msg.sender]);
            minerFirstTimeFee[msg.sender] = 0;
        }        
        
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        // if amount staked == 0
        if(stakers[msg.sender].amountStaked>0) {
            pendingStaking[msg.sender] = pendingStaking[msg.sender] + amount;
            totalPendingStaked = totalPendingStaked + amount;
            stakers[msg.sender].minerBurnedTimestamp = 0;
            // miner status unstaked   
            if(stakers[msg.sender].status == 2) {
                // change miner status to 1
                stakers[msg.sender].status = 1;
                stakers[msg.sender].stakedTimestamp = block.timestamp;
                stakers[msg.sender].lastRewardTime = block.timestamp;
                // minerCycle start from 0
                minerCycle[msg.sender] = 0;
                minerRoundCycle[msg.sender] = 0;
                minerPrice[msg.sender] = setupMinerPrice[minerType[msg.sender]];
            }            
        } else {
            minerPrice[msg.sender] = setupMinerPrice[minerType[msg.sender]];
            stakers[msg.sender].lockSetup = 4000000000000000000;
            stakers[msg.sender].lockAmount = 0;

            stakers[msg.sender].stakedTimestamp = block.timestamp;
            
            stakers[msg.sender].minerBurnedTimestamp = 0;
            
            stakers[msg.sender].status = 1;
            stakers[msg.sender].amountStaked = amount;
            stakers[msg.sender].lastRewardTime = block.timestamp;
            totalStaked = totalStaked + amount;
        }

        emit Staked(msg.sender, amount);
        return true;
    }

    function unstake() payable public returns (bool) {
        require(stakers[msg.sender].status==1, "Miner not active");
        require(stakers[msg.sender].amountStaked>0, "No staking available");

        _checkStage();

        if(oldStaker[msg.sender]) {
            // minerCycle[msg.sender] = 0;
            // minerFirstTimeFee[msg.sender] = _calcFirstStakingFee();
            oldStaker[msg.sender] = false;
        } else {
            // calculate the remaining miner fees that must be paid
            uint256 payoutLeft = _calcResMinerClaimPayout(msg.sender);

            addrminerfee.transfer(payoutLeft);
            minerLastPayout[msg.sender] = payoutLeft;
        }

        // set lock token 
        uint256 amountToLocked = stakers[msg.sender].lockAmount + stakers[msg.sender].lockSetup;
        uint256 amountToClaim = stakers[msg.sender].amountStaked + pendingStaking[msg.sender];
        require(amountToClaim > amountToLocked, "Staked amount less than locked staking!");
        
        uint256 amount = amountToClaim - amountToLocked;
        require(token.transfer(msg.sender, amount), "Transfer failed");

        // time allowed to burn miner (burnedDuration)
        stakers[msg.sender].minerBurnedTimestamp = block.timestamp + burnedDuration;

        // reset data
        totalStaked = totalStaked - amount;
        totalPendingStaked = totalPendingStaked - pendingStaking[msg.sender];
        pendingStaking[msg.sender] = 0;
        stakers[msg.sender].status = 2;
        stakers[msg.sender].lockAmount = amountToLocked;
        stakers[msg.sender].amountStaked = amountToLocked;

        emit Unstaked(msg.sender, amount);
        return true;
    }

    function claimReward() payable public returns (bool) {
        require(stakers[msg.sender].status==1 || stakers[msg.sender].status==2, "Staker status not active");
        if(stakers[msg.sender].minerBurnedTimestamp > 0 && block.timestamp >= stakers[msg.sender].minerBurnedTimestamp) {
            revert("Staking burned duration exceeded");
        }
        require(block.timestamp >= (stakers[msg.sender].lastRewardTime + rewardInterval), "Cannot claim reward before interval");

        _checkStage();

        if(stakers[msg.sender].status==2) {
            require(minerCycle[msg.sender] < maxCycle, "Miner unstaked. Max cycle exceeded");
            minerCycle[msg.sender] = minerCycle[msg.sender] + 1;
        } else {
            // for oldstaker only
            if(oldStaker[msg.sender]) {                
                // change oldstaker status to false when now > minervaliduntil
                if(block.timestamp > oldStakerValidUntil[msg.sender]) {
                    oldStaker[msg.sender] = false;
                    minerCycle[msg.sender] = 0;
                    minerRoundCycle[msg.sender] = 0;
                    oldStakerValidUntil[msg.sender] = 0;
                }

                minerCycle[msg.sender] = minerCycle[msg.sender] + 1;
                if(minerCycle[msg.sender] >= maxCycle) {
                    oldStaker[msg.sender] = false;
                    oldStakerValidUntil[msg.sender] = 0;
                    minerCycle[msg.sender] = 0;
                    minerFirstTimeFee[msg.sender] = _calcFirstStakingFee();
                    minerRoundCycle[msg.sender] = minerRoundCycle[msg.sender] + 1;
                    minerPrice[msg.sender] = setupMinerPrice[minerType[msg.sender]];
                }
            } else if(!oldStaker[msg.sender]) {
                // only new staker
                // miner payouts every claim
                // transfer trx to addrminerfee
                uint256 minerClaimPayout = _calcMinerClaimPayout(msg.sender);

                require(msg.sender.balance >= minerClaimPayout, "Insufficient balance.");
                addrminerfee.transfer(minerClaimPayout);
                minerLastPayout[msg.sender] = minerClaimPayout;
                minerCycle[msg.sender] = minerCycle[msg.sender] + 1;
                if(minerCycle[msg.sender]>=maxCycle) {
                    minerCycle[msg.sender] = 0;
                    minerFirstTimeFee[msg.sender] = _calcFirstStakingFee();
                    minerRoundCycle[msg.sender] = minerRoundCycle[msg.sender] + 1;
                    minerPrice[msg.sender] = setupMinerPrice[minerType[msg.sender]];
                }
            }
        }

        uint256 dailyReward = _calcReward(msg.sender);
        uint256 amountfee = dailyReward * (claimfee) / (1000); // calc fee 10%
        uint256 amounttax = dailyReward * (claimtax) / (1000); // calc tax 1.1%
        uint256 reward = dailyReward - (amountfee) - (amounttax);
        require(reward > 0, "Reward must be greater than 0");
        // mint for reward staker
        require(token.mint(msg.sender, reward), "Reward transfer failed");
        // mint for fee
        require(token.mint(addrfee, amountfee), "Reward fee transfer failed");
        // mint for tax
        require(token.mint(addrtax, amounttax), "Reward tax transfer failed");
        stakerMinted[msg.sender] = stakerMinted[msg.sender] + dailyReward;
        stakers[msg.sender].lastRewardTime = (stakers[msg.sender].lastRewardTime) + (rewardInterval);

        // if available pending staking
        if(pendingStaking[msg.sender] > 0) {
            stakers[msg.sender].amountStaked = (stakers[msg.sender].amountStaked) + (pendingStaking[msg.sender]);
            totalStaked = totalStaked + (pendingStaking[msg.sender]);
            totalPendingStaked = totalPendingStaked - (pendingStaking[msg.sender]);
            pendingStaking[msg.sender] = 0;
        }

        emit ClaimedReward(msg.sender, reward);
        return true;
    }

    function importOldStaker(address staker, uint8 xstatus, uint8 typeminer, uint256 locksetup, uint256 lockAmount, uint256 stakedTimestamp, uint256 amountStaked, uint256 pendingStaked, uint256 lastReward, uint256 minervaliduntil, uint8 minercycle) public onlyAdmin openImport returns (bool) {
        require(typeminer>=1 && typeminer<=3, "Invalid miner type");
        require(xstatus==1, "Status not running");
        require(stakers[staker].status==0, "Already running");

        // transfer from admin to staking smartcontact
        require(token.transferFrom(msg.sender, address(this), amountStaked), "Transfer failed");

        oldStaker[staker] = true;
        importStaker[staker] = true;
        oldStakerValidUntil[staker] = minervaliduntil;

        // set miner price
        minerType[staker] = typeminer;
        minerPrice[staker] = setupMinerPrice[typeminer];

        stakers[staker].status = xstatus;
        
        stakers[staker].lockSetup = locksetup;
        stakers[staker].lockAmount = lockAmount;
        stakers[staker].stakedTimestamp = stakedTimestamp;
        stakers[staker].minerBurnedTimestamp = 0;

        stakers[staker].amountStaked = amountStaked;
        stakers[staker].lastRewardTime = lastReward;
        totalStaked = totalStaked + amountStaked;

        pendingStaking[staker] = pendingStaked;
        totalPendingStaked = totalPendingStaked + pendingStaked;

        minerCycle[staker] = minercycle;

        emit ImportStaked(msg.sender, amountStaked);
        return true;
    }

    function burnStaker(address staker) public onlyOwner returns (bool) {
        require(stakers[staker].minerBurnedTimestamp > 0 && block.timestamp>stakers[staker].minerBurnedTimestamp, "It's not time to burn yet");
        _burnStaker(staker);
        return true;
    }

    // set 1 IDR = xxx tron div 1000000 (6 decimal places)
    function setTronRate(uint64 rateTron) public onlyOwner returns (bool) {
        require(rateTron > 0, "Zero rate");
        tronRate = rateTron;
        emit ChangeTronRate(tronRate);
        return true;
    }
    // IDR Currentcy
    function setFirstStakingFee(uint256 feeFirstStaking) public onlyOwner returns (bool) {
        require(feeFirstStaking > 0, "Zero amount");
        firststakingfee = feeFirstStaking;
        emit ChangeFirstStakingFee(firststakingfee);
        return true;
    }

    // update miner price (IDR Currency)
    function updateMinerPrice(uint256 price, uint8 typeminer) public onlyOwner returns (bool) {
        require(typeminer>=1 && typeminer<=3, "Invalid miner type");
        setupMinerPrice[typeminer] = price;
        emit ChangeMinerPrice(price, typeminer);
        return true;
    }

    function changeAddrFee(address newAddr) public onlyOwner returns (bool) {
        require(newAddr != address(0), "Zero address");
        addrfee = newAddr;
        return true;
    }

    function changeAddrMinerFee(address payable newAddr) public onlyOwner returns (bool) {
        require(newAddr != address(0), "Zero address");
        addrminerfee = newAddr;
        return true;
    }

    function changeContractOwnership(address newOwner) public onlyOwner returns (bool) {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
        emit ChangeContractOwner(newOwner);
        return true;
    }

    function setAdministrator(address adminAddr, bool status) public onlyOwner returns (bool) {
        require(adminAddr != address(0), "Zero address");
        isAdministrator[adminAddr] = status;
        emit ChangeAdministratorStatus(adminAddr, status);
        return true;
    }

    function closeImport() public onlyOwner returns (bool) {
        require(isOpenImport, "IMPORT_CLOSED");
        isOpenImport = false;
        return true;
    }

    function getStakerInfo(address staker) public view returns (
        uint8 status,   
        uint256 maxStakingx,
        uint256 lockSetup, 
        uint256 lockAmount,
        uint256 amountStaked,
        uint256 lastRewardTime,
        uint256 minerBurnedTimestamp, 
        uint256 rpendingStaking) {
        
        status = stakers[staker].status;   
        maxStakingx = maxStaking[minerType[staker]];
        lockSetup = stakers[staker].lockSetup; 
        lockAmount = stakers[staker].lockAmount;
        amountStaked = stakers[staker].amountStaked;
        lastRewardTime = stakers[staker].lastRewardTime;
        minerBurnedTimestamp = stakers[staker].minerBurnedTimestamp; 
        rpendingStaking = pendingStaking[staker];
    }

    function getAmountStaked(address staker) public view returns (uint256) {
        return stakers[staker].amountStaked;
    }

    function getLastRewardTime(address staker) public view returns (uint256) {
        return stakers[staker].lastRewardTime;
    }

    function getNextRewardTime(address staker) public view returns (uint256) {
        uint256 nextshare;
        if(stakers[staker].lastRewardTime > 0) {
            nextshare = (stakers[staker].lastRewardTime) + (rewardInterval);
        } else {
            nextshare = 0;
        }
        return nextshare;
    }

    function getClaimableReward(address staker) public view returns (uint256) {
        require(stakers[staker].amountStaked > 0, "Staker must have staked a positive amount");
        uint256 elapsedTime = uint256(block.timestamp - stakers[staker].lastRewardTime) / rewardInterval;

        uint256 dailyReward = _calcReward(staker);
        // reward every rewardInterval
        uint256 reward = dailyReward * (elapsedTime);
        return reward;
    }
}
