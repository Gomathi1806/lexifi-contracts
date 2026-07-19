// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IVerificationProvider
/// @notice Standardized interface for identity/compliance verification providers.
/// @dev Lexifi supports multiple providers (Coinbase EAS, Worldcoin, ZK-proofs).
///      Each provider implements this interface so policies can query them uniformly.
interface IVerificationProvider {
    /// @notice Verification status for a user
    struct VerificationResult {
        bool verified;           // Whether the user passed verification
        uint256 tier;            // Provider-specific tier (maps to AccessLevel)
        uint256 expiry;          // When the verification expires (0 = no expiry)
        bytes32 attestationId;   // Reference to the on-chain attestation (if any)
        string providerName;     // e.g. "coinbase", "worldcoin", "zkpass"
    }

    /// @notice Check if a user has a valid verification
    /// @param user The wallet to check
    /// @return result The verification details
    function verify(address user) external view returns (VerificationResult memory result);

    /// @notice The provider's unique identifier
    function providerId() external view returns (bytes32);

    /// @notice Human-readable provider name
    function providerName() external view returns (string memory);

    /// @notice Whether this provider supports a given verification type
    /// @param verificationType Keccak hash of type string (e.g. keccak256("KYC"), keccak256("ACCREDITED"))
    function supportsType(bytes32 verificationType) external view returns (bool);
}
