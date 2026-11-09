// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ILexifiPolicy} from "../interfaces/ILexifiPolicy.sol";
import {IVerificationProvider} from "../interfaces/IVerificationProvider.sol";
import {LexifiPolicyConfig} from "../LexifiPolicyConfig.sol";
import {CoinbaseEASProvider, IEAS, IEASIndexer} from "./CoinbaseEASProvider.sol";

/// @title CountryEligibilityPolicy
/// @notice Admits a wallet only if the country in its Coinbase attestation is eligible for the
///         pool. Wallets attested to the United States or a US territory are always denied, and
///         no pool config can change that.
///
/// @dev RegionalPolicyV4 asks only whether a country attestation exists. This policy reads the
///      value: Coinbase's schemas are `string verifiedCountry` and
///      `string verifiedBusinessCountry`, holding an ISO 3166-1 alpha-2 code.
///
///      Every rule fails closed:
///      - An unconfigured or inactive pool denies, and `minimumLevel` returns INSTITUTIONAL.
///      - A wallet with no valid country attestation denies, so a US person cannot pass by
///        having no attestation.
///      - If a wallet holds both a personal and a business attestation, both must be eligible.
///      - A value that is not exactly two uppercase ASCII letters denies, so "us" or "USA"
///        cannot slip past the comparison.
///      - A failed lookup denies, so a lookup error cannot hide a US attestation.
///
///      The enforced minimum is floored at RETAIL, so a DENIED verdict can never pass the
///      `level >= minimumLevel` comparison, whatever bytes the registry holds. Removing
///      liquidity is never gated.
///
///      Limits: the attestation records the country on the holder's Coinbase account, not where
///      the holder is now, and the gate covers only pools that use this policy. Deploy against
///      `LexifiPolicyConfigV2`.
contract CountryEligibilityPolicy is ILexifiPolicy {
    struct CountryConfig {
        AccessLevel minimumSwapLevel;
        AccessLevel minimumLpLevel;
        /// @dev True: only `countries` are eligible. False: every country except `countries`.
        bool allowOnlyListed;
        bytes2[] countries;
        bool active;
    }

    enum Reading {
        None,
        Valid,
        Unreadable
    }

    bytes32 public constant CONFIG_FAMILY = keccak256("lexifi.policy.country");

    CoinbaseEASProvider public immutable provider;
    LexifiPolicyConfig public immutable configRegistry;

    IEAS private immutable _eas;
    IEASIndexer private immutable _indexer;
    address private immutable _attester;
    bytes32 private immutable _schemaCountry;
    bytes32 private immutable _schemaBusinessCountry;

    error ZeroAddress();
    error InvalidCountryCode(bytes2 code);

    constructor(address _provider, address _registry) {
        if (_provider == address(0) || _registry == address(0)) revert ZeroAddress();
        provider = CoinbaseEASProvider(_provider);
        configRegistry = LexifiPolicyConfig(_registry);

        // Read from the provider so the two contracts cannot disagree on what counts as valid.
        _eas = provider.eas();
        _indexer = provider.indexer();
        _attester = provider.coinbaseAttester();
        _schemaCountry = provider.SCHEMA_COUNTRY();
        _schemaBusinessCountry = provider.SCHEMA_BIZ_COUNTRY();
    }

    /// @dev Decode config and normalise it. `configured` false means "deny", never "allow".
    function _config(PoolId poolId)
        internal
        view
        returns (CountryConfig memory cfg, bool configured)
    {
        bytes memory raw = configRegistry.getConfig(CONFIG_FAMILY, poolId);
        if (raw.length == 0) return (cfg, false);
        cfg = abi.decode(raw, (CountryConfig));
        if (!cfg.active) return (cfg, false);

        // LP minimum never below the swap minimum.
        if (uint8(cfg.minimumLpLevel) < uint8(cfg.minimumSwapLevel)) {
            cfg.minimumLpLevel = cfg.minimumSwapLevel;
        }
        configured = true;
    }

    function checkAccess(PoolId poolId, address user, uint8, /* operation */ uint256 /* amount */ )
        external
        view
        override
        returns (AccessLevel level, string memory reason)
    {
        (CountryConfig memory cfg, bool configured) = _config(poolId);
        if (!configured) return (AccessLevel.DENIED, "Pool not configured for this policy");

        IVerificationProvider.VerificationResult memory v = provider.verify(user);
        if (!v.verified) return (AccessLevel.DENIED, "No verification found");

        (Reading personal, bytes2 personalCode) = _readCountry(user, _schemaCountry);
        (Reading business, bytes2 businessCode) = _readCountry(user, _schemaBusinessCountry);

        if (personal == Reading.Unreadable || business == Reading.Unreadable) {
            return (AccessLevel.DENIED, "Country attestation could not be read");
        }
        if (personal == Reading.None && business == Reading.None) {
            return (AccessLevel.DENIED, "Country verification required for this pool");
        }
        if (personal == Reading.Valid && !_isEligible(cfg, personalCode)) {
            return (AccessLevel.DENIED, "Country not eligible for this pool");
        }
        if (business == Reading.Valid && !_isEligible(cfg, businessCode)) {
            return (AccessLevel.DENIED, "Business country not eligible for this pool");
        }

        return (AccessLevel(v.tier), "");
    }

    function minimumLevel(PoolId poolId, uint8 operation)
        external
        view
        override
        returns (AccessLevel)
    {
        (CountryConfig memory cfg, bool configured) = _config(poolId);
        // Maximum, not DENIED: checkAccess returns DENIED here and `0 >= 0` would pass.
        if (!configured) return AccessLevel.INSTITUTIONAL;
        if (operation > 1) return AccessLevel.DENIED; // removeLiquidity: exit is never gated
        return _floor(operation == 0 ? cfg.minimumSwapLevel : cfg.minimumLpLevel);
    }

    /// @notice True for the United States and its territories, which no pool can admit.
    function isAlwaysBlocked(bytes2 code) public pure returns (bool) {
        return code == "US" || code == "PR" || code == "GU" || code == "VI" || code == "AS"
            || code == "MP" || code == "UM";
    }

    function policyName() external pure override returns (string memory) {
        return "Lexifi Country Eligibility Policy";
    }

    function policyVersion() external pure override returns (uint256) {
        return 1;
    }

    /// @notice Encode a config for the registry's `setConfig`.
    /// @dev Use ISO codes: the United Kingdom is "GB", not "UK". Listing a US code as eligible
    ///      has no effect, because `isAlwaysBlocked` is checked first.
    function encodeConfig(
        AccessLevel minSwap,
        AccessLevel minLp,
        bool allowOnlyListed,
        bytes2[] calldata countries
    ) external pure returns (bytes memory) {
        for (uint256 i = 0; i < countries.length; i++) {
            if (!_isCountryFormat(countries[i])) revert InvalidCountryCode(countries[i]);
        }
        return abi.encode(
            CountryConfig({
                minimumSwapLevel: minSwap,
                minimumLpLevel: minLp,
                allowOnlyListed: allowOnlyListed,
                countries: countries,
                active: true
            })
        );
    }

    /// @dev Re-applies every check the provider makes, because the provider exposes only a
    ///      yes/no answer and this contract needs the attestation's data.
    function _readCountry(address user, bytes32 schema)
        internal
        view
        returns (Reading, bytes2)
    {
        bytes32 uid;
        try _indexer.getAttestationUid(user, schema) returns (bytes32 found) {
            uid = found;
        } catch {
            return (Reading.Unreadable, bytes2(0));
        }
        if (uid == bytes32(0)) return (Reading.None, bytes2(0));

        IEAS.Attestation memory att;
        try _eas.getAttestation(uid) returns (IEAS.Attestation memory found) {
            att = found;
        } catch {
            return (Reading.Unreadable, bytes2(0));
        }

        if (att.schema != schema || att.attester != _attester || att.recipient != user) {
            return (Reading.None, bytes2(0));
        }
        if (att.revocationTime != 0) return (Reading.None, bytes2(0));
        if (att.expirationTime != 0 && att.expirationTime < block.timestamp) {
            return (Reading.None, bytes2(0));
        }

        return _decodeCountry(att.data);
    }

    /// @dev Strict on purpose. `abi.encode(string)` of two characters is exactly three words:
    ///      offset, length and the right-padded text. Anything else is unreadable. Parsed by
    ///      hand because `abi.decode` reverts on bad input and cannot be caught internally.
    function _decodeCountry(bytes memory data) internal pure returns (Reading, bytes2) {
        if (data.length != 96) return (Reading.Unreadable, bytes2(0));

        uint256 offset;
        uint256 length;
        bytes32 text;
        assembly ("memory-safe") {
            offset := mload(add(data, 32))
            length := mload(add(data, 64))
            text := mload(add(data, 96))
        }
        if (offset != 32 || length != 2) return (Reading.Unreadable, bytes2(0));
        if (uint256(text) << 16 != 0) return (Reading.Unreadable, bytes2(0));

        bytes2 code = bytes2(text);
        if (!_isCountryFormat(code)) return (Reading.Unreadable, bytes2(0));
        return (Reading.Valid, code);
    }

    function _isEligible(CountryConfig memory cfg, bytes2 code) internal pure returns (bool) {
        if (isAlwaysBlocked(code)) return false;

        bool listed = false;
        for (uint256 i = 0; i < cfg.countries.length; i++) {
            if (cfg.countries[i] == code) {
                listed = true;
                break;
            }
        }
        return cfg.allowOnlyListed ? listed : !listed;
    }

    function _isCountryFormat(bytes2 code) internal pure returns (bool) {
        return code[0] >= "A" && code[0] <= "Z" && code[1] >= "A" && code[1] <= "Z";
    }

    function _floor(AccessLevel stored) internal pure returns (AccessLevel) {
        return uint8(stored) < uint8(AccessLevel.RETAIL) ? AccessLevel.RETAIL : stored;
    }
}
