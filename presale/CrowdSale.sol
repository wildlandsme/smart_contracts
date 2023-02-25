// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./TokenVesting.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Crowdsale is Context, Ownable, ReentrancyGuard {
    using Address for address;
    using SafeERC20 for ERC20;

    // tokens and contracts
    ERC20 public immutable token;
    IERC721 public immutable memberCard;
    TokenVesting public immutable vestingContract;

    // sale addresses
    address payable public treasury_1;
    address payable public treasury_2;
        
    // rates
    uint256 public constant tokenAmountRateOne = 1667; // per ETH // 40% off -> 66% more tokens
    uint256 public constant tokenAmountRateTwo = 1250;  // per ETH // 20% off -> 25% more tokens
    uint256 public constant tokenAmountRateThree = 1000;  // per ETH 
    uint256 public tokensRaised;

    // limits
    uint256 public limitPhaseOne; 
    uint256 public limitPhaseTwo; 
    uint256 public limitPhaseThree;

    uint256 public constant minimumBuyAmount = 1 * 1e16; // 0.01 ETH
    bool public isIcoCompleted = false;
    bool public hasIcoPaused = false;

    // round handlers (there are three presale rounds): for member card holders, for whitelisted addresses and public
    bool public isIcoFirstRoundCompleted = false;
    bool public isIcoSecondRoundCompleted = false;
    uint256 public startCrowdsaleTime;
    uint256 public startSecondRoundTime;
    uint256 public startThirdRoundTime;
    uint256 public whiteListSpots = 100;
    bool public extendedRoundOne = false;
    bool public extendedRoundTwo = false;

    // whitelisted addressed
    mapping(address => bool) public whiteListed;

    event TokenBuy(address indexed buyer, uint256 value, uint256 amount);
    event Whitelist(address indexed whitelisted);
    event WhitelistMultiple(address[] addresses, bool value);
    event Close();
    event SetTime(string indexed round, uint256 timestamp);
    event TreasuryChanged(address treasury1, address treasury2);
    event Paused(bool paused);
    event ExtendFirstRound(bool extended);
    event ExtendSecondRound(bool extended);

    modifier whenIcoCompleted() {
        require(
            isIcoCompleted,
            "Crowdsale: crowdsale not completed");
        _;
    }

    modifier onlyAfterStart() {
        uint256 _startTime = startCrowdsaleTime;
        require(
            block.timestamp >= _startTime && _startTime != 0,
            "Crowdsale: crowdsale not started yet"
        );
        _;
    }

    modifier onlyWhenNotPaused() {
        require(
            !hasIcoPaused, 
            "Crowdsale: crowdsale has paused");
        _;
    }

    modifier onlyWhenNotCompleted() {
        require(
            !isIcoCompleted, 
            "Crowdsale: crowdsale has completed");
        _;
    }

    /**
     * @param _token erc20 token address
     * @param _treasury_1 first treasury address
     * @param _treasury_2 second treasury address
     * @param _memberCard erc721 member card
     * @param _vestingContract address of vesting contract
     */
    constructor(
        address _token,
        address payable _treasury_1,
        address payable _treasury_2,
        address _memberCard,
        address _vestingContract
    ) {
        require(
            _token != address(0),
            "Crowdsale: invalid zero address for token provided"
        );
        require(
            _vestingContract != address(0),
            "Crowdsale: invalid zero address for vest provided"
        );
        require(
            _memberCard != address(0),
            "Crowdsale: invalid zero address for member card"
        );
        require(
            _treasury_1 != address(0) && _treasury_2 != address(0),
            "Crowdsale: invalid zero address for treasury addresses"
        );
        // startCrowdsaleTime = block.timestamp;
        vestingContract = TokenVesting(_vestingContract);
        token = ERC20(_token);
        memberCard = IERC721(_memberCard);
        treasury_1 = _treasury_1;
        treasury_2 = _treasury_2;

        uint256 _decimals = ERC20(_token).decimals();
        limitPhaseOne = 75 * 1e3 * (10**_decimals); // + 75k
        limitPhaseTwo = 225 * 1e3 * (10**_decimals); // + 150k (225k)
        limitPhaseThree = 525 * 1e3 * (10**_decimals); // + 300k (525k)
    }

    /**
     * @dev Set white list address.
     * onlyOwner protected.
     * @param _grantees array of grantee addresses
     * @param set are the _grantees to be whitelisted (true) or revoked (false)?
     */
    function setWhitelist(address[] calldata _grantees, bool set) public onlyOwner {
        // add addresses to whitelist
        for (uint i = 0; i < _grantees.length; i++) {
            require(_grantees[i] != address(0), "Crowdsale: Invalid address for grantee");
            whiteListed[_grantees[i]] = set;
        }
        emit WhitelistMultiple(_grantees, set);
    }

    /**
     * @dev Allow users to secure one of the limited whitelist spots.
     * Cannot be called after presale has started.
     */
    function secureWhitelistSpot() external {
        uint256 _spots = whiteListSpots;
        require(
            block.timestamp < startCrowdsaleTime,
            "Crowdsale: crowdsale already started"
        );
        require(_spots > 0, 
            "Crowdsale: no spot left.");
        require(!whiteListed[msg.sender], 
            "Crowdsale: already whitelisted.");
        whiteListSpots = _spots - 1;
        whiteListed[msg.sender] = true;
        emit Whitelist(msg.sender);
    }

    /**
     * @dev Set treasury addresses.
     * onlyOwner protected.
     * @param _treasury_1 first treasury address
     * @param _treasury_2 second treasury address
     */
    function setTreasury(address payable _treasury_1, address payable _treasury_2) public onlyOwner {
        require (_treasury_1 != address(0), "Crowdsale: invalid address 1");
        require (_treasury_2 != address(0), "Crowdsale: invalid address 2");
        treasury_1 = _treasury_1;
        treasury_2 = _treasury_2;
        emit TreasuryChanged(treasury_1, treasury_2);
    }
    /**
     * @dev Set white list address.
     * nonReentrant protected.
     * onlyAfterStart protected.
     * onlyWhenNotPaused protected.
     * onlyWhenNotCompleted protected.
     */
    function buyNative() public payable nonReentrant onlyAfterStart onlyWhenNotPaused onlyWhenNotCompleted {
        require(
            tokensRaised < limitPhaseThree,
            "Crowdsale: reached the maximum amount"
        );
        // set user transferred value
        uint256 _amount = msg.value;
        // tokens to buy
        uint256 tokensToBuy = 0;
        uint256 _limitOne = limitPhaseOne;
        uint256 _limitTwo = limitPhaseTwo;
        uint256 _limitThree = limitPhaseThree;
        uint256 _raised = tokensRaised;
        uint256 _2ndRoundTime = startSecondRoundTime;
        uint256 _3rdRoundTime = startThirdRoundTime;

        if (_raised < _limitOne) {
            tokensToBuy = _getTokensAmount(_amount, tokenAmountRateOne);
            // round 1 is only for whitelisted addresses or for wmc card holders if extended
            require(
                whiteListed[_msgSender()] || (extendedRoundOne && memberCard.balanceOf(_msgSender()) > 0) || extendedRoundTwo, 
                "Crowdsale: Sender not whitelisted."
            );
            require(
                (_amount >= minimumBuyAmount) ||
                    // safety case to allow for lower purchase if limit is reached
                    (tokensToBuy >= (_limitOne - _raised)),
                "Crowdsale: minimum eth amount not sent."
            );
            if (_raised + tokensToBuy > _limitOne) {
                // adjust tokensToBuy
                tokensToBuy = _limitOne - _raised;
                // set actual cost based on available tokens
                _amount = _getETHAmount(tokensToBuy, tokenAmountRateOne);
            }
        } else if (_raised < _limitTwo && isIcoFirstRoundCompleted) {
            require(
                _2ndRoundTime > 0 && block.timestamp >= _2ndRoundTime,
                "Crowdsale: second round not started!"
            );
            // only for wmc card holders or public if extended
            require(
                memberCard.balanceOf(_msgSender()) > 0  || extendedRoundTwo, 
                "Crowdsale: only for member card holders."
            );
            tokensToBuy = _getTokensAmount(_amount, tokenAmountRateTwo);
            require(
                (_amount >= minimumBuyAmount) ||
                    (tokensToBuy >= (_limitTwo - _raised)),
                "Crowdsale: minimum eth amount not sent."
            );
            if (_raised + tokensToBuy > _limitTwo) {
                // adjust tokensToBuy
                tokensToBuy = _limitTwo - _raised;
                // set actual cost based on available tokens
                _amount = _getETHAmount(tokensToBuy, tokenAmountRateTwo);
            }
        } else if (_raised < _limitThree && isIcoSecondRoundCompleted) {
            require(
                _3rdRoundTime > 0 && block.timestamp >= _3rdRoundTime,
                "Crowdsale: third round not started!"
            );
            // public presale
            tokensToBuy = _getTokensAmount(_amount, tokenAmountRateThree);
            require(
                (_amount >= minimumBuyAmount) ||
                    (tokensToBuy >= (_limitThree - _raised)),
                "Crowdsale: minimum eth amount not sent."
            );
            if (_raised + tokensToBuy > _limitThree) {
                // adjust tokensToBuy
                tokensToBuy = _limitThree - _raised;
                // set actual cost based on available tokens
                _amount = _getETHAmount(tokensToBuy, tokenAmountRateThree);
            }
        }

        require(
            tokensToBuy > 0,
            "Crowdsale: insufficient output balance."
        );

        token.safeTransfer(address(vestingContract), tokensToBuy);
        // transfer funds to treasury addresses
        uint256 split_1 = _amount / 2;
        treasury_1.transfer(split_1);
        treasury_2.transfer(_amount - split_1);
        if (_amount < msg.value){
            // refund the rest back to sender if _amount < msg.value
            payable(_msgSender()).transfer(msg.value - _amount);
        }
        // non-revokable vest
        vestingContract.vest(_msgSender(), tokensToBuy);
        // check limits for round 1 and 2
        if (_raised + tokensToBuy >= _limitOne) {
            isIcoFirstRoundCompleted = true;
        }
        if (_raised + tokensToBuy >= _limitTwo) {
            isIcoSecondRoundCompleted = true;
        }
        // set raised token amount
        tokensRaised = _raised + tokensToBuy;
        emit TokenBuy(_msgSender(), _amount, tokensToBuy);
    }

    /**
     * @dev Get ETH amount given a _tokenAmount and the respective _tokenAmountRate per ETH.
     * @param _tokenAmount amount of tokens to be purchased
     * @param _tokenAmountRate amount of tokens per eth
     * @return eth cost
     */
    function _getETHAmount(uint256 _tokenAmount, uint256 _tokenAmountRate)
        internal
        pure
        returns (uint256)
    {
        // tokens -> rate * amount -> amount = tokens/rate
        return _tokenAmount / _tokenAmountRate;
    }

    /**
     * @dev Get token amount given a _value and the respective _tokenAmountRate per ETH.
     * @param _value eth value usable for purchase
     * @param _tokenAmountRate amount of tokens per eth
     * @return amount of tokens to be purchased
     */
    function _getTokensAmount(uint256 _value, uint256 _tokenAmountRate)
        internal
        pure
        returns (uint256)
    {
        // tokens -> rate * _value
        return _value * _tokenAmountRate;
    }

    /**
     * @dev Close crowdsale.
     * onlyOwner protected.
     */
    function closeCrowdsale() public onlyOwner {
        isIcoCompleted = true;
        vestingContract.startVesting(block.timestamp);
        emit Close();
    }

    /**
     * @dev Pause crowdsale.
     * onlyOwner protected.
     */
    function togglePauseCrowdsale() public onlyOwner {
        hasIcoPaused = !hasIcoPaused;
        emit Paused(hasIcoPaused);
    }

    /**
     * @dev Start crowdsale.
     * onlyOwner protected.
     * @param _time unix time stamp
     */
    function startCrowdSale(uint256 _time) public onlyOwner{
        require(startCrowdsaleTime == 0, "Crowdsale: already set");
        require(
            _time >= block.timestamp,
            "Crowdsale: can not start in past"
        );
        startCrowdsaleTime = _time;
        emit SetTime("1st", _time);
    }

    /**
     * @dev Start 2nd round.
     * onlyOwner protected.
     * @param _time unix time stamp
     */
    function startSecondRound(uint256 _time) public onlyOwner {
        require(startSecondRoundTime == 0, "Crowdsale: already set");
        require(
            _time >= block.timestamp,
            "Crowdsale: can not start in past"
        );
        startSecondRoundTime = _time;
        emit SetTime("2nd", _time);
    }

   /**
     * @dev Start 3rd round.
     * onlyOwner protected.
     * @param _time unix time stamp
     */
    function startThirdRound(uint256 _time) public onlyOwner {
        require(startThirdRoundTime == 0, "Crowdsale: already set");
        require(
            _time >= block.timestamp,
            "Crowdsale: can not start in past"
        );
        startThirdRoundTime = _time;
        emit SetTime("3rd", _time);
    }

   /**
     * @dev Extend 1st round.
     * onlyOwner protected.
     * @param _extended is the 1st round to be extended for wmc card holder?
     */
    function extendRoundOne(bool _extended) public onlyOwner {
        extendedRoundOne = _extended;
        emit ExtendFirstRound(_extended);
    }

   /**
     * @dev Extend 2nd round.
     * onlyOwner protected.
     * @param _extended is the 2nd round to be extended for public?
     */
    function extendRoundTwo(bool _extended) public onlyOwner {
        extendedRoundTwo = _extended;
        emit ExtendSecondRound(_extended);
    }

    /**
     * @dev Has 2nd round of presale started?
     * @return true if 2nd round has started, else false
     */
    function has2ndRoundStarted() external view returns (bool) {
        return block.timestamp >= startSecondRoundTime && startSecondRoundTime > 0;
    }

    /**
     * @dev Has 3rd round of presale started?
     * @return true if 3rd round has started, else false
     */
    function has3rdRoundStarted() external view returns (bool) {
        return block.timestamp >= startThirdRoundTime && startThirdRoundTime > 0;
    }

   /**
     * @dev Deposit amount of token into the presale contract.
     * onlyOwner protected.
     * @param _amount amount of tokens to be deposited
     */
    function deposit(uint256 _amount) public onlyOwner {
        token.safeTransferFrom(_msgSender(), address(this), _amount);
    }

   /**
     * @dev Transfer remaining tokens if presale is closed earlier.
     * onlyOwner protected.
     */
    function withdraw() public whenIcoCompleted onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(_msgSender(), balance);
    }
   /**
     * @dev Withdraw any eth left in contract.
     * onlyOwner protected.
     */
    function withdrawETH() public whenIcoCompleted onlyOwner {
        (bool success, ) = payable(owner()).call{value: address(this).balance}(
            ""
        );
        require(success);
    }
}