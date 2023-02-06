// SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.1;


import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./TokenVesting.sol";
import "./WildlandCards.sol";


contract MigrationAdmin is Ownable {

    TokenVesting public vestingContract;
    WildlandsMemberCards public wildlandContract;

    constructor(address _vestingContract, WildlandsMemberCards _wildlandContract) {
        setVestingContract(_vestingContract);
        setWildlandContract(_wildlandContract);
    }

    function setVestingContract(address _vestingContract) public onlyOwner {
        vestingContract = TokenVesting(_vestingContract);
    }

    
    function setWildlandContract(WildlandsMemberCards _wildlandContract) public onlyOwner {
        wildlandContract = _wildlandContract;
    }

    function setRTG(address[] calldata _recipients, uint256[] calldata _amount) public onlyOwner {
        require(_recipients.length == _amount.length);
        // grad vesting for rtg holders
        for (uint i = 0; i < _recipients.length; i++) {
            require(_recipients[i] != address(0));
            vestingContract.vest(_recipients[i], _amount[i], false);
        }
    }

    function mintCards(address[] calldata _recipients, uint256[] calldata _ids) public onlyOwner {
        require(_recipients.length == _ids.length);
        // grad vesting for rtg holders
        for (uint i = 0; i < _recipients.length; i++) {
            require(_recipients[i] != address(0));
            wildlandContract.mint(_recipients[i], _ids[i]);
        }
    }
}