// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {NG} from "./NextGenTypes.sol";

interface ISpotSourceBinding {
    function spotBinding() external view returns (NG.SpotBinding memory);
}
