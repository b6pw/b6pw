pragma solidity 0.8.24;

import {NG} from "./NextGenTypes.sol";
import {IGenerationIdentity} from "./IGenerationIdentity.sol";

interface IOwnershipCore is IGenerationIdentity {
    function normalizeId(string calldata id) external pure returns (string memory);
    function idHash(string calldata id) external pure returns (bytes32);
    function isAvailable(string calldata id) external view returns (bool);
    function getRecord(bytes32 idHash_) external view returns (NG.Record memory);
    function ownerOf(bytes32 idHash_) external view returns (address);
    function ownershipNonceOf(bytes32 idHash_) external view returns (uint256);
    function setDescription(string calldata id, string calldata description) external;
    function setResolution(string calldata id, string calldata resolution) external;
    function createOrdinary(string calldata id, address owner, string calldata description,
        string calldata resolution) external returns (bytes32 idHash_, uint256 nonce);
    function createPlatform(string calldata id, address custody, address originPlatform,
        uint256 createdGeneration) external returns (bytes32 idHash_, uint256 nonce, uint256 instanceId);
    function markListed(bytes32 idHash_, address expectedOwner, uint256 expectedNonce)
        external returns (uint256 listingNonce);
    function cancelListed(bytes32 idHash_, address expectedOwner, uint256 expectedNonce)
        external returns (uint256 nextNonce);
    function settleToFreeLock(bytes32 idHash_, address expectedOwner, uint256 expectedNonce,
        address receiver, uint64 lockDuration) external returns (uint256 nextNonce);
    function completeFreeLock(bytes32 idHash_, address expectedOwner, uint256 expectedNonce)
        external returns (uint256 nextNonce);
    function releaseOrdinary(bytes32 idHash_, address expectedOwner, uint256 expectedNonce)
        external returns (uint256 nextNonce);
    function releaseExpired(string calldata id) external;
}
