pragma solidity 0.8.24;

import {IGenerationIdentity} from "../interfaces/IGenerationIdentity.sol";
import {IGovernanceConfig} from "../interfaces/IGovernanceConfig.sol";
import {IMarketBusiness} from "../interfaces/IMarketBusiness.sol";
import "../interfaces/NextGenErrors.sol";
import {NG} from "../interfaces/NextGenTypes.sol";

/// @notice Read-only sale-fee candidate module for the NextGen SettlementKernel.
/// @dev This contract never receives value, writes ownership, or approves assets.
contract B6PWMarketBusinessNG is IMarketBusiness {
    uint256 private constant BPS_DENOMINATOR = 10_000;

    uint256 private immutable _chainId;
    bytes32 private immutable _generationId;
    address private immutable _config;

    constructor(address config_) {
        if (config_ == address(0) || config_.code.length == 0) {
            revert InvalidConfiguration();
        }

        IGovernanceConfig configContract = IGovernanceConfig(config_);
        uint256 configuredChainId = configContract.chainId();
        if (configuredChainId != block.chainid) revert WrongChain();

        _chainId = configuredChainId;
        _generationId = configContract.generationId();
        if (_generationId == bytes32(0) || configContract.config() != config_) {
            revert InvalidConfiguration();
        }
        _config = config_;
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
        return keccak256(bytes("B6PW_NEXTGEN_V1:MarketBusiness"));
    }

    /// @inheritdoc IMarketBusiness
    function calculateSaleFee(NG.FeeContext calldata context)
        external
        view
        override
        returns (uint256 feeWei)
    {
        if (context.priceWei == 0 || context.minimumFeeWei > context.priceWei) {
            revert FeeBounds();
        }
        if (context.feeBps > BPS_DENOMINATOR) revert FeeBounds();

        uint256 percentageFee;
        if (context.feeBps != 0) {
            if (context.priceWei > type(uint256).max / context.feeBps) {
                revert FeeBounds();
            }
            percentageFee = (context.priceWei * context.feeBps) / BPS_DENOMINATOR;
        }

        feeWei = percentageFee >= context.minimumFeeWei
            ? percentageFee
            : context.minimumFeeWei;
        if (feeWei > context.priceWei) revert FeeBounds();
    }
}
