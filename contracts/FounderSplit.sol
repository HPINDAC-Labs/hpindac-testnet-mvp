// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;
 
import "./interfaces/IHederaTokenService.sol";
import "./libraries/HederaResponseCodes.sol";
 
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}
 
contract FounderSplit {
    address public immutable founderA;
    address public immutable founderB;
    uint16 public immutable founderAShareBps;
    address public immutable stablecoin;
 
    event Distributed(uint256 total, uint256 toFounderA, uint256 toFounderB);
 
    constructor(address _founderA, address _founderB, uint16 _founderAShareBps, address _stablecoin) {
        require(_founderA != address(0) && _founderB != address(0), "FounderSplit: zero address");
        require(_stablecoin != address(0), "FounderSplit: zero stablecoin");
        require(_founderAShareBps <= 10000, "FounderSplit: invalid share");
        founderA = _founderA;
        founderB = _founderB;
        founderAShareBps = _founderAShareBps;
        stablecoin = _stablecoin;
    }
 
    function distribute() external {
        uint256 balance = IERC20Minimal(stablecoin).balanceOf(address(this));
        require(balance > 0, "FounderSplit: nothing to distribute");
 
        uint256 toA = (balance * founderAShareBps) / 10000;
        uint256 toB = balance - toA;
 
        if (toA > 0) _send(founderA, toA);
        if (toB > 0) _send(founderB, toB);
 
        emit Distributed(balance, toA, toB);
    }
 
    function _send(address to, uint256 amount) internal {
        require(amount <= uint256(uint64(type(int64).max)), "FounderSplit: amount overflow");
        int64 result = IHederaTokenService(address(0x167)).transferToken(
            stablecoin, address(this), to, int64(uint64(amount))
        );
        require(result == HederaResponseCodes.SUCCESS, "FounderSplit: transfer failed");
    }
}
