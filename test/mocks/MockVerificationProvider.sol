// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVerificationProvider} from "../../src/interfaces/IVerificationProvider.sol";

/// @notice Mock provider where tiers can be set manually for testing
contract MockVerificationProvider is IVerificationProvider {
    mapping(address => uint256) public userTiers;
    mapping(address => bool) public userVerified;

    function setUser(address user, uint256 tier, bool verified) external {
        userTiers[user] = tier;
        userVerified[user] = verified;
    }

    function verify(address user) external view override returns (VerificationResult memory result) {
        result.verified = userVerified[user];
        result.tier = userTiers[user];
        result.expiry = 0;
        result.attestationId = bytes32(0);
        result.providerName = "mock";
    }

    function providerId() external pure override returns (bytes32) {
        return keccak256("mock");
    }

    function providerName() external pure override returns (string memory) {
        return "Mock Provider";
    }

    function supportsType(bytes32) external pure override returns (bool) {
        return true;
    }
}
