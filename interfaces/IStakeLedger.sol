pragma solidity 0.8.24;

import {NG} from "./NextGenTypes.sol";
import {IGenerationIdentity} from "./IGenerationIdentity.sol";

interface IStakeLedger is IGenerationIdentity {
    function token() external view returns (address);
    function stakeOf(bytes32 idHash_) external view returns (NG.StakeRecord memory);
    function claimableOf(address beneficiary) external view returns (uint256);
    function totalActiveStake() external view returns (uint256);
    function totalClaimableStake() external view returns (uint256);
    /// @dev Reads the active QuotePolicy candidate through the fixed-core boundary.
    function previewQuote() external view returns (NG.StakeQuote memory);
    function lastValidQuote() external view returns (NG.StakeQuote memory);
    function lastValidEvidence() external view returns (NG.PriceEvidence memory);
    /// @dev Callable by anyone; only a freshly validated current quote may be persisted.
    function acceptCurrentQuote() external returns (NG.StakeQuote memory);
    function register(string calldata id, uint256 expectedRequiredStake, uint256 maxStake,
        uint256 deadline, bytes32 expectedQuoteVersion) external;
    function registerWithMetadata(string calldata id, string calldata description,
        string calldata resolution, uint256 expectedRequiredStake, uint256 maxStake,
        uint256 deadline, bytes32 expectedQuoteVersion) external;
    function completeStake(string calldata id, uint256 expectedRequiredStake, uint256 maxStake,
        uint256 deadline, bytes32 expectedQuoteVersion) external;
    function unstake(string calldata id, address to) external;
    function claimOldStake(address to) external;
    function creditOldStake(bytes32 idHash_, address expectedOwner, uint256 expectedNonce) external;
}
