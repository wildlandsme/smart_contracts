// SPDX-License-Identifier: MIT
pragma solidity ^0.8.1;

import "./IWildlandCards.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Play2Earn is Ownable {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // Info of each user.
    struct UserInfo {
        bool registered;  
    }
    IERC20 bitGold;  

    mapping(address => string) public addressToUserId;
    // mapping(address => uint256) public addressToTokenId;
    mapping(string => uint256) public userIdToTokenId;
    mapping(address => UserInfo) public userInfo;
    mapping(uint256 => uint256) public prizePool;
    mapping(uint256 => bool) public isTokenRegistered;
    uint256 public totalFactor;
    IWildlandCards public wmc;

    event SetPrize(uint output, uint base);
       /**
     * @notice Constructor
     */
    constructor(
        IWildlandCards _wmc,
        IERC20 _bit
    ) {
        wmc = _wmc;
        bitGold = _bit;
    }

    modifier validateTokenOwner(uint256 _tokenId) {
        require(wmc.ownerOf(_tokenId) == msg.sender, "P2E: not owner of token");
        _;
    }

    modifier validateAmount(uint256 _amount) {
        require(_amount > 100, "P2E: minimal registration requirements not met");
        _;
    }

    function getWMCFactor(uint256 _tokenId) public pure returns (uint256) {
        // check affiliate id
        if (_tokenId == 0)
            return 0;
        else if (_tokenId <= 100) {
            // BIT CARD MEMBER
            return 4; // factor 4
        }
        else if (_tokenId <= 400) {
            // GOLD CARD MEMBER
            return 3; // factor 3
        }
        else if (_tokenId <= 1000) {
            // BLACK CARD MEMBER
            return 2; // factor 2
        }
        // WILD LANDS MEMBER CARD
        return 1; // factor 1
    }

/*
    function register(string memory user_id, uint256 _tokenId, uint256 _amount) external validateTokenOwner(_tokenId) validateAmount(_amount) {
        // register address for token id
        UserInfo storage user = userInfo[msg.sender];
        // addressToTokenId[msg.sender] = _tokenId;
        addressToUserId[msg.sender] = user_id;
        userIdToTokenId[user_id] = _tokenId;
        bitGold.safeTransferFrom(address(msg.sender), address(this), _amount);
        user.amount = user.amount.add(_amount);
        user.registered = true;
        totalRegistered = totalRegistered.add(_amount);
        totalFactor = totalFactor.add(getWMCFactor(_tokenId));
    }
*/

    function register(string memory user_id, uint256 _tokenId) external validateTokenOwner(_tokenId) {
        // register address for token id
        UserInfo storage user = userInfo[msg.sender];
        // addressToTokenId[msg.sender] = _tokenId;
        addressToUserId[msg.sender] = user_id;
        userIdToTokenId[user_id] = _tokenId;
        user.registered = true;
        if (!isTokenRegistered[_tokenId])
            totalFactor = totalFactor.add(getWMCFactor(_tokenId));
        isTokenRegistered[_tokenId] = true;
    }

    function IsValidRegistration(address _address) external view returns (bool) {
        uint256 tokenId = GetRegisteredTokenId(_address);
        return userInfo[_address].registered == true && wmc.ownerOf(tokenId) == _address;
    }

    function GetRegisteredTokenId(address _address) public view returns (uint256) {
        return userIdToTokenId[addressToUserId[_address]];
    }


/*
    function unstake() public {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = user.amount;
        // reset user registration data
        user.amount = 0;
        user.registered = false;
        // reset registered token id
        string memory userId = addressToUserId[msg.sender];
        uint256 tokenId = userIdToTokenId[userId];
        userIdToTokenId[userId] = 0;
        // reduce registered amount and factor
        totalRegistered = totalRegistered.sub(amount);
        totalFactor = totalFactor.sub(getWMCFactor(tokenId));
        bitGold.safeTransfer(address(msg.sender), amount);
    }
*/

    // the prize is directly connected to the wmc cards. W/O being the owner of the respective wmc card
    // the prize cannot be claimed. 
    function claim(uint256 _tokenId) external validateTokenOwner(_tokenId){
        UserInfo storage user = userInfo[msg.sender];
        require(user.registered, "P2E: user not registered");
        // string memory user_id = addressToUserId[msg.sender];
        uint256 prize = prizePool[_tokenId];
        prizePool[_tokenId] = 0;
        // transfer prize to user
        bitGold.safeTransfer(address(msg.sender), prize);
    }



    function setPrize(string[] calldata _user, uint256[] calldata _points, uint256 _total_points, uint256 _total_base_prize) external onlyOwner {
        require(_user.length == _points.length);
        uint256 totalPrizes = 0;
        for (uint i = 0; i < _user.length; i++) {
            uint256 tokenId = userIdToTokenId[_user[i]];
            uint256 factor = getWMCFactor(tokenId);
            // ignore not registered user ids (also unstaked ones)
            if (tokenId != 0) {
                // set price points * 1e18 / totalpoints * factor / 1e18
                uint256 points = _points[i];
                uint256 prize = points.mul(1e18).div(_total_points).mul(_total_base_prize.mul(factor)).div(1e18);
                prizePool[tokenId] = prizePool[tokenId].add(prize);
                totalPrizes = totalPrizes.add(prize);
            }
        }
        // TODO transfer from owner
        // emit sum of total prices
        emit SetPrize(totalPrizes, _total_base_prize);
    }
}