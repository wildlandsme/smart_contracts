// SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.1;


import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

interface Token {
    function transfer(address _to, uint _amount) external returns (bool success);
    function balanceOf(address _owner) external view returns (uint balance);
}


contract ByteDrop is Ownable {
    using SafeMath for uint;

    address public tokenAddr;

    event EtherTransfer(address beneficiary, uint amount);

    constructor(address _tokenAddr) {
        tokenAddr = _tokenAddr;
    }

    function dropTokens(address[] calldata _recipients, uint256[] calldata _amount) public onlyOwner returns (bool) {
        require(_recipients.length == _amount.length);

        for (uint i = 0; i < _recipients.length; i++) {
            require(_recipients[i] != address(0));
            require(Token(tokenAddr).transfer(_recipients[i], _amount[i]));
        }

        return true;
    }

    function dropEther(address payable[] calldata _recipients, uint256[] calldata _amount, bool _emit) public payable onlyOwner returns (bool) {
        uint total = 0;

        for(uint j = 0; j < _amount.length; j++) {
            total = total.add(_amount[j]);
        }

        require(total <= msg.value);
        require(_recipients.length == _amount.length);


        for (uint i = 0; i < _recipients.length; i++) {
            require(_recipients[i] != address(0));

            _recipients[i].transfer(_amount[i]);

            if (_emit)
                emit EtherTransfer(_recipients[i], _amount[i]);
        }

        return true;
    }

    function updateTokenAddress(address newTokenAddr) public onlyOwner {
        tokenAddr = newTokenAddr;
    }

    function withdrawTokens(address beneficiary) public onlyOwner {
        require(Token(tokenAddr).transfer(beneficiary, Token(tokenAddr).balanceOf(address(this))));
    }

    function withdrawEther(address payable beneficiary) public onlyOwner {
        beneficiary.transfer(address(this).balance);
    }
}