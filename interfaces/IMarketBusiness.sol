pragma solidity 0.8.24;

import {NG} from "./NextGenTypes.sol";
import {IGenerationIdentity} from "./IGenerationIdentity.sol";

interface IMarketBusiness is IGenerationIdentity {
    function calculateSaleFee(NG.FeeContext calldata context) external view returns (uint256 feeWei);
}
