// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract TokenVesting is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    event NewVest(address indexed _from, address indexed _to, uint256 _value);
    event UnlockVest(address indexed _holder, uint256 _value);
    event RevokeVest(address indexed _holder, uint256 _refund);

    struct Vest {
        uint256 value;
        uint256 transferred;
        bool revokable;
        bool revoked;
    }

    address public crowdsaleAddress;
    ERC20 public token;
    uint256 public totalVesting;
    uint256 public totalLimit;
    uint256 public RELEASES = 3;
    uint256 duration = 30 days; 
    uint256 finishOfVest = RELEASES * duration;
    mapping(address => Vest) public vests;
    uint256 public start;
    uint256 public finish;

    modifier onlyCrowdsale() {
        require(_msgSender() == crowdsaleAddress, "TokenVesting: Only crowdsale can call this function.");
        _;
    }

    constructor(address _token) {
        require(
            _token != address(0),
            "TokenVesting: invalid zero address for token provided"
        );

        token = ERC20(_token);
        // presale limit
        totalLimit = 1e6 * (10**token.decimals());
    }

    /**
     * @notice Set crowdsale address.
     * onlyOwner protected.
     */
    function setCrowdsaleAddress(address _crowdsaleAddress) public onlyOwner {
        require(
            _crowdsaleAddress != address(0),
            "TokenVesting: invalid zero address for crowdsale"
        );
        crowdsaleAddress = _crowdsaleAddress;
    }

    /**
     * @notice Add a new purchased _value of tokens.
     * onlyCrowdsale protected.
     */
    function vest(
        address _to,
        uint256 _value,
        bool _revokable
    ) external onlyCrowdsale {
        require(
            _to != address(0),
            "TokenVesting: invalid zero address for beneficiary!"
        );
        require(_value > 0, "TokensVesting: invalid value for beneficiary!");
        require(
            totalVesting.add(_value) <= totalLimit,
            "TokenVesting: total value exeeds total limit!"
        );
        require(
            !vests[_to].revoked,
            "TokenVesting: Revoked addresses cannot take part"
        );
        

        
        if (vests[_to].value == 0) {
            vests[_to].revokable = _revokable;
            vests[_to].revoked = false;
        }
        vests[_to].value += _value;

        totalVesting = totalVesting.add(_value);

        emit NewVest(_msgSender(), _to, _value);
    }

    /**
     * @notice Revoke added vest.
     * Not possible for vests added by crowdsale.
     * onlyOwner protected.
     */
    function revoke(address _holder) public onlyOwner {
        Vest storage vested = vests[_holder];

        require(vested.revokable, "TokenVesting: vested can not get revoked!");
        require(!vested.revoked, "TokenVesting: holder already revoked!");

        uint256 refund = vested.value.sub(vested.transferred);

        totalVesting = totalVesting.sub(refund);
        vested.revoked = true;
        vested.value = 0;
        token.safeTransfer(_msgSender(), refund);

        emit RevokeVest(_holder, refund);
    }

    /**
     * @notice Start vesting period.
     * Only crowdsale. Will be called once the sale is completed.
     * onlyCrowdsale protected.
     */
    function startVesting(uint256 _start) public onlyCrowdsale {
        require(finish == 0, "TokenVesting: already started!");
        start = _start;
        finish = _start.add(finishOfVest);
    }

    /**
     * @notice Calculate amount of already vested tokens.
     * Can also return the amount of unlocked vested tokens.
     * For external use only.
     */
    function vestedTokens(address _holder, bool unlocked)
        external
        view
        returns (uint256)
    {
        if (start == 0) {
            return 0;
        }

        Vest memory vested = vests[_holder];
        if (vested.value == 0) {
            return 0;
        }
        uint256 vestedAmount = calculateVestedTokens(vested);
        uint256 transferable = vestedAmount.sub(vested.transferred);
        if (unlocked)
            return transferable;

        return vestedAmount;
    }

    /**
     * @notice Calculate amount of already vested tokens.
     * Return full _vested.value if vesting period is finished.
     * For internal use only.
     */
    function calculateVestedTokens(Vest memory _vested)
        private
        view
        returns (uint256)
    {
        if (block.timestamp >= finish) {
            return _vested.value;
        }

        if (start > block.timestamp)
            return 0;
        // 40% are initially unlocked right away
        uint256 initalUnlock = 2;
        uint256 timePassedAfterStart = block.timestamp.sub(start);
        // Consider initial unlock
        uint256 availableReleases = timePassedAfterStart.div(duration) + initalUnlock;
        // RELEASES = 3 -> 5 releases in total
        uint256 tokensPerRelease = _vested.value.div(RELEASES + initalUnlock);

        return availableReleases.mul(tokensPerRelease);
    }

    /**
     * @notice Countdown to be displayed on frontend. 
     * Returns next vesting timestamp if nothing is transferrable, else 0 (transferrable amount is unlocked).
     */
    function countdown(address _holder) external view returns (uint256){
        if (block.timestamp >= finish) {
            return 0;
        }
        Vest storage vested = vests[_holder];
        // check vested amount, if greater 0, vesting is still unlocked
        uint256 vestedAmount = calculateVestedTokens(vested);
        uint256 transferable = vestedAmount.sub(vested.transferred);
        if (transferable > 0) {
            return 0;
        }
        // compute available releases and passed time
        uint256 timePassedAfterStart = block.timestamp.sub(start);
        uint256 availableReleases = timePassedAfterStart.div(duration);
        // return unlock timestamp in unix time
        return start.add(duration.mul(availableReleases + 1));
    }

    /**
     * @notice Claim vested tokens. 
     * Returns if nothing to vest or nothing is unlocked. 
     * nonReentrant protected.
     */
    function unlockVestedTokens() external nonReentrant {
        require(start != 0, "vesting: not started yet");
        Vest storage vested = vests[_msgSender()];
        require(vested.value != 0, "vesting: no tokens to vest");
        require(!vested.revoked, "vesting: revoked");

        uint256 vestedAmount = calculateVestedTokens(vested);
        if (vestedAmount == 0) {
            return;
        }

        uint256 transferable = vestedAmount.sub(vested.transferred);
        if (transferable == 0) {
            return;
        }

        vested.transferred = vested.transferred.add(transferable);
        totalVesting = totalVesting.sub(transferable);
        token.safeTransfer(_msgSender(), transferable);

        emit UnlockVest(_msgSender(), transferable);
    }
}