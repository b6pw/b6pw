pragma solidity 0.8.24;

import {IGenerationIdentity} from "../interfaces/IGenerationIdentity.sol";
import {IGovernanceConfig} from "../interfaces/IGovernanceConfig.sol";
import {IOracleDirectory} from "../interfaces/IOracleDirectory.sol";
import {IQuotePolicyHub} from "../interfaces/IQuotePolicyHub.sol";
import {NG} from "../interfaces/NextGenTypes.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import "../interfaces/NextGenErrors.sol";
import {NextGenEvents} from "../interfaces/NextGenEvents.sol";

contract B6PWQuotePolicyHubNG is IQuotePolicyHub, NextGenEvents {
    uint256 private constant USD6_TO_USD18 = 1e12;
    uint256 private constant TOKEN_SCALE = 1e18;
    bytes32 private constant OWNERSHIP_ROLE = keccak256("B6PW_NEXTGEN_V1:Ownership");
    bytes32 private constant QUOTE_ROLE = keccak256("B6PW_NEXTGEN_V1:Quote");
    uint256 private constant DIRECTORY_READ_GAS = 250_000;
    uint256 private constant IDENTITY_READ_GAS = 50_000;
    uint256 private constant ORACLE_OBSERVATION_BYTES = 832;

    address private immutable _config;
    uint256 private immutable _chainId;
    bytes32 private immutable _generationId;

    constructor(address config_) {
        if (config_ == address(0) || config_.code.length == 0) revert InvalidConfiguration();
        uint256 configuredChain = IGovernanceConfig(config_).chainId();
        bytes32 configuredGeneration = IGovernanceConfig(config_).generationId();
        if (configuredChain == 0 || configuredGeneration == bytes32(0)) revert InvalidConfiguration();
        _config = config_;
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
        return QUOTE_ROLE;
    }

    function previewQuote() external view override returns (NG.StakeQuote memory) {
        _requireIdentity();
        (NG.CoreBindings memory bindings, NG.OracleState memory state, NG.BusinessPolicy memory policy) = _context();
        (NG.StakeQuote memory fresh, bool valid) = _readFresh(bindings, state, policy);
        if (valid) return fresh;
        return NG.StakeQuote({
            requiredStake: 0,
            priceUsd18: 0,
            quoteVersion: bytes32(0),
            sourceVersion: 0,
            seedSourceVersion: 0,
            pricingPolicyVersion: 0,
            seedPolicyVersion: 0,
            observedAt: 0,
            valid: false,
            isFallback: false,
            usedBackup: false
        });
    }

    function _context()
        private
        view
        returns (NG.CoreBindings memory bindings, NG.OracleState memory state, NG.BusinessPolicy memory policy)
    {
        if (!IGovernanceConfig(_config).coreSealed()) revert CoreNotSealed();
        bindings = IGovernanceConfig(_config).coreBindings();
        _validatePeer(bindings.ownership, OWNERSHIP_ROLE);
        state = IGovernanceConfig(_config).oracleState();
        policy = IGovernanceConfig(_config).policy();
    }

    function _readFresh(NG.CoreBindings memory bindings, NG.OracleState memory state, NG.BusinessPolicy memory policy)
        private
        view
        returns (NG.StakeQuote memory quote, bool valid)
    {
        address directory = state.directory;
        if (!_validDirectory(directory, state.directoryCodeHash)) return (quote, false);
        if (!_validSourceSet(state.sources, state.version, state.sourceSetHash)) return (quote, false);

        NG.OracleObservation memory observation;
        bool observed;
        (observation, observed) = _readObservation(directory, false, state, policy.ethUsdMaxAge);
        if (!observed && state.sources.backupEnabled) {
            (observation, observed) = _readObservation(directory, true, state, policy.ethUsdMaxAge);
        }
        if (!observed) return (quote, false);

        uint256 priceUsd18 = observation.b6pwUsd.price;
        if (priceUsd18 == 0) return (quote, false);
        uint256 wholeTokens = _mulDivUp(policy.targetUsd6, USD6_TO_USD18, priceUsd18);
        if (wholeTokens == 0 || wholeTokens > type(uint256).max / TOKEN_SCALE) return (quote, false);
        uint256 requiredStake = wholeTokens * TOKEN_SCALE;
        uint256 moduleVersion = _moduleVersion();
        if (moduleVersion == 0) return (quote, false);
        bytes32 quoteVersion = _quoteVersion(bindings.ownership, state.version, moduleVersion);
        uint256 observedAt = observation.b6pwUsd.observedAt;
        quote = NG.StakeQuote({
            requiredStake: requiredStake,
            priceUsd18: priceUsd18,
            quoteVersion: quoteVersion,
            sourceVersion: state.version,
            seedSourceVersion: state.version,
            pricingPolicyVersion: policyVersion(),
            seedPolicyVersion: policyVersion(),
            observedAt: observedAt,
            valid: true,
            isFallback: false,
            usedBackup: observation.usedBackup
        });
        return (quote, true);
    }

    function previewQuoteFromEvidence(NG.PriceEvidence calldata evidence)
        external
        view
        override
        returns (NG.StakeQuote memory quote)
    {
        _requireIdentity();
        (NG.CoreBindings memory bindings, NG.OracleState memory state, NG.BusinessPolicy memory policy) = _context();
        if (
            msg.sender != bindings.stake || evidence.schemaVersion != state.evidenceSchemaVersion
                || evidence.observation.schemaVersion != state.evidenceSchemaVersion
                || evidence.chainId != _chainId || evidence.generationId != _generationId
                || evidence.config != _config || evidence.stakeLedger != bindings.stake
                || evidence.sourceTrustEpoch != state.sourceTrustEpoch
                || evidence.sourceTrustCommitment != state.sourceTrustCommitment
                || evidence.observation.sourceTrustCommitment != state.sourceTrustCommitment
                || evidence.observation.chainId != _chainId
                || evidence.observation.generationId != _generationId
                || evidence.observation.config != _config
                || evidence.observation.stakeLedger != bindings.stake
                || evidence.observation.sourceTrustEpoch != state.sourceTrustEpoch
                || evidence.evidenceDigest == bytes32(0)
        ) return _invalidQuote();
        uint256 priceUsd18 = evidence.observation.b6pwUsd.price;
        if (!_validPrice(evidence.observation.b6pwUsd) || priceUsd18 == 0) return _invalidQuote();
        (bool requirementOk, uint256 requiredStake) = _tryMulDivUp(policy.targetUsd6, USD6_TO_USD18, priceUsd18);
        if (!requirementOk || requiredStake == 0 || requiredStake > type(uint256).max / TOKEN_SCALE) {
            return _invalidQuote();
        }
        requiredStake *= TOKEN_SCALE;
        uint256 moduleVersion = _moduleVersion();
        if (moduleVersion == 0) return _invalidQuote();
        quote = NG.StakeQuote({
            requiredStake: requiredStake,
            priceUsd18: priceUsd18,
            quoteVersion: _quoteVersion(bindings.ownership, state.version, moduleVersion),
            sourceVersion: state.version,
            seedSourceVersion: evidence.observation.sourceVersion,
            pricingPolicyVersion: policyVersion(),
            seedPolicyVersion: evidence.observation.sourceVersion,
            observedAt: evidence.observation.b6pwUsd.observedAt,
            valid: true,
            isFallback: true,
            usedBackup: evidence.observation.usedBackup
        });
    }

    function _validObservation(
        NG.OracleObservation memory observation,
        NG.OracleState memory state,
        bool useBackup,
        uint256 ethUsdMaxAge
    ) private view returns (bool) {
        if (observation.sourceVersion != state.version || observation.sourceSetHash != state.sourceSetHash) return false;
        if (observation.usedBackup != useBackup) return false;
        if (
            observation.schemaVersion != state.evidenceSchemaVersion
                || observation.sourceTrustCommitment != state.sourceTrustCommitment
                || observation.chainId != _chainId || observation.generationId != _generationId
                || observation.config != _config
                || observation.stakeLedger != IGovernanceConfig(_config).coreBindings().stake
                || observation.sourceTrustEpoch != state.sourceTrustEpoch
                || observation.routeIdentityHash != _routeIdentityHash(state, useBackup)
                || !_validPrice(observation.spot) || !_validPrice(observation.ethUsd)
                || ethUsdMaxAge == 0 || block.timestamp - observation.ethUsd.observedAt > ethUsdMaxAge
        ) return false;
        if (!_validPrice(observation.b6pwUsd)) return false;
        return observation.b6pwUsd.price != 0;
    }

    function _validPrice(NG.PriceQuote memory price) private view returns (bool) {
        return price.valid
            && price.decimals == 18
            && price.price > 0
            && price.observedAt != 0
            && price.observedAt <= block.timestamp
            && price.sourceRevision != 0;
    }

    function _readObservation(
        address directory,
        bool useBackup,
        NG.OracleState memory state,
        uint256 ethUsdMaxAge
    )
        private
        view
        returns (NG.OracleObservation memory observation, bool valid)
    {
        (bool ok, bytes memory data) = BoundedStaticCall.callView(
            directory,
            abi.encodeWithSelector(IOracleDirectory.readRegistration.selector, useBackup),
            DIRECTORY_READ_GAS,
            ORACLE_OBSERVATION_BYTES
        );
        if (!ok || data.length != ORACLE_OBSERVATION_BYTES) return (observation, false);
        observation = abi.decode(data, (NG.OracleObservation));
        valid = _validObservation(observation, state, useBackup, ethUsdMaxAge);
    }

    function _validDirectory(address directory, bytes32 expectedCodeHash) private view returns (bool) {
        if (directory == address(0) || directory.code.length == 0 || expectedCodeHash == bytes32(0)) return false;
        if (directory.codehash != expectedCodeHash) return false;
        (bool chainOk, bytes32 chainWord) = _readIdentityWord(directory, IGenerationIdentity.chainId.selector);
        (bool generationOk, bytes32 generationWord) =
            _readIdentityWord(directory, IGenerationIdentity.generationId.selector);
        (bool configOk, bytes32 configWord) = _readIdentityWord(directory, IGenerationIdentity.config.selector);
        (bool roleOk, bytes32 roleWord) = _readIdentityWord(directory, IGenerationIdentity.roleId.selector);
        return chainOk
            && uint256(chainWord) == _chainId
            && generationOk
            && generationWord == _generationId
            && configOk
            && address(uint160(uint256(configWord))) == _config
            && roleOk
            && roleWord == keccak256("B6PW_NEXTGEN_V1:OracleDirectory");
    }

    function _readIdentityWord(address target, bytes4 selector) private view returns (bool ok, bytes32 word) {
        bytes memory callData = abi.encodeWithSelector(selector);
        bytes memory returnData;
        (ok, returnData) = BoundedStaticCall.callView(target, callData, IDENTITY_READ_GAS, 32);
        if (!ok || returnData.length != 32) return (false, bytes32(0));
        assembly {
            word := mload(add(returnData, 32))
        }
    }

    function _validSourceSet(NG.SourceSet memory sources, uint256 version, bytes32 sourceSetHash)
        private
        view
        returns (bool)
    {
        if (version == 0 || sourceSetHash == bytes32(0) || !_validRoute(sources.primary)) return false;
        if (!sources.backupEnabled) {
            return _emptyRoute(sources.backup);
        }
        return _validRoute(sources.backup);
    }

    function _validRoute(NG.SourceRoute memory route) private view returns (bool) {
        return route.spot != address(0)
            && route.ethUsd != address(0)
            && route.spot.code.length > 0
            && route.ethUsd.code.length > 0
            && route.spotCodeHash != bytes32(0)
            && route.ethUsdCodeHash != bytes32(0)
            && route.spot.codehash == route.spotCodeHash
            && route.ethUsd.codehash == route.ethUsdCodeHash
            && route.spotRevision != 0
            && route.ethUsdRevision != 0
            && route.spotRootId != bytes32(0)
            && route.ethUsdRootId != bytes32(0);
    }

    function _emptyRoute(NG.SourceRoute memory route) private pure returns (bool) {
        return route.spot == address(0)
            && route.ethUsd == address(0)
            && route.spotCodeHash == bytes32(0)
            && route.ethUsdCodeHash == bytes32(0)
            && route.spotRevision == 0
            && route.ethUsdRevision == 0
            && route.spotRootId == bytes32(0)
            && route.ethUsdRootId == bytes32(0);
    }

    function _quoteVersion(address ownership, uint256 sourceVersion, uint256 moduleVersion)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                _chainId,
                _generationId,
                _config,
                ownership,
                address(this),
                policyVersion(),
                sourceVersion,
                moduleVersion
            )
        );
    }

    function policyVersion() private view returns (uint256) {
        return IGovernanceConfig(_config).pricingPolicyVersion();
    }

    function _moduleVersion() private view returns (uint256) {
        (address module,, uint256 version) = IGovernanceConfig(_config).moduleState(NG.ModuleKind.QUOTE_POLICY);
        return module == address(this) ? version : 0;
    }

    function _routeIdentityHash(NG.OracleState memory state, bool useBackup) private view returns (bytes32) {
        NG.SourceRoute memory route = useBackup ? state.sources.backup : state.sources.primary;
        return keccak256(abi.encode(state.directory, state.directoryCodeHash, state.sourceSetHash, route));
    }

    function _invalidQuote() private pure returns (NG.StakeQuote memory quote) {
        quote.valid = false;
    }

    function _tryMulDivUp(uint256 numerator, uint256 multiplier, uint256 denominator)
        private
        pure
        returns (bool valid, uint256 result)
    {
        if (denominator == 0) return (false, 0);
        result = _mulDiv(numerator, multiplier, denominator);
        if (mulmod(numerator, multiplier, denominator) != 0) {
            if (result == type(uint256).max) return (false, 0);
            ++result;
        }
        return (true, result);
    }

    function _requireIdentity() private view {
        if (block.chainid != _chainId) revert WrongChain();
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

    function _mulDivUp(uint256 numerator, uint256 multiplier, uint256 denominator) private pure returns (uint256) {
        if (denominator == 0) revert InvalidQuote();
        uint256 product = _mulDiv(numerator, multiplier, denominator);
        if (mulmod(numerator, multiplier, denominator) != 0) {
            if (product == type(uint256).max) revert InvalidQuote();
            ++product;
        }
        return product;
    }

    function _mulDiv(uint256 a, uint256 b, uint256 denominator) private pure returns (uint256 result) {
        if (denominator == 0) revert InvalidQuote();
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        if (prod1 == 0) return prod0 / denominator;
        if (prod1 >= denominator) revert InvalidQuote();

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
        result = prod0 * inverse;
    }
}
