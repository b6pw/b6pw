pragma solidity 0.8.24;

import {NG} from "./NextGenTypes.sol";
import {IGenerationIdentity} from "./IGenerationIdentity.sol";

interface ICustody is IGenerationIdentity {
    function ownershipCore() external view returns (address);
    function settlementKernel() external view returns (address);
    function platformAccounting() external view returns (address);
    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function proposeAdmin(address proposed) external;
    function acceptAdmin() external;
    function setDescription(string calldata id, string calldata description) external;
    function setResolution(string calldata id, string calldata resolution) external;
    function list(NG.ListRequest calldata request) external;
    function cancelListing(string calldata id, uint256 expectedNonce, bytes32 expectedListingId) external;
    function directTransfer(NG.DirectRequest calldata request) external payable;
    receive() external payable;
}
