pragma solidity 0.8.24;

import {NG} from "./NextGenTypes.sol";
import {IGenerationIdentity} from "./IGenerationIdentity.sol";

interface IPriceSource is IGenerationIdentity {
    function descriptor() external view returns (NG.SourceDescriptor memory);
    function readPrice() external view returns (NG.PriceQuote memory);
}
