pragma solidity 0.8.24;

import {IGenerationIdentity} from "../interfaces/IGenerationIdentity.sol";
import {IEthUsdSourceBinding} from "../interfaces/IEthUsdSourceBinding.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {NG} from "../interfaces/NextGenTypes.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import {SourceBindingHash} from "../libraries/SourceBindingHash.sol";

interface IChainlinkAggregatorV3NG {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Immutable Chainlink ETH/USD wrapper that always exposes an 18
///         decimal quote. Freshness is intentionally enforced by the core
///         policy consumer, not by a hidden adapter cache.
contract B6PWChainlinkETHUSDAdapterNG is IPriceSource, IEthUsdSourceBinding {
    using BoundedStaticCall for address;

    uint8 internal constant MAX_SUPPORTED_FEED_DECIMALS = 36;
    uint256 private constant STATICCALL_GAS = 120_000;
    bytes32 private constant CONFIG_ROLE = keccak256(bytes("B6PW_NEXTGEN_V1:Config"));
    bytes32 private constant ROLE = keccak256(bytes("B6PW_NEXTGEN_V1:ETHUSD"));

    address public immutable override config;
    uint256 private immutable _chainId;
    bytes32 private immutable _generationId;
    address internal immutable feed;
    uint8 internal immutable feedDecimals;

    constructor(address config_, address feed_) {
        if (config_ == address(0) || config_.code.length == 0 || feed_ == address(0) || feed_.code.length == 0) {
            revert();
        }
        (bool chainOk, bytes memory chainData) =
            config_.staticcall(abi.encodeWithSelector(IGenerationIdentity.chainId.selector));
        (bool generationOk, bytes memory generationData) =
            config_.staticcall(abi.encodeWithSelector(IGenerationIdentity.generationId.selector));
        if (!chainOk || chainData.length != 32 || !generationOk || generationData.length != 32) revert();
        (bool configOk, bytes memory configData) =
            config_.staticcall(abi.encodeWithSelector(IGenerationIdentity.config.selector));
        (bool roleOk, bytes memory roleData) =
            config_.staticcall(abi.encodeWithSelector(IGenerationIdentity.roleId.selector));
        if (
            !configOk || configData.length != 32 || abi.decode(configData, (address)) != config_ || !roleOk
                || roleData.length != 32 || abi.decode(roleData, (bytes32)) != CONFIG_ROLE
        ) revert();
        (bool decimalsOk, bytes memory decimalsData) =
            feed_.callView(abi.encodeWithSelector(IChainlinkAggregatorV3NG.decimals.selector), STATICCALL_GAS, 32);
        if (!decimalsOk || decimalsData.length != 32) revert();
        uint8 decimals_ = abi.decode(decimalsData, (uint8));
        if (decimals_ > MAX_SUPPORTED_FEED_DECIMALS) revert();

        config = config_;
        _chainId = abi.decode(chainData, (uint256));
        _generationId = abi.decode(generationData, (bytes32));
        if (_chainId == 0 || _generationId == bytes32(0)) revert();
        feed = feed_;
        feedDecimals = decimals_;
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

    function ethUsdBinding() external view override returns (NG.EthUsdBinding memory binding) {
        binding = NG.EthUsdBinding({config: config, feed: feed, feedDecimals: feedDecimals});
    }

    function descriptor() external view override returns (NG.SourceDescriptor memory sourceDescriptor) {
        bytes32 rootId = _sourceRootId();
        sourceDescriptor = NG.SourceDescriptor({
            chainId: _chainId,
            generationId: _generationId,
            baseAsset: NG.Asset.ETH,
            quoteAsset: NG.Asset.USD,
            decimals: 18,
            bindingHash: rootId,
            sourceRevision: 1,
            sourceRootId: rootId
        });
    }

    function _sourceRootId() private view returns (bytes32) {
        NG.SourceDescriptor memory sourceDescriptor = NG.SourceDescriptor({
            chainId: _chainId,
            generationId: _generationId,
            baseAsset: NG.Asset.ETH,
            quoteAsset: NG.Asset.USD,
            decimals: 18,
            bindingHash: bytes32(0),
            sourceRevision: 1,
            sourceRootId: bytes32(0)
        });
        NG.EthUsdBinding memory binding = NG.EthUsdBinding({config: config, feed: feed, feedDecimals: feedDecimals});
        bytes32 dependenciesHash = keccak256(abi.encode(feed.codehash, feedDecimals));
        return SourceBindingHash.ethUsdRoot(sourceDescriptor, binding, dependenciesHash);
    }

    function readPrice() external view override returns (NG.PriceQuote memory quote) {
        quote.decimals = 18;
        quote.sourceRevision = 1;
        (bool decimalsOk, bytes memory decimalsData) =
            feed.callView(abi.encodeWithSelector(IChainlinkAggregatorV3NG.decimals.selector), STATICCALL_GAS, 32);
        uint256 rawDecimals;
        if (decimalsOk && decimalsData.length == 32) {
            assembly {
                rawDecimals := mload(add(decimalsData, 0x20))
            }
        }
        if (!decimalsOk || decimalsData.length != 32 || rawDecimals != feedDecimals) {
            return quote;
        }

        (bool roundOk, bytes memory roundData) = feed.callView(
            abi.encodeWithSelector(IChainlinkAggregatorV3NG.latestRoundData.selector), STATICCALL_GAS, 160
        );
        if (!roundOk || roundData.length != 160) return quote;
        uint256 rawRoundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint256 rawAnsweredInRound;
        assembly {
            rawRoundId := mload(add(roundData, 0x20))
            answer := mload(add(roundData, 0x40))
            startedAt := mload(add(roundData, 0x60))
            updatedAt := mload(add(roundData, 0x80))
            rawAnsweredInRound := mload(add(roundData, 0xa0))
        }
        if (rawRoundId > type(uint80).max || rawAnsweredInRound > type(uint80).max) return quote;
        uint80 roundId = uint80(rawRoundId);
        uint80 answeredInRound = uint80(rawAnsweredInRound);
        if (
            roundId == 0 || answeredInRound < roundId || answer <= 0 || startedAt == 0 || updatedAt == 0
                || startedAt > updatedAt || updatedAt > block.timestamp
        ) return quote;

        uint256 normalized = _normalize(uint256(answer), feedDecimals);
        if (normalized == 0) return quote;
        quote.price = normalized;
        quote.observedAt = updatedAt;
        quote.valid = true;
    }

    function _normalize(uint256 value, uint8 decimals_) private pure returns (uint256) {
        if (decimals_ == 18) return value;
        if (decimals_ < 18) {
            uint256 scale = 10 ** (18 - decimals_);
            if (value > type(uint256).max / scale) return 0;
            return value * scale;
        }
        return value / (10 ** (decimals_ - 18));
    }
}
