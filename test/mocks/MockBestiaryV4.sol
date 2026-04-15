// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title MockBestiaryV4
 * @notice Mock del BestiaryV4 che implementa lockTokens/unlockTokens per test tornei.
 *         Include ERC721 per ownerOf().
 */
contract MockBestiaryV4 is ERC721 {
    uint256 private _nextId = 1;

    /// @dev tokenId → locked (true/false)
    mapping(uint256 => bool) public tokenLocked;

    /// @dev Indirizzo autorizzato a chiamare lock/unlock (= tournament contract)
    address public tournamentContract;

    constructor() ERC721("MockBestiary", "MBST") {}

    function setTournamentContract(address _tc) external {
        tournamentContract = _tc;
    }

    function mintTo(address to) external returns (uint256) {
        uint256 id = _nextId++;
        _mint(to, id);
        return id;
    }

    function mintId(address to, uint256 id) external {
        _mint(to, id);
    }

    function setTokenLock(uint256[] calldata tokenIds, bool locked) external {
        require(msg.sender == tournamentContract, "Not tournament contract");
        for (uint256 i; i < tokenIds.length; i++) {
            tokenLocked[tokenIds[i]] = locked;
        }
    }
}
