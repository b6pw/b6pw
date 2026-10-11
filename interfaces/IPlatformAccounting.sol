pragma solidity 0.8.24;

import {NG} from "./NextGenTypes.sol";
import {IGenerationIdentity} from "./IGenerationIdentity.sol";

interface IPlatformAccounting is IGenerationIdentity {
    function specialStakeOf(address originPlatform) external view returns (NG.SpecialStake memory);
    function registrar() external view returns (address);
    function batchNonce(address registrar_) external view returns (uint256);
    function currentCustody() external view returns (address);
    function registrarCodeHash() external view returns (bytes32);
    function currentCustodyCodeHash() external view returns (bytes32);
    function custodyVersion() external view returns (uint256);
    function platformAuthorizationEpoch() external view returns (uint256);
    function pendingCustody() external view
        returns (bytes32 proposalId, uint256 expectedVersion, uint256 proposerWalletEpoch);
    function setRegistrar(address proposed, uint256 expectedWalletEpoch) external;
    function stakeSpecial(uint256 maxAmount) external;
    function topUpSpecial(uint256 maxAdditionalAmount) external;
    function unstakeSpecial(address to) external;
    function assertOriginActive(
        bytes32 idHash_, address expectedOwner, uint256 expectedNonce, uint256 expectedInstanceId,
        uint256 expectedGeneration
    ) external view;
    function detachOrigin(
        bytes32 idHash_, address expectedOwner, uint256 expectedNonce, uint256 expectedInstanceId,
        uint256 expectedGeneration
    ) external;
    function syncOriginNonce(
        bytes32 idHash_, address expectedOwner, uint256 expectedNonce, uint256 nextNonce,
        uint256 expectedInstanceId, uint256 expectedGeneration
    ) external;
    function batchCreate(NG.BatchRequest calldata request, bytes calldata registrarSignature) external;
    function proposeCustody(NG.CustodyProposal calldata proposed) external returns (bytes32 proposalId);
    function cancelCustodyProposal(bytes32 proposalId) external;
    function activateCustody(bytes32 proposalId, uint256 expectedVersion) external;
}
