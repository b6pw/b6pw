pragma solidity 0.8.24;

import {NG} from "./NextGenTypes.sol";
import {IGenerationIdentity} from "./IGenerationIdentity.sol";

interface ISettlementKernel is IGenerationIdentity {
    function getListing(string calldata id) external view returns (NG.Listing memory);
    function previewListing(uint256 priceWei) external view
        returns (uint256 feeWei, uint256 minimumFeeWei, uint256 oracleVersion, uint256 marketVersion);
    function previewDirectFee() external view returns (uint256 feeWei, uint256 oracleVersion);
    function list(NG.ListRequest calldata request) external returns (bytes32 listingId);
    function cancelListing(string calldata id, uint256 expectedNonce, bytes32 expectedListingId) external;
    function buy(NG.BuyRequest calldata request) external payable;
    function directTransfer(NG.DirectRequest calldata request) external payable;
    function protocolFeeClaimable(address beneficiary) external view returns (uint256);
    function totalProtocolFeeLiability() external view returns (uint256);
    function claimProtocolFees(address to) external;
}
