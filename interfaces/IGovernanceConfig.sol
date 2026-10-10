pragma solidity 0.8.24;

import {NG} from "./NextGenTypes.sol";
import {IGenerationIdentity} from "./IGenerationIdentity.sol";

interface IGovernanceConfig is IGenerationIdentity {
    function token() external view returns (address);
    function coreBindings() external view returns (NG.CoreBindings memory);
    function coreSealed() external view returns (bool);
    function policy() external view returns (NG.BusinessPolicy memory);
    function pricingPolicyVersion() external view returns (uint256);
    function economicPolicyVersion() external view returns (uint256);
    function oracleState() external view returns (NG.OracleState memory);
    function spotSourcePolicy(bool useBackup) external view returns (NG.SpotSourcePolicy memory);
    function ethUsdSourcePolicy(bool useBackup) external view returns (NG.EthUsdSourcePolicy memory);
    function sourcePolicyHash() external view returns (bytes32);
    function sourceTrustEpoch() external view returns (uint64);
    /// @dev Returns 1 for valid, 2 for source outage/identity failure, 3 for malformed provenance.
    function validatePriceObservation(NG.OracleObservation calldata observation, bool useBackup)
        external view returns (uint8 status);
    function validateSpotSource(
        bool useBackup, address source, bytes32 sourceCodeHash, uint64 sourceRevision, bytes32 sourceRootId
    )
        external
        view
        returns (NG.PriceQuote memory canonical);
    function validateEthUsdSource(
        bool useBackup, address source, bytes32 sourceCodeHash, uint64 sourceRevision, bytes32 sourceRootId
    )
        external
        view
        returns (NG.PriceQuote memory canonical);
    function moduleState(NG.ModuleKind kind) external view
        returns (address module, bytes32 codeHash, uint256 version);
    function governance() external view returns (address);
    function governanceEpoch() external view returns (uint256);
    function pendingGovernance() external view
        returns (address proposed, uint256 governanceEpoch);
    function platformWallet() external view returns (address);
    function walletEpoch() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function pendingOracle() external view
        returns (bytes32 proposalId, uint256 expectedVersion, uint256 governanceEpoch);
    function pendingModule(NG.ModuleKind kind) external view
        returns (bytes32 proposalId, uint256 expectedVersion, uint256 governanceEpoch);
    function sealCore(NG.CoreBindings calldata bindings) external;
    function setBusinessPolicy(NG.BusinessPolicy calldata proposed, uint256 expectedEconomicVersion,
        uint256 expectedPricingVersion) external;
    function setPlatformWallet(address proposed, uint256 expectedWalletEpoch) external;
    function setFeeRecipient(address proposed) external;
    function proposeGovernance(address proposed) external;
    function cancelGovernanceProposal() external;
    function acceptGovernance() external;
    function proposeOracleWithTrustMode(
        address directory,
        bytes32 directoryCodeHash,
        NG.SourceSet calldata sources,
        uint256 expectedVersion,
        NG.TrustTransition transition,
        bytes32 expectedTrustCommitment,
        bytes32 semanticsHash,
        uint16 evidenceSchemaVersion
    ) external returns (bytes32 proposalId);
    /// @dev Legacy activation path is always interpreted as a trust-semantics change.
    function proposeOracle(address directory, bytes32 directoryCodeHash,
        NG.SourceSet calldata sources, uint256 expectedVersion) external returns (bytes32 proposalId);
    function cancelOracleProposal(bytes32 proposalId) external;
    function activateOracle(bytes32 proposalId, uint256 expectedVersion) external;
    function setSourcePolicies(
        NG.SpotSourcePolicy calldata primarySpot,
        NG.SpotSourcePolicy calldata backupSpot,
        NG.EthUsdSourcePolicy calldata primaryEthUsd,
        NG.EthUsdSourcePolicy calldata backupEthUsd,
        uint256 expectedOracleVersion
    ) external;
    function proposeModule(NG.ModuleKind kind, address module, bytes32 codeHash,
        uint256 expectedVersion) external returns (bytes32 proposalId);
    function cancelModuleProposal(NG.ModuleKind kind, bytes32 proposalId) external;
    function activateModule(NG.ModuleKind kind, bytes32 proposalId, uint256 expectedVersion) external;
}
