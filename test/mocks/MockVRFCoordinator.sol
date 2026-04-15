// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title MockVRFCoordinatorV2Plus (Foundry)
 * @notice Mock del VRF Coordinator per test Foundry.
 *         Supporta sia SatoshiBestiary (VRFConsumerBaseV2Plus) che SatoshiForge (IVRFCoordinatorV2Plus).
 */
interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

contract MockVRFCoordinatorV2Plus {
    uint256 private _nextRequestId = 1;
    mapping(uint256 => address) public requestConsumer;
    mapping(uint256 => uint32) public requestNumWords;

    // Simula il blocco del requestRandomWords (per test DoS)
    bool public shouldFail;
    // Simula ritardo — non fulfilla automaticamente
    bool public delayFulfillment;

    function requestRandomWords(
        VRFV2PlusClient.RandomWordsRequest calldata req
    ) external returns (uint256 requestId) {
        require(!shouldFail, "MockVRF: forced failure");
        requestId = _nextRequestId++;
        requestConsumer[requestId] = msg.sender;
        requestNumWords[requestId] = req.numWords;
    }

    /// @dev Fulfilla manualmente una richiesta con randomWords specifici
    function fulfillManual(
        uint256 requestId,
        address consumer,
        uint256[] calldata randomWords
    ) external {
        IVRFConsumer(consumer).rawFulfillRandomWords(requestId, randomWords);
    }

    /// @dev Fulfilla con numeri pseudorandom generati da un seed
    function fulfillWithSeed(
        uint256 requestId,
        address consumer,
        uint256 seed
    ) external {
        uint32 numWords = requestNumWords[requestId];
        uint256[] memory words = new uint256[](numWords);
        for (uint32 i = 0; i < numWords; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(seed, i)));
        }
        // Convert memory to calldata-compatible call
        IVRFConsumer(consumer).rawFulfillRandomWords(requestId, words);
    }

    function setShouldFail(bool _fail) external {
        shouldFail = _fail;
    }

    function nextRequestId() external view returns (uint256) {
        return _nextRequestId;
    }
}
