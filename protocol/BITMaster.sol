// SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.1;

/*
 *  @title Wildland's Master contract
 *  Copyright @ Wildlands
 *  App: https://wildlands.me
 */

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import "./IWildlandCards.sol";
import "./BitGold.sol";
import "./BitRAM.sol";

//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once bit is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract BitMaster is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeMath for uint32;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many tokens the user has staked.
        uint256 rewardDebt; // Reward debt.
        uint256 lockedAt;   // Unix time locked at 
    }
    

    // Info of each pool.
    struct PoolInfo {
        IERC20 stakeToken;        // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. bits to distribute per block.
        uint256 lastRewardBlock;  // Last block number that bits distribution occurs.
        uint256 accBitsPerShare;  // Accumulated bits per share, times 1e12. See below.
        uint256 lockTimer;        // lock counter in seconds (ethereum has non-fixed blocks per day)
        uint16 depositFeeBP;      
        uint16 burnDepositFeeBP;          
        uint16 withdrawFeeBP;      
        uint16 burnWithdrawFeeBP;  
        bool requireMembership;        
    }
    

    // The bit TOKEN!
    BitGold public bit;
    // The ram... where rewards are stored until users unstake or collect
    BitRAM public ram;
    uint32 public MAX_PERCENT = 1e4; // for avoiding errors while programming, never use magic numbers :)
    uint256 public DECIMALS_TOKEN = 1e18;
    uint256 public DECIMALS_SHARE_REWARD = 1e18;
    address public DEAD_ADDRESS = address(0x000000000000000000000000000000000000dEaD);
    // Treasury address.
    address public treasuryaddr;
    uint256 public UNITS_PER_DAY = 86400 / 12; // 7200 blocks per day
    // bit tokens created per blocks based on max supply (11m-1m = 10m).
    uint256 public bitPerBlock = (10 * 10 ** 6 - 145000) * DECIMALS_TOKEN / (2 * 365 * UNITS_PER_DAY);

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint; // in 1e3
    // The block number when bit mining starts.
    uint256 public startBlock; // in 1e0
    mapping(IERC20 => bool) public poolExistence;
    bool public paused;
    // codes of affiliatees
    mapping (address => bytes4) public affiliatee;
    // member cards serve as affiliate token to earn part of staking fees that have to be paid when staking (non-inflationary)
    IWildlandCards public wildlandcard;

    // white list addresses as member and exclude from fees (e.g., partner contracts)
    mapping (address => bool) public isWhiteListed;
    mapping (address => bool) public IsExcludedFromFees;

    event EmitDeposit(address indexed user, uint256 indexed pid, uint256 amount, uint256 lockedFor);
    event EmitWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmitEmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmitSet(uint256 pid, uint256 allocPoint, uint256 lockTimer, uint16 depositFeeBP, uint16 burnDepositFeeBP, uint16 withdrawFeeBP, uint16 burnWithdrawFeeBP, bool isMember);
    event EmitAdd(address token, uint256 allocPoint, uint256 lockTimer, uint16 depositFeeBP, uint16 burnDepositFeeBP, uint16 withdrawFeeBP, uint16 burnWithdrawFeeBP, bool isMember);
    event EmitTreasuryChanged(address _new);
    event CodeFailed(uint256 tokenId);
    event CodeSuccess(bytes4 code, uint256 tokenId);
    event CodeSet(address indexed user, bytes4 code);
    event SetStartblock(uint256 startBlock);
    event ExcludedFromFees(address user);
    event WhiteListed(address user);
    event SetPaused(bool paused);

    constructor(
        BitGold _bit,
        BitRAM _ram,
        IWildlandCards _wildlandcard,
        address _treasuryaddr
    ) {
        bit = _bit;
        ram = _ram;
        wildlandcard = _wildlandcard;
        treasuryaddr = _treasuryaddr;

        // staking pool
        poolInfo.push(PoolInfo({
            stakeToken: _bit,
            allocPoint: 1000,
            lastRewardBlock: startBlock,
            accBitsPerShare: 0,
            lockTimer: 0,
            depositFeeBP: 300,
            burnDepositFeeBP: 200,
            withdrawFeeBP: 300,
            burnWithdrawFeeBP: 200,
            requireMembership: true
        }));
        poolExistence[_bit] = true;
        totalAllocPoint = 1000;
    }

    /// SECION MODIFIERS

    /**
     * @notice Validate if pool exists
     */
    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "validatePool: pool exists?");
        _;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /**
     * @notice Check that no pool is added twice.
     */
    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "add: existing pool");
        _;
    }

    /**
     * @notice Check if membership is required and if so, check if msg.sender has membership (see isMember function).
     */
    modifier requireMembership(uint256 _pid) {
        // either affiliate code or member card required
        require(!poolInfo[_pid].requireMembership || isMember(msg.sender), "restricted: affiliate code required.");
        _;
    }

    /// SECION POOL AND MINE DATA

    /** 
     * @notice Add a new lp to the pool. Can only be called by the owner.
     * It will be automatically checked if pool is duplicate.
     * Fee: Max fee 10% = fee base points <= 1000 (MAX_PERCENT = 1e4).
     * _lockTimer is measured in unix time.
     * onlyOwner protected.
     */
    function add(uint256 _allocPoint, IERC20 _token, uint256 _lockTimer, uint16 _depositFeeBP, uint16 _burnDepositFeeBP, uint16 _withdrawFeeBP, uint16 _burnWithdrawFeeBP, bool _withUpdate, bool _requireMembership) public onlyOwner nonDuplicated(_token) {
        require(_depositFeeBP <= MAX_PERCENT.div(10), "add: invalid deposit fee basis points"); // max 10%
        require(_burnDepositFeeBP <= _depositFeeBP, "add: invalid burn deposit fee basis points"); // max 100% of deposit fee
        require(_withdrawFeeBP <= MAX_PERCENT.div(10), "add: invalid withdraw fee basis points"); // max 10%
        require(_burnWithdrawFeeBP <= _withdrawFeeBP, "add: invalid burn withdraw fee basis points"); // max 100% of withdraw fee
        require(_lockTimer <= 30 days, "add: invalid time locked. Max allowed is 30 days in seconds");
        if (_withUpdate) {
            _massUpdatePools();
        }
        // BEP20 interface check
        _token.balanceOf(address(this));
        // check lp token exist -> revert if you try to add same lp token twice
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        // add pool info
        poolInfo.push(PoolInfo({
            stakeToken: _token, // the lp token
            allocPoint: _allocPoint, //allocation points for new farm. 
            lastRewardBlock: lastRewardBlock, // last block that got rewarded
            accBitsPerShare: 0, 
            lockTimer: _lockTimer,
            depositFeeBP: _depositFeeBP,
            burnDepositFeeBP: _burnDepositFeeBP,
            withdrawFeeBP: _withdrawFeeBP,
            burnWithdrawFeeBP: _burnWithdrawFeeBP,
            requireMembership: _requireMembership
        }));
        poolExistence[_token] = true;
        updateStakingPool();
        emit EmitAdd(address(_token), _allocPoint, _lockTimer, _depositFeeBP, _burnDepositFeeBP, _withdrawFeeBP, _burnWithdrawFeeBP, _requireMembership);
    }

    /** 
     * @notice Update the given pool's bit allocation point. Can only be called by the owner.
     * Fee: Max fee 10% = fee base points <= 1000 (MAX_PERCENT = 1e4).
     * _lockTimer is measured in blocks.
     * onlyOwner protected.
     */
    function set(uint256 _pid, uint256 _allocPoint, uint256 _lockTimer, uint16 _depositFeeBP, uint16 _burnDepositFeeBP, uint16 _withdrawFeeBP, uint16 _burnWithdrawFeeBP, bool _withUpdate, bool _requireMembership) public onlyOwner validatePool(_pid) {
        require(_depositFeeBP <= MAX_PERCENT.div(10), "set: invalid deposit fee basis points"); // max 10%
        require(_burnDepositFeeBP <= _depositFeeBP, "set: invalid burn deposit fee basis points"); // max 100% of deposit fee
        require(_withdrawFeeBP <= MAX_PERCENT.div(10), "set: invalid withdraw fee basis points"); // max 10%
        require(_burnWithdrawFeeBP <= _withdrawFeeBP, "set: invalid burn withdraw fee basis points"); // max 100% of withdraw fee
        require(_lockTimer <= 30 days, "set: invalid time locked. Max allowed is 30 days in seconds");
        if (_withUpdate)
            _updatePool(_pid);
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        // update values
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].burnDepositFeeBP = _burnDepositFeeBP;
        poolInfo[_pid].withdrawFeeBP = _withdrawFeeBP;
        poolInfo[_pid].burnWithdrawFeeBP = _burnWithdrawFeeBP;
        poolInfo[_pid].lockTimer = _lockTimer;
        poolInfo[_pid].requireMembership = _requireMembership;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
            updateStakingPool();
        }
        emit EmitSet(_pid, _allocPoint, _lockTimer, _depositFeeBP, _burnDepositFeeBP, _withdrawFeeBP, _burnWithdrawFeeBP, _requireMembership);
    }
    /**
     * @notice Update reward variables for all pools. Be careful of gas spending! (external)
     * nonReentrant protected.
     */
    function massUpdatePools() external nonReentrant {
        _massUpdatePools();
    }

    /**
     * @notice Update reward variables for all pools. Be careful of gas spending!
     */
    function _massUpdatePools() internal {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            _updatePool(pid);
        }
    }

    /**
     * @notice Update multiplier of staking pool (_pid=0).
     */
    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points.add(poolInfo[pid].allocPoint);
        }
        // won't update unless allocation points of pool > 0 
        if (points != 0 && poolInfo[0].allocPoint != 0) {
            points = points.div(3);
            totalAllocPoint = totalAllocPoint.sub(poolInfo[0].allocPoint).add(points);
            poolInfo[0].allocPoint = points;
        }
    }

    /**
     * @notice Return reward multiplier based on _from and _to block number.
     */
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (paused)
            return 0;
        return _to.sub(_from);
    }

    /**
     * @notice Apply having every 365 * UNITS_PER_DAY blocks (approx 1 year).
     * Given _amount is divided by 2 ** i where i = number of passed years (>= 0).
     */
    function applyHalfing(uint256 _amount, uint256 testcounter) public view returns (uint256) {
        // start block not reached -> no reward
        // start block not set -> no reward
        if (block.number < startBlock || startBlock == 0)
            return 0;
        // current active block counter
        uint256 blocks = block.number.add(testcounter).sub(startBlock);
        // halfing every 365 days (approx) -> every 365 * UNITS_PER_DAY blocks
        uint256 i = blocks.div(UNITS_PER_DAY.mul(365)); // 0 if less than 365 days have passed
        return _amount.div(2**i);
    }
    
    /**
     * @notice Minting info per block based on halfing and pause state.
     */
    function mintingInfo() external view returns(uint256) {
		return applyHalfing(bitPerBlock.mul(getMultiplier(0,1)), 0);
    }    
    
    /**
     * @notice Update pool (external)
     * nonReentrant protected.
     */
    function updatePool(uint256 _pid) external nonReentrant {
        _updatePool(_pid);
    }

    /**
     * @notice Update pool (internal).
     */
    function _updatePool(uint256 _pid) internal validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.stakeToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        // bit reward
        uint256 bitReward = applyHalfing(multiplier.mul(bitPerBlock).mul(pool.allocPoint).div(totalAllocPoint), 0);
        if (bitReward != 0) {
            uint256 fee_tres = bitReward.div(10); 
            // 1) Mint to ram
            bit.mint(address(ram), bitReward);
            // 2) transfer fee from ram to treasury
            safeBitTransfer(treasuryaddr, fee_tres);
            // 3) bit reward is deducted by fee
            bitReward = bitReward.sub(fee_tres);
            // set new distribution per LP
            pool.accBitsPerShare = pool.accBitsPerShare.add(bitReward.mul(DECIMALS_SHARE_REWARD).div(lpSupply));
        }
        pool.lastRewardBlock = block.number;
    }

    /**
     * @notice Returns pending bits for given pool _pid.
     */
    function pendingBit(uint256 _pid, address _user) external view returns (uint256) {
        // get pool info in storage
        PoolInfo storage pool = poolInfo[_pid];
        // get user info in storage
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accBitsPerShare = pool.accBitsPerShare;
        uint256 lpSupply = pool.stakeToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0 && totalAllocPoint != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            // bits per block * 90% 
            uint256 bitReward = applyHalfing(multiplier.mul(bitPerBlock).mul(pool.allocPoint).div(totalAllocPoint), 0);
            accBitsPerShare = accBitsPerShare.add(bitReward.mul(9).div(10).mul(DECIMALS_SHARE_REWARD).div(lpSupply));
        }
        return user.amount.mul(accBitsPerShare).div(DECIMALS_SHARE_REWARD).sub(user.rewardDebt);
    }
    
    /**
     * @notice Remaining locked time in seconds for given _pid and _user.
     */
    function timeToUnlock(uint256 _pid, address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_pid][_user];
        PoolInfo storage pool = poolInfo[_pid];
        uint256 _time_required = user.lockedAt.add(pool.lockTimer);
        if (_time_required <= block.timestamp)
            return 0;
        else
            return _time_required.sub(block.timestamp);
    }

    /// SECTION AFFILIATE

    /**
     * @notice check if _user is member.
     * Meber means: _user has either an affiliate code set (see setCode function), owns or has owned a wildlands member card.
     * or is a whitelisted address, e.g., a partner contract.
     */
    function isMember(address _user) public view returns(bool) {
        // either be an affiliator or an affiliatee
        // affiliators who sold their member card, stay members
        return affiliatee[_user] != 0x0 || wildlandcard.getCodeByAddress(_user) != 0x0 || isWhiteListed[_user];
    }

    /**
     * @notice Get affiliate base points for a given _user.
     * The affilite mechansims has 4 levels (3 vip and 1 standard). 
     * Affiliates get a portion of the fees based on the member level. 
     * There are 1000 VIP MEMBER CARDS (id 1 - 1000) and INFINTITY STANDARD MEMBER CARDS (1001+).
     * affiliatee[_user] is the affiliate code that _user used to be a member (see setCode function).
     */
    function getAffiliateBasePoints(address _user) public view returns (uint256) {
        // get affiliate id
        uint256 tokenId = wildlandcard.getTokenIdByCode(affiliatee[_user]);
        // check affiliate id
        if (tokenId == 0)
            return 0;
        else if (tokenId <= 100) {
            // BIT CARD MEMBER
            return 20; // 20 %
        }
        else if (tokenId <= 400) {
            // GOLD CARD MEMBER
            return 15; // 15 %
        }
        else if (tokenId <= 1000) {
            // BLACK CARD MEMBER
            return 10; // 10 %
        }
        // STANDARD MEMBER CARD
        return 5; // 5 %
    }

    /**
     * @notice Set affiliate code
     * The affiliate code of msg.sender is stored in affiliatee[msg.sender]. 
     * Affiliate fees are to the current token owner that is linked to the provided _code.
     * nonReentrant protected.
     */
    function setCode(bytes4 _code) public nonReentrant {
        require(affiliatee[msg.sender] == 0x0, "setCode: Affiliate code already set");
        require(wildlandcard.getTokenIdByCode(_code) != 0 && _code != 0x0, "setCode: Code is not valid");
        affiliatee[msg.sender] = _code;
        emit CodeSet(msg.sender, _code);
    }

    /**
     * @notice Process fee, burn fee and affiliate fees.
     * If burn fee is lower than total fee, an affiliate fee is computed if token_id > 0.
     * Affiliate fees are sent to the CURRENT token owner.
     * Difference of _amount_fee - (_burn_fee + affiliateFee) is sent to treasury.
     */
    function handleFee(uint256 _pid, uint256 _amount_fee, uint256 _burn_fee) internal {
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 token = pool.stakeToken;
        // burn portion of fees if > 0
        if (_burn_fee > 0)
            token.safeTransfer(DEAD_ADDRESS, _burn_fee);
        // transfer fees - burn to treasury/affiliates if > 0              
        if (_burn_fee < _amount_fee) {
            // get transferrable fee
            uint256 feeTransferable = _amount_fee.sub(_burn_fee);
            bytes4 code = affiliatee[msg.sender];
            uint256 tokenId = wildlandcard.getTokenIdByCode(code);
            uint256 affiliateFee = 0;
            if (tokenId > 0) {
                // compute affiliate fee (definitely > 0 since feeTransferable > 0 at this point)
                uint256 affiliateBasePoints = getAffiliateBasePoints(msg.sender);
                affiliateFee = feeTransferable.mul(affiliateBasePoints).div(100);
                // transfer affiliate fee to owner of member card id
                token.safeTransfer(wildlandcard.ownerOf(tokenId), affiliateFee);
            }
            // transfer to treasury
            token.safeTransfer(treasuryaddr, feeTransferable.sub(affiliateFee));
        }
    }

    /// USER ACTIONS

    /**
     * @notice Depost token _amount in pool _pid
     * Checks if membership is required and validates given pool id _pid.
     * nonReentrant protected.
     */
    function deposit(uint256 _pid, uint256 _amount) external validatePool(_pid) nonReentrant requireMembership(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        _updatePool(_pid);
        if (user.amount > 0) {
            // transfer pending nuts to user since reward debts are updated below
            uint256 pending = user.amount.mul(pool.accBitsPerShare).div(DECIMALS_SHARE_REWARD).sub(user.rewardDebt);
            if(pending > 0) {
                safeBitTransfer(msg.sender, pending);
            }
        }
        uint256 lockedFor = 0;
        if (_amount > 0) {
            uint256 amount_fee = 0;
            uint256 amount_old = user.amount; // neded for avg lock computation
            // check transfer to also allow fee on transfer
            uint256 preStakeBalance = pool.stakeToken.balanceOf(address(this));
            pool.stakeToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            uint256 postStakeBalance = pool.stakeToken.balanceOf(address(this));
            // transferred/staked amount is difference between post and pre
            _amount = postStakeBalance.sub(preStakeBalance);
            if(pool.depositFeeBP > 0 && !IsExcludedFromFees[msg.sender]){
                // depositFeeBP is factor 10000 (MAX_PERCENT) overall
                amount_fee = _amount.mul(pool.depositFeeBP).div(MAX_PERCENT);
                uint256 burn_fee = amount_fee.mul(pool.burnDepositFeeBP).div(pool.depositFeeBP);
                handleFee(_pid, amount_fee, burn_fee);
            }
            // store user amount
            user.amount = user.amount.add(_amount).sub(amount_fee);
            // set new locked amount based on average locking window
            lockedFor = timeToUnlock(_pid, msg.sender);
            // avg lockedFor: (lockedFor * amount_old + lockTimer * (_amount - amount_fee)) / user.amount
            lockedFor = lockedFor.mul(amount_old).add(pool.lockTimer.mul(_amount.sub(amount_fee))).div(user.amount);
            // set new locked at 
            user.lockedAt = block.timestamp.sub(pool.lockTimer.sub(lockedFor));
        }
        // user reward debt since there are already many nuts that had been produced before :)
        user.rewardDebt = user.amount.mul(pool.accBitsPerShare).div(DECIMALS_SHARE_REWARD);
        emit EmitDeposit(msg.sender, _pid, _amount, lockedFor);
    }

    /**
     * @notice Withdraw token _amount from pool _pid
     * Membership is not required, i.e., user can always withdraw their token regardless of membership mechanism.
     * Validates given pool id _pid.
     * nonReentrant protected.
     */
    function withdraw(uint256 _pid, uint256 _amount) external validatePool(_pid) nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: Hm I am not sure you have that amount staked here.");
        // check locked timer
        require(timeToUnlock(_pid, msg.sender) == 0, "withdraw: tokens are still locked.");
        _updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accBitsPerShare).div(DECIMALS_SHARE_REWARD).sub(user.rewardDebt);
        if(pending > 0) {
            safeBitTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            // reduce amount before transferring
            user.amount = user.amount.sub(_amount);
            uint256 amount_fee = 0;
            if (pool.withdrawFeeBP > 0 && !IsExcludedFromFees[msg.sender]) {
                amount_fee = _amount.mul(pool.withdrawFeeBP).div(MAX_PERCENT);
                uint256 burn_fee = amount_fee.mul(pool.burnWithdrawFeeBP).div(pool.withdrawFeeBP);
                handleFee(_pid, amount_fee, burn_fee);
            }
            // transfer token minues penalty fee
            pool.stakeToken.safeTransfer(address(msg.sender), _amount.sub(amount_fee));
        }
        // update reward debts
        user.rewardDebt = user.amount.mul(pool.accBitsPerShare).div(DECIMALS_SHARE_REWARD);
        emit EmitWithdraw(msg.sender, _pid, _amount);
    }

    /**
     * @notice Withdraw without caring about rewards. EMERGENCY ONLY.
     * Locked timer needs to be 0.
     * Simplified fee processing (fee deducted and sent to treasury). No affiliate processing for simplicity.
     * Validates given pool id _pid.
     * nonReentrant protected.
     */
    function emergencyWithdraw(uint256 _pid) public validatePool(_pid) nonReentrant {
        require(timeToUnlock(_pid, msg.sender) == 0, "withdraw: tokens are still locked.");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        uint256 amount_fee = 0;
        if (_amount != 0) {
            if (pool.withdrawFeeBP > 0 && !IsExcludedFromFees[msg.sender]) {
                amount_fee = _amount.mul(pool.withdrawFeeBP).div(MAX_PERCENT);
                // fee is deducted but simplified processed due to complexity of called function handleFee
                // uint256 burn_fee = amount_fee.mul(pool.burnWithdrawFeeBP).div(pool.withdrawFeeBP);
                // handleFee(_pid, amount_fee, burn_fee);
                pool.stakeToken.safeTransfer(treasuryaddr, amount_fee);
            }
            // transfer token minues penalty fee
            pool.stakeToken.safeTransfer(address(msg.sender), _amount.sub(amount_fee));
        }
        // emit event
        emit EmitEmergencyWithdraw(msg.sender, _pid, _amount);
    }

    /// SECTION HELPERS

    /**
     * @notice Safe bit transfer function, just in case if rounding error causes pool to not have enough bits.
     */
    function safeBitTransfer(address _to, uint256 _amount) internal {
        ram.safeBitTransfer(_to, _amount);
    }

    /**
     * @notice Update treasury address by the previous tresaruy address.
     * Can only be called by current treasury address. 
     */
    function tres(address _treasuryaddr) public {
        require(msg.sender == treasuryaddr, "treasury: wut?");
        require(_treasuryaddr != address(0), "treasury: 0x0 address is not the best idea here");
        treasuryaddr = _treasuryaddr;
        emit EmitTreasuryChanged(_treasuryaddr);
    }

    /// SECTION ADMIN 

    /**
     * @notice Set start block any time after deployment.
     * Can only be called once if startBlock == 0.
     * onlyOwner protected.
     */
    function setStartblock(uint256 _block) public onlyOwner {
        require(
            _block >= block.number,
            "set startblock: can not start in past"
        );
        require(
            startBlock == 0,
            "set startblock: start block already set"
        );
        for (uint256 pid = 0; pid < poolInfo.length; pid++) {
            PoolInfo storage pool = poolInfo[pid];
            pool.lastRewardBlock = _block;
        }
        startBlock = _block;
        emit SetStartblock(_block);
    }
    
    /**
     * @notice Pause minting.
     * Optional: all pools are updated before changing pause state.
     * onlyOwner protected.
     */
    function setPaused(bool _paused, bool _withUpdate) external onlyOwner {
        // only in case of emergency.
        if (_withUpdate) {
            // update all pools before activation/deactivation
            _massUpdatePools();
        }
        paused = _paused;  
        emit SetPaused(_paused);
    }

    /**
     * @notice Whitelist addresse -> Makes _address a member. Useful for partner contracts.
     * onlyOwner protected.
     */
    function whiteListAddress(address _address) external onlyOwner {
        // whitelist addresses as members, such as partner contracts    
        // cannot be undone as this might mess up the partners' contracts     
        isWhiteListed[_address] = true;  
        emit WhiteListed(_address);   
    }

    /**
     * @notice Exclude address from fee -> Useful for partner contracts that cannot handle fees.
     * onlyOwner protected.
     */
    function excludeFromFees(address _address) external onlyOwner {
        // whitelist addresses as non-fee-payers, such as partner contracts  
        // cannot be undone as this might mess up the partners' contracts      
        IsExcludedFromFees[_address] = true; 
        emit ExcludedFromFees(_address);  
    }
}
