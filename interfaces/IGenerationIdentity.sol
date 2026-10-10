pragma solidity 0.8.24;

interface IGenerationIdentity {
    function chainId() external view returns (uint256);
    function generationId() external view returns (bytes32);
    function config() external view returns (address);
    function roleId() external pure returns (bytes32);
}
