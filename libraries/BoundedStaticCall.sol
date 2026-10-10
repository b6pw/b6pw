pragma solidity 0.8.24;

library BoundedStaticCall {
    function callView(
        address target,
        bytes memory callData,
        uint256 gasLimit,
        uint256 maxReturnData
    ) internal view returns (bool success, bytes memory returnData) {
        if (target == address(0) || target.code.length == 0 || gasLimit == 0) {
            success = false;
            returnData = new bytes(0);
            return (success, returnData);
        }
        if (callData.length > type(uint32).max || maxReturnData > type(uint32).max) {
            success = false;
            returnData = new bytes(0);
            return (success, returnData);
        }

        assembly {
            let dataPtr := add(callData, 0x20)
            let dataLength := mload(callData)
            let ok := staticcall(gasLimit, target, dataPtr, dataLength, 0, 0)
            let returnSize := returndatasize()
            if gt(returnSize, maxReturnData) {
                ok := 0
                returnSize := 0
            }

            returnData := mload(0x40)
            mstore(returnData, returnSize)
            returndatacopy(add(returnData, 0x20), 0, returnSize)
            mstore(0x40, add(add(returnData, 0x20), and(add(returnSize, 0x1f), not(0x1f))))
            success := ok
        }
    }
}
