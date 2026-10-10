pragma solidity 0.8.24;

library NG {
    enum Lifecycle { NORMAL, LISTED, FREE_LOCK, RELEASED }
    enum Asset { B6PW, ETH, USD }
    enum TrustTransition { COMPATIBLE_IMPLEMENTATION, SEMANTIC_CHANGE }
    // Existing module ordinals remain stable; QuotePolicy occupies the new slot.
    enum ModuleKind { MARKET_BUSINESS, BATCH_OPERATOR, QUOTE_POLICY }

    struct GenesisInputs {
        uint256 chainId; bytes32 generationId; address token;
        address governanceSafe; address feeRecipient; address platformWallet;
    }
    struct CoreBindings {
        address ownership; address stake; address settlement;
        address platformAccounting;
    }

    /// @dev Business policy values are mutable, but both FREE_LOCK durations are always nonzero.
    struct BusinessPolicy {
        uint256 targetUsd6; uint256 minimumFeeUsd6; uint16 marketFeeBps;
        uint64 marketFreeLock; uint64 directFreeLock;
        uint256 platformSpecialStake; uint32 platformBatchMax;
        uint32 platformSelectionMax; uint64 ethUsdMaxAge;
    }
    struct PriceQuote {
        uint256 price; uint8 decimals; bool valid;
        uint256 observedAt; uint64 sourceRevision;
    }
    struct SourceDescriptor {
        uint256 chainId; bytes32 generationId;
        Asset baseAsset; Asset quoteAsset; uint8 decimals;
        bytes32 bindingHash; uint64 sourceRevision; bytes32 sourceRootId;
    }
    struct SpotBinding {
        address config;
        address b6pwToken;
        address poolManager;
        address stateView;
        bytes32 poolId;
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        uint128 minLiquidity;
        uint256 minPrice;
        uint256 maxPrice;
    }
    struct EthUsdBinding {
        address config;
        address feed;
        uint8 feedDecimals;
    }
    struct SpotSourcePolicy {
        bytes32 policyHash;
        uint64 policyRevision;
    }
    struct EthUsdSourcePolicy {
        bytes32 policyHash;
        uint64 policyRevision;
    }
    struct SourceRoute {
        address spot; address ethUsd;
        bytes32 spotCodeHash; bytes32 ethUsdCodeHash;
        uint64 spotRevision; uint64 ethUsdRevision; bytes32 spotRootId; bytes32 ethUsdRootId;
    }
    struct SourceSet {
        SourceRoute primary; SourceRoute backup; bool backupEnabled;
    }
    struct OracleState {
        address directory; bytes32 directoryCodeHash;
        SourceSet sources; uint256 version; bytes32 sourceSetHash;
        uint64 sourceTrustEpoch; bytes32 sourceTrustCommitment; bytes32 sourceSemanticsHash; uint16 evidenceSchemaVersion;
    }
    struct OracleObservation {
        PriceQuote spot; PriceQuote ethUsd; PriceQuote b6pwUsd;
        uint256 sourceVersion; bytes32 sourceSetHash; bool usedBackup;
        uint16 schemaVersion; bytes32 sourceTrustCommitment; bytes32 routeIdentityHash;
        uint256 chainId; bytes32 generationId; address config; address stakeLedger; uint64 sourceTrustEpoch;
    }
    struct PriceEvidence {
        uint16 schemaVersion; uint256 chainId; bytes32 generationId; address config; address stakeLedger;
        uint64 sourceTrustEpoch; bytes32 sourceSetHash; bytes32 sourceTrustCommitment;
        bytes32 evidenceDigest; OracleObservation observation;
        SourceSet sources; uint256 acceptedAt;
    }
    struct EthObservation {
        PriceQuote ethUsd; uint256 sourceVersion;
        bytes32 sourceSetHash; bool usedBackup;
    }
    struct StakeQuote {
        uint256 requiredStake; uint256 priceUsd18; bytes32 quoteVersion;
        uint256 sourceVersion; uint256 seedSourceVersion;
        uint256 pricingPolicyVersion; uint256 seedPolicyVersion;
        uint256 observedAt; bool valid; bool isFallback; bool usedBackup;
    }
    struct Record {
        address owner; Lifecycle status; uint256 ownershipNonce;
        uint256 instanceId; uint256 freeLockExpiresAt; bool stakeComplete;
        bool platformOrigin; address originPlatform; uint256 createdGeneration;
        string description; string resolution;
    }
    struct StakeRecord { address owner; uint256 amount; bool active; }
    struct SpecialStake {
        uint256 amount; uint256 generation; uint256 invalidatedGeneration; bool active;
    }
    struct ListRequest {
        bytes32 generationId; string id; uint256 expectedOwnershipNonce;
        uint256 priceWei; uint256 expectedFeeWei; uint256 maxFeeWei;
        uint256 deadline; uint256 expectedOracleVersion; uint256 expectedMarketVersion;
    }
    struct BuyRequest {
        bytes32 generationId; string id; bytes32 listingId; address expectedSeller;
        uint256 expectedPriceWei; uint256 expectedOwnershipNonce; uint256 deadline;
    }
    struct DirectRequest {
        bytes32 generationId; string id; address receiver; uint256 expectedOwnershipNonce;
        uint256 maxFeeWei; uint256 deadline; uint256 expectedOracleVersion;
    }
    struct FeeContext { uint256 priceWei; uint16 feeBps; uint256 minimumFeeWei; }
    struct Listing {
        bytes32 listingId; address seller; uint256 ownershipNonce;
        uint256 priceWei; uint256 feeWei; uint16 feeBps; uint256 minimumFeeWei;
        uint256 ethUsdPrice18; uint256 ethUsdObservedAt; uint64 oracleMaxAge;
        uint64 freeLockDuration;
        uint256 economicPolicyVersion; uint256 sourceVersion; uint256 marketVersion;
        bool platformOrigin; address originPlatform; uint256 createdGeneration; bool active;
    }
    struct BatchRequest {
        bytes32 generationId; address platform; address registrar; address custody;
        uint256 walletEpoch; uint256 platformAuthorizationEpoch;
        bytes32 registrarCodeHash; bytes32 custodyCodeHash;
        uint256 specialGeneration; uint256 operatorVersion;
        uint256 authorizationNonce; uint256 deadline; string[] ids;
    }
    struct CustodyProposal {
        address custody; address expectedAdmin; bytes32 codeHash;
        uint256 expectedVersion; uint256 proposerWalletEpoch;
    }
    struct SpotInputs {
        address poolManager; address stateView; bytes32 poolId;
        address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks;
        uint128 minLiquidity; uint256 minPrice; uint256 maxPrice;
    }
}
