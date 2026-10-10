pragma solidity 0.8.24;

import {IGenerationIdentity} from "../interfaces/IGenerationIdentity.sol";
import {IGovernanceConfig} from "../interfaces/IGovernanceConfig.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {ISpotSourceBinding} from "../interfaces/ISpotSourceBinding.sol";
import {NG} from "../interfaces/NextGenTypes.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import {FullPrecisionMath} from "../libraries/FullPrecisionMath.sol";
import {SourceBindingHash} from "../libraries/SourceBindingHash.sol";

interface IV4StateViewNG {
    function poolManager() external view returns (address);
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

interface IERC20DecimalsNG {
    function decimals() external view returns (uint8);
}

/// @notice Immutable, spot-only ETH/B6PW source for the configured pool.
/// @dev This source intentionally has no historical read, writer, or
///      manually supplied price path.
contract B6PWSpotSourceNG is IPriceSource, ISpotSourceBinding {
    using BoundedStaticCall for address;

    uint256 private constant STATICCALL_GAS = 120_000;
    uint160 private constant MIN_SQRT_PRICE_X96 = 1;
    uint160 private constant MAX_SQRT_PRICE_X96 = type(uint160).max;
    int24 private constant MIN_TICK = -887_272;
    int24 private constant MAX_TICK = 887_272;
    uint256 private constant Q192 = 2 ** 192;
    bytes32 private constant CONFIG_ROLE = keccak256(bytes("B6PW_NEXTGEN_V1:Config"));
    bytes32 private constant ROLE = keccak256(bytes("B6PW_NEXTGEN_V1:Spot"));

    address public immutable override config;
    uint256 private immutable _chainId;
    bytes32 private immutable _generationId;
    address internal immutable poolManager;
    address internal immutable stateView;
    bytes32 internal immutable poolId;
    address internal immutable b6pwToken;
    address internal immutable currency0;
    address internal immutable currency1;
    uint24 internal immutable fee;
    int24 internal immutable tickSpacing;
    address internal immutable hooks;
    uint128 internal immutable minLiquidity;
    uint256 internal immutable minPrice;
    uint256 internal immutable maxPrice;

    constructor(address config_, NG.SpotInputs memory inputs) {
        if (config_ == address(0) || config_.code.length == 0) revert();
        if (
            inputs.poolManager == address(0) || inputs.stateView == address(0) || inputs.poolId == bytes32(0)
                || inputs.currency0 != address(0) || inputs.currency1 == address(0) || inputs.tickSpacing <= 0
                || inputs.minLiquidity == 0 || inputs.minPrice == 0 || inputs.maxPrice < inputs.minPrice
                || inputs.poolId
                    != keccak256(
                        abi.encode(inputs.currency0, inputs.currency1, inputs.fee, inputs.tickSpacing, inputs.hooks)
                    )
        ) revert();
        if (inputs.poolManager.code.length == 0 || inputs.stateView.code.length == 0) revert();

        (uint256 chainId_, bytes32 generationId_) = _configIdentity(config_);
        address configuredToken = _configuredToken(config_);
        if (configuredToken != inputs.currency1 || configuredToken.code.length == 0) revert();
        _checkTokenDecimals(configuredToken);
        _checkStateView(inputs.stateView, inputs.poolManager);

        config = config_;
        _chainId = chainId_;
        _generationId = generationId_;
        poolManager = inputs.poolManager;
        stateView = inputs.stateView;
        poolId = inputs.poolId;
        b6pwToken = configuredToken;
        currency0 = inputs.currency0;
        currency1 = inputs.currency1;
        fee = inputs.fee;
        tickSpacing = inputs.tickSpacing;
        hooks = inputs.hooks;
        minLiquidity = inputs.minLiquidity;
        minPrice = inputs.minPrice;
        maxPrice = inputs.maxPrice;
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

    function spotBinding() external view override returns (NG.SpotBinding memory binding) {
        binding = NG.SpotBinding({
            config: config,
            b6pwToken: b6pwToken,
            poolManager: poolManager,
            stateView: stateView,
            poolId: poolId,
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks,
            minLiquidity: minLiquidity,
            minPrice: minPrice,
            maxPrice: maxPrice
        });
    }

    function descriptor() external view override returns (NG.SourceDescriptor memory sourceDescriptor) {
        bytes32 rootId = _sourceRootId();
        sourceDescriptor = NG.SourceDescriptor({
            chainId: _chainId,
            generationId: _generationId,
            baseAsset: NG.Asset.B6PW,
            quoteAsset: NG.Asset.ETH,
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
            baseAsset: NG.Asset.B6PW,
            quoteAsset: NG.Asset.ETH,
            decimals: 18,
            bindingHash: bytes32(0),
            sourceRevision: 1,
            sourceRootId: bytes32(0)
        });
        NG.SpotBinding memory binding = NG.SpotBinding({
            config: config,
            b6pwToken: b6pwToken,
            poolManager: poolManager,
            stateView: stateView,
            poolId: poolId,
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks,
            minLiquidity: minLiquidity,
            minPrice: minPrice,
            maxPrice: maxPrice
        });
        bytes32 dependenciesHash = keccak256(abi.encode(
            poolManager.codehash,
            stateView.codehash,
            hooks == address(0) ? bytes32(0) : hooks.codehash
        ));
        return SourceBindingHash.spotRoot(sourceDescriptor, binding, dependenciesHash);
    }

    function readPrice() external view override returns (NG.PriceQuote memory quote) {
        quote.decimals = 18;
        quote.sourceRevision = 1;
        (bool slotOk, bytes memory slotData) =
            stateView.callView(abi.encodeWithSelector(IV4StateViewNG.getSlot0.selector, poolId), STATICCALL_GAS, 128);
        if (!slotOk || slotData.length != 128) return quote;
        uint256 rawSqrtPrice;
        int256 rawTick;
        assembly {
            rawSqrtPrice := mload(add(slotData, 0x20))
            rawTick := mload(add(slotData, 0x40))
        }
        if (rawSqrtPrice > type(uint160).max || rawTick < MIN_TICK || rawTick > MAX_TICK) {
            return quote;
        }
        uint160 sqrtPriceX96 = uint160(rawSqrtPrice);
        int24 tick = int24(rawTick);

        (bool liquidityOk, bytes memory liquidityData) =
            stateView.callView(abi.encodeWithSelector(IV4StateViewNG.getLiquidity.selector, poolId), STATICCALL_GAS, 32);
        if (!liquidityOk || liquidityData.length != 32) return quote;
        uint256 rawLiquidity;
        assembly {
            rawLiquidity := mload(add(liquidityData, 0x20))
        }
        if (rawLiquidity > type(uint128).max) return quote;
        uint128 liquidity = uint128(rawLiquidity);
        if (
            sqrtPriceX96 < MIN_SQRT_PRICE_X96 || sqrtPriceX96 > MAX_SQRT_PRICE_X96 || tick < MIN_TICK || tick > MAX_TICK
                || liquidity < minLiquidity
        ) return quote;

        uint256 ethPerB6PW = _ethPerB6PW(sqrtPriceX96);
        if (ethPerB6PW == 0 || ethPerB6PW < minPrice || ethPerB6PW > maxPrice) return quote;
        quote.price = ethPerB6PW;
        quote.valid = true;
        quote.observedAt = block.timestamp;
    }

    function _ethPerB6PW(uint160 sqrtPriceX96) private pure returns (uint256) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        if (sqrtPrice > type(uint128).max) return 0;
        uint256 square = sqrtPrice * sqrtPrice;
        return FullPrecisionMath.mulDiv(Q192, 1e18, square);
    }

    function _configIdentity(address config_) private view returns (uint256 chainId_, bytes32 generationId_) {
        (bool chainOk, bytes memory chainData) =
            config_.staticcall(abi.encodeWithSelector(IGenerationIdentity.chainId.selector));
        (bool generationOk, bytes memory generationData) =
            config_.staticcall(abi.encodeWithSelector(IGenerationIdentity.generationId.selector));
        (bool configOk, bytes memory configData) =
            config_.staticcall(abi.encodeWithSelector(IGenerationIdentity.config.selector));
        (bool roleOk, bytes memory roleData) =
            config_.staticcall(abi.encodeWithSelector(IGenerationIdentity.roleId.selector));
        if (
            !chainOk || chainData.length != 32 || !generationOk || generationData.length != 32 || !configOk
                || configData.length != 32 || abi.decode(configData, (address)) != config_ || !roleOk
                || roleData.length != 32 || abi.decode(roleData, (bytes32)) != CONFIG_ROLE
        ) revert();
        chainId_ = abi.decode(chainData, (uint256));
        generationId_ = abi.decode(generationData, (bytes32));
        if (chainId_ == 0 || generationId_ == bytes32(0)) revert();
    }

    function _configuredToken(address config_) private view returns (address configuredToken) {
        (bool ok, bytes memory data) = config_.staticcall(abi.encodeWithSelector(IGovernanceConfig.token.selector));
        if (!ok || data.length != 32) revert();
        configuredToken = abi.decode(data, (address));
    }

    function _checkTokenDecimals(address token_) private view {
        (bool ok, bytes memory data) =
            token_.callView(abi.encodeWithSelector(IERC20DecimalsNG.decimals.selector), STATICCALL_GAS, 32);
        if (!ok || data.length != 32 || abi.decode(data, (uint8)) != 18) revert();
    }

    function _checkStateView(address stateView_, address poolManager_) private view {
        (bool ok, bytes memory data) =
            stateView_.callView(abi.encodeWithSelector(IV4StateViewNG.poolManager.selector), STATICCALL_GAS, 32);
        if (!ok || data.length != 32 || abi.decode(data, (address)) != poolManager_) revert();
    }
}
