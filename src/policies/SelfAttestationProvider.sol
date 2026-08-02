// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVerificationProvider} from "../interfaces/IVerificationProvider.sol";

/// @title SelfAttestationProvider
/// @notice Verification provider where the operator registers user KYC tiers on-chain.
/// @dev For DEX operators who verify users off-chain (their own KYC/AML process)
///      then stamp wallets on-chain. Works alongside CoinbaseEASProvider to give
///      InstitutionalPolicy its second provider for N-of-M verification.
contract SelfAttestationProvider is IVerificationProvider {
    struct Attestation {
        uint256 tier;
        uint256 expiry;       // 0 = no expiry
        uint256 attestedAt;
        bool active;
    }

    mapping(address => Attestation) public attestations;

    address public owner;
    string public operatorName;

    event UserAttested(address indexed user, uint256 tier, uint256 expiry);
    event UserRevoked(address indexed user);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    error Unauthorized();
    error ZeroAddress();

    constructor(address _owner, string memory _operatorName) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        operatorName = _operatorName;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ═══════════════════════════════════════════
    //  IVerificationProvider
    // ═══════════════════════════════════════════

    function verify(
        address user
    ) external view override returns (VerificationResult memory result) {
        Attestation memory att = attestations[user];
        result.providerName = operatorName;

        if (!att.active) {
            return result;
        }

        if (att.expiry != 0 && att.expiry < block.timestamp) {
            return result;
        }

        result.verified = true;
        result.tier = att.tier;
        result.expiry = att.expiry;
        result.attestationId = keccak256(abi.encodePacked(user, att.attestedAt));
    }

    function providerId() external view override returns (bytes32) {
        return keccak256(abi.encodePacked("self-attestation-", operatorName));
    }

    function providerName() external view override returns (string memory) {
        return operatorName;
    }

    function supportsType(
        bytes32 verificationType
    ) external pure override returns (bool) {
        bytes32 TYPE_KYC = keccak256("KYC");
        bytes32 TYPE_ACCREDITED = keccak256("ACCREDITED");
        return verificationType == TYPE_KYC || verificationType == TYPE_ACCREDITED;
    }

    // ═══════════════════════════════════════════
    //  ATTESTATION MANAGEMENT
    // ═══════════════════════════════════════════

    /// @notice Attest a single user's verification tier
    /// @param user The wallet to attest
    /// @param tier Access level (1=Retail, 2=Accredited, 3=Institutional)
    /// @param expiry Unix timestamp when attestation expires (0 = never)
    function attest(address user, uint256 tier, uint256 expiry) external onlyOwner {
        if (user == address(0)) revert ZeroAddress();

        attestations[user] = Attestation({
            tier: tier,
            expiry: expiry,
            attestedAt: block.timestamp,
            active: true
        });

        emit UserAttested(user, tier, expiry);
    }

    /// @notice Attest multiple users in a single transaction
    function attestBatch(
        address[] calldata users,
        uint256[] calldata tiers,
        uint256[] calldata expiries
    ) external onlyOwner {
        require(
            users.length == tiers.length && users.length == expiries.length,
            "length mismatch"
        );

        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) revert ZeroAddress();

            attestations[users[i]] = Attestation({
                tier: tiers[i],
                expiry: expiries[i],
                attestedAt: block.timestamp,
                active: true
            });

            emit UserAttested(users[i], tiers[i], expiries[i]);
        }
    }

    /// @notice Revoke a user's attestation
    function revoke(address user) external onlyOwner {
        attestations[user].active = false;
        emit UserRevoked(user);
    }

    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
