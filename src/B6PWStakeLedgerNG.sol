pragma solidity 0.8.24;

import {IGenerationIdentity} from "../interfaces/IGenerationIdentity.sol";
import {IGovernanceConfig} from "../interfaces/IGovernanceConfig.sol";
import {IOracleDirectory} from "../interfaces/IOracleDirectory.sol";
import {IOwnershipCore} from "../interfaces/IOwnershipCore.sol";
import {IPlatformAccounting} from "../interfaces/IPlatformAccounting.sol";
import {IQuotePolicyHub} from "../interfaces/IQuotePolicyHub.sol";
import {ISettlementKernel} from "../interfaces/ISettlementKernel.sol";
import {IStakeLedger} from "../interfaces/IStakeLedger.sol";
import {NG} from "../interfaces/NextGenTypes.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import {FullPrecisionMath} from "../libraries/FullPrecisionMath.sol";
import "../interfaces/NextGenErrors.sol";
import {NextGenEvents} from "../interfaces/NextGenEvents.sol";

interface IERC20NextGen {
    function balanceOf(address account) external view returns (uint256);
}

contract B6PWStakeLedgerNG is IStakeLedger, NextGenEvents {
    bytes32 private constant OWNERSHIP_ROLE = keccak256("B6PW_NEXTGEN_V1:Ownership");
    bytes32 private constant STAKE_ROLE = keccak256("B6PW_NEXTGEN_V1:Stake");
    bytes32 private constant SETTLEMENT_ROLE = keccak256("B6PW_NEXTGEN_V1:Settlement");
    bytes32 private constant PLATFORM_ROLE = keccak256("B6PW_NEXTGEN_V1:Platform");
    bytes32 private constant QUOTE_ROLE = keccak256("B6PW_NEXTGEN_V1:Quote");
    bytes32 private constant ORACLE_DIRECTORY_ROLE = keccak256("B6PW_NEXTGEN_V1:OracleDirectory");
    uint256 private constant TOKEN_SCALE = 1e18;
    uint256 private constant USD6_TO_USD18 = 1e12;
    uint256 private constant QUOTE_MODULE_READ_GAS = 250_000;
    uint256 private constant QUOTE_IDENTITY_READ_GAS = 50_000;
    uint256 private constant ORACLE_DIRECTORY_READ_GAS = 250_000;
    uint256 private constant QUOTE_BYTES = 352;
    uint256 private constant ORACLE_OBSERVATION_BYTES = 832;

    uint8 private constant FRESH_QUOTE = 1;
    uint8 private constant SOURCE_INVALID = 2;
    uint8 private constant MODULE_INVALID = 3;

    bytes4 private constant TRANSFER_SELECTOR = bytes4(keccak256("transfer(address,uint256)"));
    bytes4 private constant TRANSFER_FROM_SELECTOR = bytes4(keccak256("transferFrom(address,address,uint256)"));

    address private immutable _config;
    address private immutable _token;
    uint256 private immutable _chainId;
    bytes32 private immutable _generationId;

    mapping(bytes32 idHash => NG.StakeRecord record) private _stakes;
    mapping(address beneficiary => uint256 amount) private _claimable;
    NG.PriceEvidence private _lastValidEvidence;

    uint256 public override totalActiveStake;
    uint256 public override totalClaimableStake;
    uint256 private _entered;

    modifier nonReentrant() {
        if (_entered == 1) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(address config_) {
        if (config_ == address(0) || config_.code.length == 0) revert InvalidConfiguration();
        address token_ = IGovernanceConfig(config_).token();
        uint256 configuredChain = IGovernanceConfig(config_).chainId();
        bytes32 configuredGeneration = IGovernanceConfig(config_).generationId();
        if (
            token_ == address(0)
                || token_.code.length == 0
                || configuredChain == 0
                || configuredGeneration == bytes32(0)
        ) revert InvalidConfiguration();
        _config = config_;
        _token = token_;
        _chainId = configuredChain;
        _generationId = configuredGeneration;
    }

    function chainId() external view override returns (uint256) {
        return _chainId;
    }

    function generationId() external view override returns (bytes32) {
        return _generationId;
    }

    function config() external view override returns (address) {
        return _config;
    }

    function roleId() external pure override returns (bytes32) {
        return STAKE_ROLE;
    }

    function token() external view override returns (address) {
        return _token;
    }

    function stakeOf(bytes32 idHash_) external view override returns (NG.StakeRecord memory) {
        return _stakes[idHash_];
    }

    function claimableOf(address beneficiary) external view override returns (uint256) {
        return _claimable[beneficiary];
    }

    function previewQuote() external view override returns (NG.StakeQuote memory) {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        (NG.StakeQuote memory fresh, uint8 status) = _readFreshQuote(bindings);
        if (status == FRESH_QUOTE) return fresh;
        if (status == SOURCE_INVALID && _lastValidEvidence.schemaVersion != 0) {
            NG.StakeQuote memory cached = _fallbackQuote(bindings.ownership);
            if (cached.valid) return cached;
        }
        return _invalidQuote();
    }

    function lastValidQuote() external view override returns (NG.StakeQuote memory) {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        if (_lastValidEvidence.schemaVersion == 0) return _invalidQuote();
        return _fallbackQuote(bindings.ownership);
    }

    function lastValidEvidence() external view override returns (NG.PriceEvidence memory) {
        _requireIdentity();
        _requireSealed();
        return _lastValidEvidence;
    }

    function acceptCurrentQuote() external override returns (NG.StakeQuote memory) {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        NG.StakeQuote memory quote;
        uint8 status;
        (quote, status) = _readFreshQuote(bindings);
        if (status != FRESH_QUOTE) revert InvalidQuote();
        _storeFreshQuote();
        emit FreshQuoteAccepted(
            quote.quoteVersion,
            quote.requiredStake,
            quote.priceUsd18,
            quote.sourceVersion,
            quote.pricingPolicyVersion,
            quote.observedAt,
            quote.usedBackup
        );
        return quote;
    }

    function register(
        string calldata id,
        uint256 expectedRequiredStake,
        uint256 maxStake,
        uint256 deadline,
        bytes32 expectedQuoteVersion
    ) external override nonReentrant {
        _register(id, "", "", expectedRequiredStake, maxStake, deadline, expectedQuoteVersion, false);
    }

    function registerWithMetadata(
        string calldata id,
        string memory description,
        string memory resolution,
        uint256 expectedRequiredStake,
        uint256 maxStake,
        uint256 deadline,
        bytes32 expectedQuoteVersion
    ) external override nonReentrant {
        _register(id, description, resolution, expectedRequiredStake, maxStake, deadline, expectedQuoteVersion, true);
    }

    function completeStake(
        string calldata id,
        uint256 expectedRequiredStake,
        uint256 maxStake,
        uint256 deadline,
        bytes32 expectedQuoteVersion
    ) external override nonReentrant {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        bytes32 idHash_ = IOwnershipCore(bindings.ownership).idHash(id);
        NG.Record memory record = IOwnershipCore(bindings.ownership).getRecord(idHash_);
        if (
            record.status != NG.Lifecycle.FREE_LOCK
                || record.owner != msg.sender
                || record.stakeComplete
                || record.freeLockExpiresAt <= block.timestamp
        ) revert InvalidLifecycle();
        if (_stakes[idHash_].active) revert AlreadyStaked();

        NG.StakeQuote memory quote = _ensureQuote(
            bindings,
            expectedRequiredStake,
            maxStake,
            deadline,
            expectedQuoteVersion
        );
        _transferFromExact(msg.sender, quote.requiredStake);
        uint256 nextNonce = IOwnershipCore(bindings.ownership)
            .completeFreeLock(idHash_, msg.sender, record.ownershipNonce);
        _stakes[idHash_] = NG.StakeRecord({owner: msg.sender, amount: quote.requiredStake, active: true});
        totalActiveStake += quote.requiredStake;
        _assertSolvent();
        emit StakeCompleted(idHash_, msg.sender, quote.requiredStake, quote.quoteVersion, quote.isFallback);
        nextNonce;
    }

    function unstake(string calldata id, address to) external override nonReentrant {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        _validatePayout(to);
        bytes32 idHash_ = IOwnershipCore(bindings.ownership).idHash(id);
        NG.Record memory record = IOwnershipCore(bindings.ownership).getRecord(idHash_);
        NG.StakeRecord memory stake = _stakes[idHash_];
        if (
            !stake.active
                || stake.owner != msg.sender
                || record.status != NG.Lifecycle.NORMAL
                || record.owner != msg.sender
                || !record.stakeComplete
        ) revert InvalidLifecycle();

        IOwnershipCore(bindings.ownership).releaseOrdinary(idHash_, msg.sender, record.ownershipNonce);
        _stakes[idHash_] = NG.StakeRecord({owner: address(0), amount: 0, active: false});
        totalActiveStake -= stake.amount;
        _transferExact(to, stake.amount);
        _assertSolvent();
        emit StakeUnstaked(idHash_, msg.sender, to, stake.amount);
    }

    function claimOldStake(address to) external override nonReentrant {
        _requireIdentity();
        _requireSealed();
        _validatePayout(to);
        uint256 amount = _claimable[msg.sender];
        if (amount == 0) revert InvalidLifecycle();
        _claimable[msg.sender] = 0;
        totalClaimableStake -= amount;
        _transferExact(to, amount);
        _assertSolvent();
        emit OldStakeClaimed(msg.sender, to, amount);
    }

    function creditOldStake(bytes32 idHash_, address expectedOwner, uint256 expectedNonce) external override nonReentrant {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        if (msg.sender != bindings.settlement) revert Unauthorized();
        NG.StakeRecord storage stake = _stakes[idHash_];
        NG.Record memory record = IOwnershipCore(bindings.ownership).getRecord(idHash_);
        if (
            record.owner != expectedOwner
                || record.ownershipNonce != expectedNonce
                || (record.status != NG.Lifecycle.NORMAL && record.status != NG.Lifecycle.LISTED)
        ) revert InvalidLifecycle();

        // Platform-origin records are collateralized by the shared special stake,
        // not by an ordinary per-ID ledger record. Detach therefore preserves
        // the ordinary liabilities unchanged and lets OwnershipCore move the ID
        // into FREE_LOCK for the receiver.
        if (record.platformOrigin) {
            if (stake.active || stake.amount != 0 || stake.owner != address(0)) revert InvalidLifecycle();
            return;
        }
        if (!stake.active || stake.owner != expectedOwner) revert InvalidLifecycle();

        uint256 amount = stake.amount;
        _stakes[idHash_] = NG.StakeRecord({owner: address(0), amount: 0, active: false});
        totalActiveStake -= amount;
        _claimable[expectedOwner] += amount;
        totalClaimableStake += amount;
        _assertSolvent();
        emit OldStakeCredited(idHash_, expectedOwner, amount);
    }

    function _register(
        string calldata id,
        string memory description,
        string memory resolution,
        uint256 expectedRequiredStake,
        uint256 maxStake,
        uint256 deadline,
        bytes32 expectedQuoteVersion,
        bool withMetadata
    ) private {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        bytes32 idHash_ = IOwnershipCore(bindings.ownership).idHash(id);
        if (!IOwnershipCore(bindings.ownership).isAvailable(id)) revert IdUnavailable();
        if (_stakes[idHash_].active) revert AlreadyStaked();

        NG.StakeQuote memory quote = _ensureQuote(
            bindings,
            expectedRequiredStake,
            maxStake,
            deadline,
            expectedQuoteVersion
        );
        _transferFromExact(msg.sender, quote.requiredStake);
        (bytes32 registeredHash,) = withMetadata
            ? IOwnershipCore(bindings.ownership).createOrdinary(id, msg.sender, description, resolution)
            : IOwnershipCore(bindings.ownership).createOrdinary(id, msg.sender, "", "");
        if (registeredHash != idHash_) revert InvalidConfiguration();
        _stakes[idHash_] = NG.StakeRecord({owner: msg.sender, amount: quote.requiredStake, active: true});
        totalActiveStake += quote.requiredStake;
        _assertSolvent();
        emit StakeCreated(idHash_, msg.sender, quote.requiredStake, quote.quoteVersion, quote.isFallback);
    }

    function _ensureQuote(
        NG.CoreBindings memory bindings,
        uint256 expectedRequiredStake,
        uint256 maxStake,
        uint256 deadline,
        bytes32 expectedQuoteVersion
    ) private returns (NG.StakeQuote memory quote) {
        (NG.StakeQuote memory fresh, uint8 status) = _readFreshQuote(bindings);
        if (status == FRESH_QUOTE) {
            quote = fresh;
            _storeFreshQuote();
            emit FreshQuoteAccepted(
                quote.quoteVersion,
                quote.requiredStake,
                quote.priceUsd18,
                quote.sourceVersion,
                quote.pricingPolicyVersion,
                quote.observedAt,
                quote.usedBackup
            );
        } else if (status == SOURCE_INVALID) {
            if (_lastValidEvidence.schemaVersion == 0) revert NoValidSeed();
            quote = _fallbackQuote(bindings.ownership);
            if (!quote.valid) revert NoValidSeed();
            NG.OracleState memory state = IGovernanceConfig(_config).oracleState();
            emit LastValidUsed(
                quote.quoteVersion,
                quote.requiredStake,
                state.version,
                quote.sourceVersion,
                quote.pricingPolicyVersion,
                quote.observedAt
            );
        } else {
            // A malformed or formula-inconsistent replaceable module is not an
            // oracle outage.  It must never be converted into a last-valid
            // acceptance path.
            revert InvalidQuote();
        }
        if (quote.requiredStake != expectedRequiredStake) revert RequiredStakeMismatch();
        if (quote.requiredStake > maxStake) revert MaxStakeExceeded();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (quote.quoteVersion != expectedQuoteVersion) revert QuoteVersionMismatch();
    }

    function _readFreshQuote(NG.CoreBindings memory bindings)
        private
        view
        returns (NG.StakeQuote memory quote, uint8 status)
    {
        NG.OracleState memory oracle;
        NG.BusinessPolicy memory policy;
        uint256 pricingVersion;
        address module;
        bytes32 codeHash;
        uint256 moduleVersion;
        try IGovernanceConfig(_config).oracleState() returns (NG.OracleState memory state) {
            oracle = state;
        } catch {
            return (quote, SOURCE_INVALID);
        }
        try IGovernanceConfig(_config).policy() returns (NG.BusinessPolicy memory configuredPolicy) {
            policy = configuredPolicy;
        } catch {
            return (quote, MODULE_INVALID);
        }
        try IGovernanceConfig(_config).pricingPolicyVersion() returns (uint256 configuredVersion) {
            pricingVersion = configuredVersion;
        } catch {
            return (quote, MODULE_INVALID);
        }
        try IGovernanceConfig(_config).moduleState(NG.ModuleKind.QUOTE_POLICY) returns (
            address configuredModule,
            bytes32 configuredCodeHash,
            uint256 configuredVersion
        ) {
            module = configuredModule;
            codeHash = configuredCodeHash;
            moduleVersion = configuredVersion;
        } catch {
            return (quote, MODULE_INVALID);
        }
        if (
            module == address(0)
                || module.code.length == 0
                || codeHash == bytes32(0)
                || module.codehash != codeHash
                || moduleVersion == 0
                || !_validModuleIdentity(module)
        ) return (quote, MODULE_INVALID);

        (bool ok, bytes memory data) = BoundedStaticCall.callView(
            module,
            abi.encodeWithSelector(IQuotePolicyHub.previewQuote.selector),
            QUOTE_MODULE_READ_GAS,
            QUOTE_BYTES
        );
        if (!ok || data.length != QUOTE_BYTES) return (quote, MODULE_INVALID);
        quote = abi.decode(data, (NG.StakeQuote));

        uint8 quoteStatus = _validFreshQuote(
            quote, bindings.ownership, module, moduleVersion, oracle, policy, pricingVersion
        );
        return (quote, quoteStatus);
    }

    function _validModuleIdentity(address module) private view returns (bool) {
        (bool chainOk, bytes32 chainWord) = _readIdentityWord(module, IGenerationIdentity.chainId.selector);
        (bool generationOk, bytes32 generationWord) =
            _readIdentityWord(module, IGenerationIdentity.generationId.selector);
        (bool configOk, bytes32 configWord) = _readIdentityWord(module, IGenerationIdentity.config.selector);
        (bool roleOk, bytes32 roleWord) = _readIdentityWord(module, IGenerationIdentity.roleId.selector);
        return chainOk
            && uint256(chainWord) == _chainId
            && generationOk
            && generationWord == _generationId
            && configOk
            && address(uint160(uint256(configWord))) == _config
            && roleOk
            && roleWord == QUOTE_ROLE;
    }

    function _readIdentityWord(address target, bytes4 selector) private view returns (bool ok, bytes32 word) {
        bytes memory data;
        (ok, data) = BoundedStaticCall.callView(
            target,
            abi.encodeWithSelector(selector),
            QUOTE_IDENTITY_READ_GAS,
            32
        );
        if (!ok || data.length != 32) return (false, bytes32(0));
        assembly {
            word := mload(add(data, 32))
        }
    }

    function _validFreshQuote(
        NG.StakeQuote memory quote,
        address ownership,
        address module,
        uint256 moduleVersion,
        NG.OracleState memory oracle,
        NG.BusinessPolicy memory policy,
        uint256 pricingVersion
    ) private view returns (uint8) {
        NG.OracleObservation memory observation;
        uint8 observationStatus;
        (observation, observationStatus) = _readApprovedObservation(oracle, policy.ethUsdMaxAge);
        if (observationStatus != FRESH_QUOTE) return observationStatus;
        uint256 expectedPrice = observation.b6pwUsd.price;
        if (!_validPrice(observation.b6pwUsd, observation.b6pwUsd.sourceRevision) || expectedPrice == 0) {
            return SOURCE_INVALID;
        }
        (bool requirementOk, uint256 expectedRequiredStake) = _requiredStake(policy.targetUsd6, expectedPrice);
        if (!requirementOk) return MODULE_INVALID;
        uint256 observedAt = observation.b6pwUsd.observedAt;
        if (
            !quote.valid
                || quote.isFallback
                || quote.requiredStake < expectedRequiredStake
                || quote.requiredStake == 0
                || quote.requiredStake % TOKEN_SCALE != 0
                || quote.priceUsd18 != expectedPrice
                || quote.quoteVersion == bytes32(0)
                || quote.sourceVersion == 0
                || quote.sourceVersion != oracle.version
                || quote.seedSourceVersion != quote.sourceVersion
                || quote.pricingPolicyVersion == 0
                || quote.pricingPolicyVersion != pricingVersion
                || quote.seedPolicyVersion != quote.pricingPolicyVersion
                || quote.observedAt == 0
                || quote.observedAt != observedAt
                || quote.usedBackup != observation.usedBackup
        ) return MODULE_INVALID;
        return quote.quoteVersion == _expectedQuoteVersion(
            ownership, module, pricingVersion, oracle.version, moduleVersion
        ) ? FRESH_QUOTE : MODULE_INVALID;
    }

    function _expectedQuoteVersion(
        address ownership, address module, uint256 pricingVersion, uint256 sourceVersion, uint256 moduleVersion
    )
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(_chainId, _generationId, _config, ownership, module, pricingVersion, sourceVersion, moduleVersion)
        );
    }

    function _readApprovedObservation(NG.OracleState memory oracle, uint256 maxAge)
        private
        view
        returns (NG.OracleObservation memory observation, uint8 status)
    {
        uint8 primaryStatus;
        (observation, primaryStatus) = _readObservation(oracle, false, maxAge);
        if (primaryStatus == FRESH_QUOTE) return (observation, FRESH_QUOTE);
        if (!oracle.sources.backupEnabled) return (observation, primaryStatus);

        uint8 backupStatus;
        (observation, backupStatus) = _readObservation(oracle, true, maxAge);
        if (backupStatus == FRESH_QUOTE) return (observation, FRESH_QUOTE);
        if (primaryStatus == MODULE_INVALID || backupStatus == MODULE_INVALID) {
            return (observation, MODULE_INVALID);
        }
        return (observation, SOURCE_INVALID);
    }

    function _readObservation(
        NG.OracleState memory oracle,
        bool useBackup,
        uint256 maxAge
    ) private view returns (NG.OracleObservation memory observation, uint8 status) {
        (bool ok, bytes memory data) = BoundedStaticCall.callView(
            oracle.directory,
            abi.encodeWithSelector(IOracleDirectory.readRegistration.selector, useBackup),
            ORACLE_DIRECTORY_READ_GAS,
            ORACLE_OBSERVATION_BYTES
        );
        if (!ok || data.length != ORACLE_OBSERVATION_BYTES) return (observation, SOURCE_INVALID);
        observation = abi.decode(data, (NG.OracleObservation));
        status = _observationStatus(observation, oracle, useBackup, maxAge);
    }

    function _observationStatus(
        NG.OracleObservation memory observation,
        NG.OracleState memory oracle,
        bool useBackup,
        uint256 maxAge
    ) private view returns (uint8) {
        uint8 provenance = IGovernanceConfig(_config).validatePriceObservation(observation, useBackup);
        if (provenance != FRESH_QUOTE) return provenance;
        NG.SourceRoute memory route = useBackup ? oracle.sources.backup : oracle.sources.primary;
        NG.PriceQuote memory spot = IGovernanceConfig(_config).validateSpotSource(
            useBackup, route.spot, route.spotCodeHash, route.spotRevision, route.spotRootId
        );
        NG.PriceQuote memory ethUsd = IGovernanceConfig(_config).validateEthUsdSource(
            useBackup, route.ethUsd, route.ethUsdCodeHash, route.ethUsdRevision, route.ethUsdRootId
        );
        if (!_validPrice(spot, route.spotRevision) || !_validPrice(ethUsd, route.ethUsdRevision)) {
            return SOURCE_INVALID;
        }
        if (
            !_samePriceQuote(observation.spot, spot) || !_samePriceQuote(observation.ethUsd, ethUsd)
                || !_validPrice(observation.b6pwUsd, route.spotRevision)
        ) return MODULE_INVALID;
        (bool compositionValid, uint256 composedPrice) = _tryMulDiv(spot.price, ethUsd.price, TOKEN_SCALE);
        if (!compositionValid || composedPrice == 0 || observation.b6pwUsd.price != composedPrice) {
            return MODULE_INVALID;
        }
        uint256 expectedObservedAt = spot.observedAt < ethUsd.observedAt ? spot.observedAt : ethUsd.observedAt;
        if (observation.b6pwUsd.observedAt != expectedObservedAt) return MODULE_INVALID;
        if (
            maxAge == 0 || block.timestamp < observation.b6pwUsd.observedAt
                || block.timestamp - observation.b6pwUsd.observedAt > maxAge
        ) return SOURCE_INVALID;
        return FRESH_QUOTE;
    }

    function _samePriceQuote(NG.PriceQuote memory a, NG.PriceQuote memory b) private pure returns (bool) {
        return a.price == b.price && a.decimals == b.decimals && a.valid == b.valid
            && a.observedAt == b.observedAt && a.sourceRevision == b.sourceRevision;
    }

    function _validPrice(NG.PriceQuote memory price, uint64 expectedRevision) private pure returns (bool) {
        return price.valid
            && price.decimals == 18
            && price.price > 0
            && price.observedAt != 0
            && price.sourceRevision == expectedRevision;
    }

    function _requiredStake(uint256 targetUsd6, uint256 priceUsd18)
        private
        pure
        returns (bool valid, uint256 requiredStake)
    {
        if (targetUsd6 == 0 || priceUsd18 == 0) return (false, 0);
        (bool ok, uint256 wholeTokens) = _tryMulDivUp(targetUsd6, USD6_TO_USD18, priceUsd18);
        if (!ok || wholeTokens == 0 || wholeTokens > type(uint256).max / TOKEN_SCALE) return (false, 0);
        return (true, wholeTokens * TOKEN_SCALE);
    }

    function _tryMulDivUp(uint256 numerator, uint256 multiplier, uint256 denominator)
        private
        pure
        returns (bool valid, uint256 result)
    {
        if (denominator == 0) return (false, 0);
        (valid, result) = _tryMulDiv(numerator, multiplier, denominator);
        if (!valid) return (false, 0);
        if (mulmod(numerator, multiplier, denominator) != 0) {
            if (result == type(uint256).max) return (false, 0);
            ++result;
        }
    }

    function _tryMulDiv(uint256 a, uint256 b, uint256 denominator)
        private
        pure
        returns (bool valid, uint256 result)
    {
        if (denominator == 0) return (false, 0);
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) return (true, prod0 / denominator);
            if (prod1 >= denominator) return (false, 0);

            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (0 - denominator);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            return (true, prod0 * inverse);
        }
    }

    function _storeFreshQuote() private {
        NG.OracleState memory oracle = IGovernanceConfig(_config).oracleState();
        NG.BusinessPolicy memory policy = IGovernanceConfig(_config).policy();
        (NG.OracleObservation memory observation, uint8 status) =
            _readApprovedObservation(oracle, policy.ethUsdMaxAge);
        if (status != FRESH_QUOTE) revert InvalidQuote();
        NG.PriceEvidence memory evidence = NG.PriceEvidence({
            schemaVersion: oracle.evidenceSchemaVersion,
            chainId: _chainId,
            generationId: _generationId,
            config: _config,
            stakeLedger: address(this),
            sourceTrustEpoch: oracle.sourceTrustEpoch,
            sourceSetHash: oracle.sourceSetHash,
            sourceTrustCommitment: oracle.sourceTrustCommitment,
            evidenceDigest: bytes32(0),
            observation: observation,
            sources: oracle.sources,
            acceptedAt: block.timestamp
        });
        evidence.evidenceDigest = _evidenceDigest(evidence);
        _lastValidEvidence = evidence;
    }

    function _fallbackQuote(address ownership) private view returns (NG.StakeQuote memory quote) {
        NG.OracleState memory oracle = IGovernanceConfig(_config).oracleState();
        NG.BusinessPolicy memory policy = IGovernanceConfig(_config).policy();
        NG.PriceEvidence memory evidence = _lastValidEvidence;
        if (
            evidence.schemaVersion == 0 || evidence.schemaVersion != oracle.evidenceSchemaVersion
                || evidence.chainId != _chainId
                || evidence.generationId != _generationId || evidence.config != _config
                || evidence.stakeLedger != address(this)
                || evidence.sourceTrustEpoch != oracle.sourceTrustEpoch
                || evidence.sourceTrustCommitment != oracle.sourceTrustCommitment
                || evidence.observation.sourceSetHash != evidence.sourceSetHash
                || evidence.observation.sourceTrustCommitment != evidence.sourceTrustCommitment
                || evidence.evidenceDigest != _evidenceDigest(evidence)
        ) {
            return _invalidQuote();
        }
        (address module, bytes32 moduleCodeHash, uint256 moduleVersion) =
            IGovernanceConfig(_config).moduleState(NG.ModuleKind.QUOTE_POLICY);
        if (
            module == address(0) || module.code.length == 0 || module.codehash != moduleCodeHash
                || moduleVersion == 0 || !_validModuleIdentity(module)
        ) return _invalidQuote();
        (bool ok, bytes memory data) = BoundedStaticCall.callView(
            module,
            abi.encodeWithSelector(IQuotePolicyHub.previewQuoteFromEvidence.selector, evidence),
            QUOTE_MODULE_READ_GAS,
            QUOTE_BYTES
        );
        if (!ok || data.length != QUOTE_BYTES) return _invalidQuote();
        quote = abi.decode(data, (NG.StakeQuote));
        (bool floorOk, uint256 floor) = _requiredStake(policy.targetUsd6, evidence.observation.b6pwUsd.price);
        if (
            !floorOk || !quote.valid || !quote.isFallback || quote.requiredStake < floor
                || quote.requiredStake == 0 || quote.requiredStake % TOKEN_SCALE != 0
                || quote.priceUsd18 != evidence.observation.b6pwUsd.price
                || quote.sourceVersion != oracle.version
                || quote.seedSourceVersion != evidence.observation.sourceVersion
                || quote.pricingPolicyVersion != IGovernanceConfig(_config).pricingPolicyVersion()
                || quote.observedAt != evidence.observation.b6pwUsd.observedAt
                || quote.usedBackup != evidence.observation.usedBackup
                || quote.quoteVersion != _expectedQuoteVersion(
                    ownership, module, quote.pricingPolicyVersion, oracle.version, moduleVersion
                )
        ) return _invalidQuote();
    }

    function _evidenceDigest(NG.PriceEvidence memory evidence) private pure returns (bytes32) {
        return keccak256(abi.encode(
            evidence.schemaVersion, evidence.chainId, evidence.generationId, evidence.config,
            evidence.stakeLedger, evidence.sourceTrustEpoch, evidence.sourceSetHash,
            evidence.sourceTrustCommitment, evidence.observation, evidence.sources, evidence.acceptedAt
        ));
    }

    function _invalidQuote() private pure returns (NG.StakeQuote memory quote) {
        quote.valid = false;
    }

    function _requireIdentity() private view {
        if (block.chainid != _chainId) revert WrongChain();
    }

    function _requireSealed() private view returns (NG.CoreBindings memory bindings) {
        if (!IGovernanceConfig(_config).coreSealed()) revert CoreNotSealed();
        bindings = IGovernanceConfig(_config).coreBindings();
        if (bindings.stake != address(this)) revert CustodyBindingMismatch();
        _validatePeer(bindings.ownership, OWNERSHIP_ROLE);
        _validatePeer(bindings.settlement, SETTLEMENT_ROLE);
        _validatePeer(bindings.platformAccounting, PLATFORM_ROLE);
    }

    function _validatePeer(address peer, bytes32 expectedRole) private view {
        if (peer == address(0) || peer.code.length == 0) revert CustodyBindingMismatch();
        if (
            IGenerationIdentity(peer).chainId() != _chainId
                || IGenerationIdentity(peer).generationId() != _generationId
                || IGenerationIdentity(peer).config() != _config
                || IGenerationIdentity(peer).roleId() != expectedRole
        ) revert CustodyBindingMismatch();
    }

    function _transferFromExact(address from, uint256 amount) private {
        uint256 beforeSender = _balanceOf(from);
        uint256 beforeLedger = _balanceOf(address(this));
        (bool success, bytes memory data) = _token.call(
            abi.encodeWithSelector(TRANSFER_FROM_SELECTOR, from, address(this), amount)
        );
        if (!success || (data.length != 0 && (data.length < 32 || !abi.decode(data, (bool))))) {
            revert ExactTransferMismatch();
        }
        uint256 afterSender = _balanceOf(from);
        uint256 afterLedger = _balanceOf(address(this));
        if (
            beforeSender < afterSender
                || beforeSender - afterSender != amount
                || afterLedger < beforeLedger
                || afterLedger - beforeLedger != amount
        ) revert ExactTransferMismatch();
    }

    function _transferExact(address to, uint256 amount) private {
        uint256 beforeVault = _balanceOf(address(this));
        uint256 beforeRecipient = _balanceOf(to);
        (bool success, bytes memory data) = _token.call(abi.encodeWithSelector(TRANSFER_SELECTOR, to, amount));
        if (!success || (data.length != 0 && (data.length < 32 || !abi.decode(data, (bool))))) {
            revert ExactTransferMismatch();
        }
        uint256 afterVault = _balanceOf(address(this));
        uint256 afterRecipient = _balanceOf(to);
        if (
            afterVault > beforeVault
                || beforeVault - afterVault != amount
                || afterRecipient < beforeRecipient
                || afterRecipient - beforeRecipient != amount
        ) revert ExactTransferMismatch();
    }

    function _balanceOf(address account) private view returns (uint256 balance) {
        (bool success, bytes memory data) = _token.staticcall(
            abi.encodeWithSelector(IERC20NextGen.balanceOf.selector, account)
        );
        if (!success || data.length != 32) revert ExactTransferMismatch();
        balance = abi.decode(data, (uint256));
    }

    function _assertSolvent() private view {
        if (_balanceOf(address(this)) < totalActiveStake + totalClaimableStake) revert Insolvent();
    }

    function _validatePayout(address to) private view {
        if (to == address(0) || to == address(this)) revert InvalidReceiver();
    }
}
