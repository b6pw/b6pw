// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {NG} from "../interfaces/NextGenTypes.sol";

library SourceBindingHash {
    bytes32 internal constant SPOT_DOMAIN = keccak256("B6PW_NG_SPOT_BINDING_V2");
    bytes32 internal constant ETHUSD_DOMAIN = keccak256("B6PW_NG_ETHUSD_BINDING_V2");
    bytes32 internal constant SPOT_ROLE = keccak256("B6PW_NEXTGEN_V1:Spot");
    bytes32 internal constant ETHUSD_ROLE = keccak256("B6PW_NEXTGEN_V1:ETHUSD");

    struct SpotInput {
        bytes32 domain;
        uint256 chainId;
        bytes32 generationId;
        address config;
        address source;
        bytes32 sourceCodeHash;
        bytes32 role;
        NG.Asset baseAsset;
        NG.Asset quoteAsset;
        uint8 decimals;
        uint64 sourceRevision;
        address b6pwToken;
        address poolManager;
        bytes32 poolManagerCodeHash;
        address stateView;
        bytes32 stateViewCodeHash;
        bytes32 poolId;
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes32 hooksCodeHash;
        uint128 minLiquidity;
        uint256 minPrice;
        uint256 maxPrice;
    }

    struct EthUsdInput {
        bytes32 domain;
        uint256 chainId;
        bytes32 generationId;
        address config;
        address source;
        bytes32 sourceCodeHash;
        bytes32 role;
        NG.Asset baseAsset;
        NG.Asset quoteAsset;
        uint8 decimals;
        uint64 sourceRevision;
        address feed;
        bytes32 feedCodeHash;
        uint8 feedDecimals;
    }

    function spot(SpotInput memory input) internal pure returns (bytes32) {
        return keccak256(abi.encode(input));
    }

    function ethUsd(EthUsdInput memory input) internal pure returns (bytes32) {
        return keccak256(abi.encode(input));
    }

    function spotRoot(NG.SourceDescriptor memory descriptor, NG.SpotBinding memory binding, bytes32 dependenciesHash)
        internal
        pure
        returns (bytes32)
    {
        bytes32 identityHash = keccak256(abi.encode(
            descriptor.chainId,
            descriptor.generationId,
            descriptor.baseAsset,
            descriptor.quoteAsset,
            descriptor.decimals,
            descriptor.sourceRevision,
            binding.config
        ));
        return keccak256(abi.encode(SPOT_DOMAIN, identityHash, keccak256(abi.encode(binding)), dependenciesHash));
    }

    function ethUsdRoot(
        NG.SourceDescriptor memory descriptor, NG.EthUsdBinding memory binding, bytes32 dependenciesHash
    )
        internal
        pure
        returns (bytes32)
    {
        bytes32 identityHash = keccak256(abi.encode(
            descriptor.chainId,
            descriptor.generationId,
            descriptor.baseAsset,
            descriptor.quoteAsset,
            descriptor.decimals,
            descriptor.sourceRevision,
            binding.config
        ));
        return keccak256(abi.encode(ETHUSD_DOMAIN, identityHash, keccak256(abi.encode(binding)), dependenciesHash));
    }
}
