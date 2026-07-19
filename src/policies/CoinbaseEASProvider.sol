// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVerificationProvider} from "../interfaces/IVerificationProvider.sol";

/// @dev EAS Indexer: maps (recipient, schemaId) -> attestation UID
interface IEASIndexer {
    function getAttestationUid(
        address recipient,
        bytes32 schemaId
    ) external view returns (bytes32);
}

/// @dev EAS: reads attestation data
interface IEAS {
    struct Attestation {
        bytes32 uid;
        bytes32 schema;
        uint64 time;
        uint64 expirationTime;
        uint64 revocationTime;
        bytes32 refUID;
        address attester;
        address recipient;
        bool revocable;
        bytes data;
    }

    function getAttestation(bytes32 uid) external view returns (Attestation memory);
}

/// @title CoinbaseEASProvider
/// @notice Verification provider that reads Coinbase Verifications via EAS on Base.
contract CoinbaseEASProvider is IVerificationProvider {
    IEAS public immutable eas;
    IEASIndexer public immutable indexer;
    address public immutable coinbaseAttester;

    bytes32 public constant SCHEMA_ACCOUNT =
        0xf8b05c79f090979bf4a80270aba232dff11a10d9ca55c4f88de95317970f0de9;
    bytes32 public constant SCHEMA_COUNTRY =
        0x1801901fabd0e6189356b4fb52bb0ab855276d84f7ec140839fbd1f6801ca065;
    bytes32 public constant SCHEMA_BIZ_ACCOUNT =
        0xf82663c0eac879bed1e09e3d4598752359a321f51b38ae669728f480abf3f474;
    bytes32 public constant SCHEMA_BIZ_COUNTRY =
        0xf87445e61219642b989807bc418e5d5fa8e3adb49e230891055a997121f6c80b;

    bytes32 public constant TYPE_KYC = keccak256("KYC");
    bytes32 public constant TYPE_COUNTRY = keccak256("COUNTRY");
    bytes32 public constant TYPE_ACCREDITED = keccak256("ACCREDITED");
    bytes32 public constant TYPE_BUSINESS = keccak256("BUSINESS");

    constructor(address _eas, address _indexer, address _attester) {
        eas = IEAS(_eas);
        indexer = IEASIndexer(_indexer);
        coinbaseAttester = _attester;
    }

    function verify(address user) external view override returns (VerificationResult memory result) {
        result.providerName = "coinbase";

        bool hasAccount = _hasValidAttestation(user, SCHEMA_ACCOUNT);
        bool hasCountry = _hasValidAttestation(user, SCHEMA_COUNTRY);
        bool hasBizAccount = _hasValidAttestation(user, SCHEMA_BIZ_ACCOUNT);
        bool hasBizCountry = _hasValidAttestation(user, SCHEMA_BIZ_COUNTRY);

        if (hasBizAccount || hasBizCountry) {
            result.verified = true;
            result.tier = 3;
        } else if (hasAccount && hasCountry) {
            result.verified = true;
            result.tier = 2;
        } else if (hasAccount) {
            result.verified = true;
            result.tier = 1;
        } else {
            result.verified = false;
            result.tier = 0;
        }

        if (hasAccount) {
            result.attestationId = indexer.getAttestationUid(user, SCHEMA_ACCOUNT);
        }

        return result;
    }

    function providerId() external pure override returns (bytes32) {
        return keccak256("coinbase-eas-base");
    }

    function providerName() external pure override returns (string memory) {
        return "Coinbase Verifications (EAS)";
    }

    function supportsType(bytes32 verificationType) external pure override returns (bool) {
        return verificationType == TYPE_KYC
            || verificationType == TYPE_COUNTRY
            || verificationType == TYPE_BUSINESS;
    }

    function _hasValidAttestation(address user, bytes32 schema) internal view returns (bool) {
        try indexer.getAttestationUid(user, schema) returns (bytes32 uid) {
            if (uid == bytes32(0)) return false;

            IEAS.Attestation memory att = eas.getAttestation(uid);

            if (att.attester != coinbaseAttester) return false;
            if (att.revocationTime != 0) return false;
            if (att.expirationTime != 0 && att.expirationTime < block.timestamp) return false;

            return true;
        } catch {
            return false;
        }
    }

    function hasAttestation(address user, bytes32 schema) external view returns (bool) {
        return _hasValidAttestation(user, schema);
    }
}
