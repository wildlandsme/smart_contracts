// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./TokenVesting.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Crowdsale is Context, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using Address for address;
    using SafeERC20 for ERC20;

    // tokens and contracts
    ERC20 public token;
    IERC721 public memberCard;
    TokenVesting public vestingContract;

    // sale addresses
    address payable public treasury_1;
    address payable public treasury_2;
        
    // rates
    uint256 public tokenAmountRateOne = 1667; // per ETH // 40% off -> 66% more tokens
    uint256 public tokenAmountRateTwo = 1250;  // per ETH // 20% off -> 25% more tokens
    uint256 public tokenAmountRateThree = 1000;  // per ETH 
    uint256 public tokensRaised;

    // limits
    uint256 public limitPhaseOne; 
    uint256 public limitPhaseTwo; 
    uint256 public limitPhaseThree;

    uint256 public minimumBuyAmount = 1 * 1e16; // 0.01 ETH
    bool public isIcoCompleted = false;
    bool public hasIcoPaused = false;

    // round handlers (there are three presale rounds): for member card holders, for whitelisted addresses and public
    bool public isIcoFirstRoundCompleted = false;
    bool public isIcoSecondRoundCompleted = false;
    uint256 public startCrowdsaleTime;
    uint256 public startSecondRoundTime;
    uint256 public startThirdRoundTime;

    uint256 public whiteListSpots = 100;

    // whitelisted addressed
    mapping(address => bool) public whiteListed;

    event TokenBuy(address indexed buyer, uint256 value, uint256 amount);
    event Whitelist(address indexed whitelisted);
    event Close();
    event SetTime(string indexed round, uint256 timestamp);

    modifier whenIcoCompleted() {
        require(
            isIcoCompleted,
            "Crowdsale: crowdsale not completed");
        _;
    }

    modifier onlyAfterStart() {
        require(
            block.timestamp >= startCrowdsaleTime && startCrowdsaleTime != 0,
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

        limitPhaseOne = 75 * 1e3 * (10**token.decimals()); // + 75k
        limitPhaseTwo = 225 * 1e3 * (10**token.decimals()); // + 150k (225k)
        limitPhaseThree = 525 * 1e3 * (10**token.decimals()); // + 300k (525k)
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
    }

    /**
     * @dev Allow users to secure one of the limited whitelist spots.
     * Cannot be called after presale has started.
     */
    function secureWhitelistSpot() external {
        require(
            block.timestamp < startCrowdsaleTime,
            "Crowdsale: crowdsale already started"
        );
        require(whiteListSpots > 0, 
            "Crowdsale: no spot left.");
        require(!whiteListed[msg.sender], 
            "Crowdsale: already whitelisted.");
        whiteListSpots -= 1;
        whiteListed[msg.sender] = true;
        emit Whitelist(msg.sender);
    }

    /**
     * @dev Return available whitelist spots.
     * @return amount of available white list spots
     */
    function getWhitelistSpots() external view returns (uint256) {
        return whiteListSpots;
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

        if (tokensRaised < limitPhaseOne) {
            tokensToBuy = _getTokensAmount(_amount, tokenAmountRateOne);
            // round 1 is only for whitelisted addresses
            require(
                whiteListed[_msgSender()], 
                "Crowdsale: Sender not whitelisted."
            );
            require(
                (_amount >= minimumBuyAmount) ||
                    // safetey case to allow for lower purchase if limit is reached
                    (tokensToBuy >= (limitPhaseOne - tokensRaised)),
                "Crowdsale: minimum eth amount not sent."
            );
            if (tokensRaised + tokensToBuy > limitPhaseOne) {
                // adjust tokensToBuy
                tokensToBuy = limitPhaseOne.sub(tokensRaised);
                // set actual cost based on available tokens
                _amount = _getETHAmount(tokensToBuy, tokenAmountRateOne);
            }
        } else if (tokensRaised >= limitPhaseOne && tokensRaised < limitPhaseTwo && isIcoFirstRoundCompleted) {
            require(
                startSecondRoundTime > 0 && block.timestamp >= startSecondRoundTime,
                "Crowdsale: second round not started!"
            );
            require(
                memberCard.balanceOf(_msgSender()) > 0, 
                "Crowdsale: only for member card holders."
            );
            tokensToBuy = _getTokensAmount(_amount, tokenAmountRateTwo);
            require(
                (_amount >= minimumBuyAmount) ||
                    (tokensToBuy >= (limitPhaseTwo - tokensRaised)),
                "Crowdsale: minimum eth amount not sent."
            );
            if (tokensRaised + tokensToBuy > limitPhaseTwo) {
                // adjust tokensToBuy
                tokensToBuy = limitPhaseTwo.sub(tokensRaised);
                // set actual cost based on available tokens
                _amount = _getETHAmount(tokensToBuy, tokenAmountRateTwo);
            }
        } else if (tokensRaised >= limitPhaseTwo && tokensRaised < limitPhaseThree && isIcoSecondRoundCompleted) {
            require(
                startThirdRoundTime > 0 && block.timestamp >= startThirdRoundTime,
                "Crowdsale: third round not started!"
            );
            // public presale
            tokensToBuy = _getTokensAmount(_amount, tokenAmountRateThree);
            require(
                (_amount >= minimumBuyAmount) ||
                    (tokensToBuy >= (limitPhaseThree - tokensRaised)),
                "Crowdsale: minimum eth amount not sent."
            );
            if (tokensRaised + tokensToBuy > limitPhaseThree) {
                // adjust tokensToBuy
                tokensToBuy = limitPhaseThree.sub(tokensRaised);
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
        uint256 split_1 = _amount.div(2);
        treasury_1.transfer(split_1);
        treasury_2.transfer(_amount.sub(split_1));
        if (_amount < msg.value){
            // refund the rest back to sender if _amount < msg.value
            payable(_msgSender()).transfer(msg.value.sub(_amount));
        }
        // non-revokable vest
        vestingContract.vest(_msgSender(), tokensToBuy, false);
        emit TokenBuy(_msgSender(), _amount, tokensToBuy);
        // set raised token amount
        tokensRaised += tokensToBuy;
        // check limits for round 1 and 2
        if (tokensRaised >= limitPhaseOne) {
            isIcoFirstRoundCompleted = true;
        }
        if (tokensRaised >= limitPhaseTwo) {
            isIcoSecondRoundCompleted = true;
        }
    }

    /**
     * @dev Get ETH amount given a _tokenAmount and the respective _tokenAmountRate per ETH.
     * @param _tokenAmount amont of tokens to be purchased
     * @param _tokenAmountRate amount of tokens per eth
     * @return eth cost
     */
    function _getETHAmount(uint256 _tokenAmount, uint256 _tokenAmountRate)
        internal
        pure
        returns (uint256)
    {
        // tokens -> rate * amount -> amount = tokens/rate
        return _tokenAmount.div(_tokenAmountRate);
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
        return _value.mul(_tokenAmountRate);
    }

    /**
     * @dev Close crowedsale.
     * onlyOwner protected.
     */
    function closeCrowdsale() public onlyOwner {
        isIcoCompleted = true;
        vestingContract.startVesting(block.timestamp);
        emit Close();
    }

    /**
     * @dev Pause crowedsale.
     * onlyOwner protected.
     */
    function togglePauseCrowdsale() public onlyOwner {
        hasIcoPaused = !hasIcoPaused;
    }

    /**
     * @dev Start crowedsale.
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