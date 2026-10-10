pragma solidity 0.8.24;

import {NG} from "./NextGenTypes.sol";

interface NextGenEvents {
    event CoreSealed(bytes32 indexed generationId, bytes32 bindingsHash);
    event BusinessPolicyChanged(uint256 pricingVersion, uint256 economicVersion, bytes32 policyHash);
    event GovernanceProposed(address indexed current, address indexed pending, uint256 governanceEpoch);
    event GovernanceCancelled(address indexed pending);
    event GovernanceAccepted(address indexed previous, address indexed current, uint256 governanceEpoch);
    event PlatformWalletChanged(address indexed previous, address indexed current, uint256 walletEpoch);
    event FeeRecipientChanged(address indexed previous, address indexed current);
    event OracleProposed(bytes32 indexed proposalId, uint256 expectedVersion, uint256 governanceEpoch, bytes32 bindingHash);
    event OracleCancelled(bytes32 indexed proposalId);
    event OracleActivated(uint256 indexed sourceVersion, address indexed directory, bytes32 sourceSetHash);
    event ModuleProposed(uint8 indexed kind, bytes32 indexed proposalId, uint256 expectedVersion, uint256 governanceEpoch);
    event ModuleCancelled(uint8 indexed kind, bytes32 indexed proposalId);
    event ModuleActivated(uint8 indexed kind, address indexed module, uint256 version, bytes32 codeHash);
    event FreshQuoteAccepted(bytes32 indexed quoteVersion, uint256 requiredStake, uint256 priceUsd18,
        uint256 sourceVersion, uint256 pricingVersion, uint256 observedAt, bool usedBackup);
    event LastValidUsed(bytes32 indexed quoteVersion, uint256 requiredStake, uint256 activeSourceVersion,
        uint256 seedSourceVersion, uint256 seedPolicyVersion, uint256 observedAt);
    event OwnershipChanged(bytes32 indexed idHash, address indexed previousOwner, address indexed owner,
        uint256 instanceId, uint256 nonce, uint8 status);
    event MetadataChanged(bytes32 indexed idHash, string description, string resolution);
    event FreeLockStarted(bytes32 indexed idHash, uint256 nonce, uint256 expiresAt);
    event PlatformDetached(bytes32 indexed idHash, address indexed originPlatform, uint256 createdGeneration);
    event StakeCreated(bytes32 indexed idHash, address indexed owner, uint256 amount, bytes32 quoteVersion, bool isFallback);
    event StakeCompleted(bytes32 indexed idHash, address indexed owner, uint256 amount, bytes32 quoteVersion, bool isFallback);
    event OldStakeCredited(bytes32 indexed idHash, address indexed beneficiary, uint256 amount);
    event StakeUnstaked(bytes32 indexed idHash, address indexed owner, address indexed to, uint256 amount);
    event OldStakeClaimed(address indexed beneficiary, address indexed to, uint256 amount);
    event ListingCreated(bytes32 indexed idHash, bytes32 indexed listingId, NG.Listing snapshot);
    event ListingCancelled(bytes32 indexed idHash, bytes32 indexed listingId);
    event Purchased(bytes32 indexed idHash, bytes32 indexed listingId, address indexed buyer,
        address seller, uint256 priceWei, uint256 feeWei, uint256 sellerNetWei, address settlementFeeRecipient);
    event DirectTransferred(bytes32 indexed idHash, address indexed sender, address indexed receiver,
        uint256 feeWei, uint256 refundWei, uint256 newNonce, uint256 sourceVersion);
    event ProtocolFeeCredited(address indexed beneficiary, uint256 amount);
    event ProtocolFeeClaimed(address indexed beneficiary, address indexed to, uint256 amount);
    event RegistrarChanged(address indexed registrar, uint256 walletEpoch);
    event SpecialStakeChanged(address indexed platform, uint256 generation, uint256 amount, bool active);
    event GenerationInvalidated(address indexed platform, uint256 invalidatedGeneration);
    event BatchCreated(address indexed platform, uint256 specialGeneration, address indexed custody,
        uint256 authorizationNonce, uint256 count);
    event CustodyProposed(bytes32 indexed proposalId, address indexed custody, uint256 walletEpoch);
    event CustodyCancelled(bytes32 indexed proposalId);
    event CustodyActivated(address indexed custody, uint256 version);
    event AdminProposed(address indexed current, address indexed pending);
    event AdminAccepted(address indexed previous, address indexed current);
    event CustodyNativeForwarded(address indexed admin, uint256 amount);
}
