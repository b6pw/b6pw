pragma solidity 0.8.24;

import {NG} from "./NextGenTypes.sol";
import {IGenerationIdentity} from "./IGenerationIdentity.sol";

interface IQuotePolicyHub is IGenerationIdentity {
    /// @dev Stateless candidate calculation. Asset, ownership and liability writes are forbidden.
    function previewQuote() external view returns (NG.StakeQuote memory);
    /// @dev Reprices Core-owned raw evidence under this module's current formula/version.
    function previewQuoteFromEvidence(NG.PriceEvidence calldata evidence) external view returns (NG.StakeQuote memory);
}
