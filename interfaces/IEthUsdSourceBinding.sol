// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {NG} from "./NextGenTypes.sol";

interface IEthUsdSourceBinding {
    function ethUsdBinding() external view returns (NG.EthUsdBinding memory);
}
