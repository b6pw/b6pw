pragma solidity 0.8.24;

import {IGenerationIdentity} from "../interfaces/IGenerationIdentity.sol";
import {IGovernanceConfig} from "../interfaces/IGovernanceConfig.sol";
import {IOracleDirectory} from "../interfaces/IOracleDirectory.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {NG} from "../interfaces/NextGenTypes.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import {FullPrecisionMath} from "../libraries/FullPrecisionMath.sol";

/// @notice Stateless typed composition of the active spot and ETH/USD pair.
/// @dev Routing authority and source versions live in GovernanceConfig. This
///      contract never stores a price, seed, or fallback value.
contract B6PWOracleDirectoryNG is IOracleDirectory {
    using BoundedStaticCall for address;

    uint256 private constant STATICCALL_GAS = 120_000;
    uint256 private constant MAX_SOURCE_RETURN_DATA = 256;
    bytes32 private constant CONFIG_ROLE = keccak256(bytes("B6PW_NEXTGEN_V1:Config"));
    bytes32 private constant ROLE = keccak256(bytes("B6PW_NEXTGEN_V1:OracleDirectory"));
    bytes32 private constant SPOT_ROLE = keccak256(bytes("B6PW_NEXTGEN_V1:Spot"));
    bytes32 private constant ETHUSD_ROLE = keccak256(bytes("B6PW_NEXTGEN_V1:ETHUSD"));

    address public immutable override config;
    uint256 private immutable _chainId;
    bytes32 private immutable _generationId;

    constructor(address config_) {
        if (config_ == address(0) || config_.code.length == 0) revert();
        (bool ok, bytes memory chainData) =
            config_.staticcall(abi.encodeWithSelector(IGenerationIdentity.chainId.selector));
        if (!ok || chainData.length != 32) revert();
        (bool generationOk, bytes memory generationData) =
            config_.staticcall(abi.encodeWithSelector(IGenerationIdentity.generationId.selector));
        if (!generationOk || generationData.length != 32) revert();
        (bool configOk, bytes memory configData) =
            config_.staticcall(abi.encodeWithSelector(IGenerationIdentity.config.selector));
        (bool roleOk, bytes memory roleData) =
            config_.staticcall(abi.encodeWithSelector(IGenerationIdentity.roleId.selector));
        if (
            !configOk || configData.length != 32 || abi.decode(configData, (address)) != config_ || !roleOk
                || roleData.length != 32 || abi.decode(roleData, (bytes32)) != CONFIG_ROLE
        ) revert();
        _chainId = abi.decode(chainData, (uint256));
        _generationId = abi.decode(generationData, (bytes32));
        if (_chainId == 0 || _generationId == bytes32(0)) revert();
        config = config_;
    }

    function chainId() external view override returns (uint256) {
        return _chainId;
    }

    function generationId() external view override returns (bytes32) {
        return _generationId;
    }

    function roleId() external pure override returns (bytes32) {
        return ROLE;
    }

    function readRegistration(bool useBackup) external view override returns (NG.OracleObservation memory observation) {
        (NG.OracleState memory state, bool active) = _activeState();
        if (!active) return _emptyRegistration(state, useBackup);
        NG.SourceRoute memory route = useBackup ? state.sources.backup : state.sources.primary;
        if (useBackup && !state.sources.backupEnabled) return _emptyRegistration(state, useBackup);

        NG.PriceQuote memory spot = _readSource(
            route.spot, route.spotCodeHash, route.spotRevision, route.spotRootId, SPOT_ROLE
        );
        NG.PriceQuote memory ethUsd = _readSource(
            route.ethUsd, route.ethUsdCodeHash, route.ethUsdRevision, route.ethUsdRootId, ETHUSD_ROLE
        );
        observation.spot = spot;
        observation.ethUsd = ethUsd;
        observation.sourceVersion = state.version;
        observation.sourceSetHash = state.sourceSetHash;
        observation.usedBackup = useBackup;
        observation.schemaVersion = state.evidenceSchemaVersion;
        observation.sourceTrustCommitment = state.sourceTrustCommitment;
        observation.routeIdentityHash = keccak256(
            abi.encode(state.directory, state.directoryCodeHash, state.sourceSetHash, route)
        );
        observation.chainId = _chainId;
        observation.generationId = _generationId;
        observation.config = config;
        observation.stakeLedger = IGovernanceConfig(config).coreBindings().stake;
        observation.sourceTrustEpoch = state.sourceTrustEpoch;
        if (spot.valid && ethUsd.valid && _mulDivFits(spot.price, ethUsd.price, 1e18)) {
            uint256 b6pwUsd = FullPrecisionMath.mulDiv(spot.price, ethUsd.price, 1e18);
            if (b6pwUsd != 0) {
                observation.b6pwUsd = NG.PriceQuote({
                    price: b6pwUsd,
                    decimals: 18,
                    valid: true,
                    observedAt: spot.observedAt < ethUsd.observedAt ? spot.observedAt : ethUsd.observedAt,
                    sourceRevision: spot.sourceRevision
                });
            }
        }
    }

    function readEthUsd(bool useBackup) external view override returns (NG.EthObservation memory observation) {
        (NG.OracleState memory state, bool active) = _activeState();
        if (!active || (useBackup && !state.sources.backupEnabled)) {
            observation.sourceVersion = state.version;
            observation.sourceSetHash = state.sourceSetHash;
            observation.usedBackup = useBackup;
            return observation;
        }
        NG.SourceRoute memory route = useBackup ? state.sources.backup : state.sources.primary;
        observation.ethUsd = _readSource(
            route.ethUsd, route.ethUsdCodeHash, route.ethUsdRevision, route.ethUsdRootId, ETHUSD_ROLE
        );
        observation.sourceVersion = state.version;
        observation.sourceSetHash = state.sourceSetHash;
        observation.usedBackup = useBackup;
    }

    function _activeState() private view returns (NG.OracleState memory state, bool active) {
        state = IGovernanceConfig(config).oracleState();
        active = state.directory == address(this) && state.directoryCodeHash == address(this).codehash
            && state.version != 0 && state.sourceSetHash != bytes32(0);
    }

    function _emptyRegistration(NG.OracleState memory state, bool useBackup)
        private
        view
        returns (NG.OracleObservation memory observation)
    {
        observation.sourceVersion = state.version;
        observation.sourceSetHash = state.sourceSetHash;
        observation.usedBackup = useBackup;
        observation.schemaVersion = state.evidenceSchemaVersion;
        observation.sourceTrustCommitment = state.sourceTrustCommitment;
        NG.SourceRoute memory route = useBackup ? state.sources.backup : state.sources.primary;
        observation.routeIdentityHash = keccak256(
            abi.encode(state.directory, state.directoryCodeHash, state.sourceSetHash, route)
        );
        observation.chainId = _chainId;
        observation.generationId = _generationId;
        observation.config = config;
        observation.stakeLedger = IGovernanceConfig(config).coreBindings().stake;
        observation.sourceTrustEpoch = state.sourceTrustEpoch;
    }

    function _readSource(
        address source, bytes32 expectedCodeHash, uint64 expectedRevision, bytes32 expectedRootId, bytes32 expectedRole
    )
        private
        view
        returns (NG.PriceQuote memory quote)
    {
        quote.decimals = 18;
        quote.sourceRevision = expectedRevision;
        if (
            source == address(0) || expectedCodeHash == bytes32(0) || expectedRevision == 0
                || source.codehash != expectedCodeHash || expectedRootId == bytes32(0)
        ) return quote;

        (bool descriptorOk, bytes memory descriptorData) = source.callView(
            abi.encodeWithSelector(IPriceSource.descriptor.selector), STATICCALL_GAS, MAX_SOURCE_RETURN_DATA
        );
        if (!descriptorOk || !_decodeDescriptor(descriptorData, descriptorOk)) return quote;
        NG.SourceDescriptor memory descriptor = _decodeDescriptorValue(descriptorData);
        if (
            descriptor.chainId != _chainId || descriptor.generationId != _generationId || descriptor.decimals != 18
                || descriptor.sourceRevision != expectedRevision || descriptor.bindingHash != expectedRootId
                || descriptor.sourceRootId != expectedRootId
                || !_roleMatches(descriptor, expectedRole)
        ) return quote;

        (bool priceOk, bytes memory priceData) =
            source.callView(abi.encodeWithSelector(IPriceSource.readPrice.selector), STATICCALL_GAS, 160);
        if (!priceOk || priceData.length != 160) return quote;
        (bool decoded, NG.PriceQuote memory decodedQuote) = _decodePrice(priceData);
        if (!decoded) return quote;
        quote = decodedQuote;
        if (quote.decimals != 18 || quote.sourceRevision != expectedRevision) {
            quote =
                NG.PriceQuote({price: 0, decimals: 18, valid: false, observedAt: 0, sourceRevision: expectedRevision});
            return quote;
        }
        if (!quote.valid || quote.price == 0 || quote.observedAt == 0 || quote.observedAt > block.timestamp) {
            quote.valid = false;
            quote.price = 0;
            quote.observedAt = 0;
        }
    }

    function _roleMatches(NG.SourceDescriptor memory descriptor, bytes32 expectedRole) private pure returns (bool) {
        if (expectedRole == SPOT_ROLE) {
            return descriptor.baseAsset == NG.Asset.B6PW && descriptor.quoteAsset == NG.Asset.ETH;
        }
        return
            expectedRole == ETHUSD_ROLE && descriptor.baseAsset == NG.Asset.ETH && descriptor.quoteAsset == NG.Asset.USD;
    }

    function _decodeDescriptor(bytes memory data, bool callOk) private pure returns (bool) {
        if (!callOk || data.length != 256) return false;
        uint256 baseAsset;
        uint256 quoteAsset;
        uint256 decimals_;
        uint256 revision;
        bytes32 rootId;
        assembly {
            baseAsset := mload(add(data, 0x60))
            quoteAsset := mload(add(data, 0x80))
            decimals_ := mload(add(data, 0xa0))
            revision := mload(add(data, 0xe0))
            rootId := mload(add(data, 0x100))
        }
        return baseAsset <= 2 && quoteAsset <= 2 && decimals_ <= type(uint8).max
            && revision <= type(uint64).max && rootId != bytes32(0);
    }

    function _decodeDescriptorValue(bytes memory data) private pure returns (NG.SourceDescriptor memory descriptor) {
        uint256 rawBase;
        uint256 rawQuote;
        uint256 rawDecimals;
        uint256 rawRevision;
        uint256 chain;
        bytes32 generation;
        bytes32 binding;
        bytes32 rootId;
        assembly {
            chain := mload(add(data, 0x20))
            generation := mload(add(data, 0x40))
            rawBase := mload(add(data, 0x60))
            rawQuote := mload(add(data, 0x80))
            rawDecimals := mload(add(data, 0xa0))
            binding := mload(add(data, 0xc0))
            rawRevision := mload(add(data, 0xe0))
            rootId := mload(add(data, 0x100))
        }
        descriptor = NG.SourceDescriptor({
            chainId: chain,
            generationId: generation,
            baseAsset: NG.Asset(rawBase),
            quoteAsset: NG.Asset(rawQuote),
            decimals: uint8(rawDecimals),
            bindingHash: binding,
            sourceRevision: uint64(rawRevision),
            sourceRootId: rootId
        });
    }

    function _decodePrice(bytes memory data) private pure returns (bool decoded, NG.PriceQuote memory quote) {
        if (data.length != 160) return (false, quote);
        uint256 rawPrice;
        uint256 rawDecimals;
        uint256 rawValid;
        uint256 rawObservedAt;
        uint256 rawRevision;
        assembly {
            rawPrice := mload(add(data, 0x20))
            rawDecimals := mload(add(data, 0x40))
            rawValid := mload(add(data, 0x60))
            rawObservedAt := mload(add(data, 0x80))
            rawRevision := mload(add(data, 0xa0))
        }
        if (rawDecimals > type(uint8).max || rawValid > 1 || rawRevision > type(uint64).max) return (false, quote);
        quote.decimals = uint8(rawDecimals);
        quote.valid = rawValid == 1;
        quote.price = rawPrice;
        quote.observedAt = rawObservedAt;
        quote.sourceRevision = uint64(rawRevision);
        decoded = true;
    }

    function _mulDivFits(uint256 x, uint256 y, uint256 denominator) private pure returns (bool) {
        if (denominator == 0) return false;
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(x, y, not(0))
            prod0 := mul(x, y)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        return prod1 < denominator;
    }
}
