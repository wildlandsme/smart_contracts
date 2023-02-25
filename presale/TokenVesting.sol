// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract TokenVesting is Ownable, ReentrancyGuard {
    using SafeERC20 for ERC20;

    event NewVest(address indexed _from, address indexed _to, uint256 _value);
    event UnlockVest(address indexed _holder, uint256 _value);
    event RevokeVest(address indexed _holder, uint256 _refund);

    struct Vest {
        uint256 value;
        uint256 transferred;
    }

    address public crowdsaleAddress;
    ERC20 public immutable token;
    uint256 public totalVesting;
    uint256 public immutable totalLimit;
    uint256 public constant RELEASES = 3;
    uint256 public constant duration = 30 days; 
    uint256 public constant finishOfVest  = RELEASES * duration;
    mapping(address => Vest) public vests;
    uint256 public start;
    uint256 public finish;
    event SetCrowdsale(address crowsale);

    modifier onlyCrowdsale() {
        require(_msgSender() == crowdsaleAddress, "TokenVesting: Only crowdsale can call this function.");
        _;
    }

    /**
     * @param _token erc20 token address
     */
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
     * @dev Set crowdsale address.
     * onlyOwner protected.
     * @param _crowdsaleAddress address of crowdsale contract
     */
    function setCrowdsaleAddress(address _crowdsaleAddress) public onlyOwner {
        require(
            _crowdsaleAddress != address(0),
            "TokenVesting: invalid zero address for crowdsale"
        );
        require(
            crowdsaleAddress == address(0),
            "TokenVesting: crowdsale already set"
        );
        crowdsaleAddress = _crowdsaleAddress;
        emit SetCrowdsale(_crowdsaleAddress);
    }

    /**
     * @dev Add a new purchased _value of tokens.
     * onlyCrowdsale protected.
     * @param _to vesting address
     * @param _value amount to be vested
     */
    function vest(
        address _to,
        uint256 _value
    ) external onlyCrowdsale {
        //require(
        //    _to != address(0),
        //    "TokenVesting: invalid zero address for beneficiary!"
        //);
        //require(_value > 0, "TokensVesting: invalid value for beneficiary!");
        require(
            totalVesting +_value <= totalLimit,
            "TokenVesting: total value exceeds total limit!"
        );
        
        vests[_to].value += _value;

        totalVesting = totalVesting + _value;

        emit NewVest(_msgSender(), _to, _value);
    }

    /**
     * @dev Start vesting period.
     * Only crowdsale. Will be called once the sale is completed.
     * onlyCrowdsale protected.
     * @param _start start time of vesting
     */
    function startVesting(uint256 _start) public onlyCrowdsale {
        require(finish == 0, "TokenVesting: already started!");
        start = _start;
        finish = _start + finishOfVest;
    }

    /**
     * @dev Calculate amount of already vested tokens.
     * Can also return the amount of unlocked vested tokens.
     * For external use only.
     * @param _holder user address
     * @param _unlocked full vested amount or only the unlocked amount?
     * @return total amount of vested tokens including (unlocked == false) or excluding (unlocked == true) claimed ones 
     */
    function vestedTokens(address _holder, bool _unlocked)
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
        if (_unlocked)
            return vestedAmount - vested.transferred;

        return vestedAmount;
    }

    /**
     * @dev Calculate amount of already vested tokens.
     * Return full _vested.value if vesting period is finished.
     * For internal use only.
     * @param _vested data struct containing vesting information
     * @return total amount of vested tokens including claimed ones
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
        uint256 initialUnlock = 2;
        uint256 timePassedAfterStart = block.timestamp - start;
        // Consider initial unlock (availableReleases <= 5)
        uint256 availableReleases = timePassedAfterStart / duration + initialUnlock;
        // RELEASES = 3 -> 5 releases in total
        return availableReleases * _vested.value / (RELEASES + initialUnlock);
    }

    /**
     * @dev Countdown to be displayed on frontend. 
     * Returns next vesting timestamp if nothing is transferrable, else 0 (transferrable amount is unlocked).
     * @param _holder user address
     * @return 0 if unlocked, else timestamp when unlocked
     */
    function countdown(address _holder) external view returns (uint256){
        if (block.timestamp >= finish) {
            return 0;
        }
        Vest storage vested = vests[_holder];
        // check vested amount, if greater 0, vesting is still unlocked
        uint256 vestedAmount = calculateVestedTokens(vested);
        uint256 transferable = vestedAmount - vested.transferred;
        if (transferable > 0) {
            return 0;
        }
        // compute available releases and passed time
        uint256 timePassedAfterStart = block.timestamp - start;
        uint256 availableReleases = timePassedAfterStart / duration;
        // return unlock timestamp in unix time
        return start + (duration * (availableReleases + 1));
    }

    /**
     * @dev Claim vested tokens. 
     * Returns if nothing to vest or nothing is unlocked. 
     * nonReentrant protected.
     */
    function unlockVestedTokens() external nonReentrant {
        require(start != 0, "vesting: not started yet");
        Vest storage vested = vests[_msgSender()];
        require(vested.value != 0, "vesting: no tokens to vest");

        uint256 vestedAmount = calculateVestedTokens(vested);
        if (vestedAmount == 0) {
            return;
        }

        uint256 transferable = vestedAmount - vested.transferred;
        if (transferable == 0) {
            return;
        }

        vested.transferred = vested.transferred + transferable;
        totalVesting = totalVesting - transferable;
        token.safeTransfer(_msgSender(), transferable);

        emit UnlockVest(_msgSender(), transferable);
    }
}