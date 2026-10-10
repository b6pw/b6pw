pragma solidity 0.8.24;

import {NG} from "./NextGenTypes.sol";
import {IGenerationIdentity} from "./IGenerationIdentity.sol";

interface IOracleDirectory is IGenerationIdentity {
    function readRegistration(bool useBackup) external view returns (NG.OracleObservation memory);
    function readEthUsd(bool useBackup) external view returns (NG.EthObservation memory);
}
