// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {LexifiHookV4} from "../src/LexifiHookV4.sol";
import {LexifiPolicyConfigV2, IPoolAdminSource} from "../src/LexifiPolicyConfigV2.sol";
import {ILexifiPolicy} from "../src/interfaces/ILexifiPolicy.sol";
import {CoinbaseEASProvider, IEAS} from "../src/policies/CoinbaseEASProvider.sol";
import {CountryEligibilityPolicy} from "../src/policies/CountryEligibilityPolicy.sol";

contract MockEAS {
    mapping(bytes32 => IEAS.Attestation) private _attestations;

    function setAttestation(IEAS.Attestation memory att) external {
        _attestations[att.uid] = att;
    }

    function getAttestation(bytes32 uid) external view returns (IEAS.Attestation memory) {
        return _attestations[uid];
    }
}

contract MockIndexer {
    mapping(address => mapping(bytes32 => bytes32)) private _uids;
    mapping(bytes32 => bool) public failing;

    function setUid(address recipient, bytes32 schema, bytes32 uid) external {
        _uids[recipient][schema] = uid;
    }

    function setFailing(bytes32 schema, bool value) external {
        failing[schema] = value;
    }

    function getAttestationUid(address recipient, bytes32 schema) external view returns (bytes32) {
        require(!failing[schema], "indexer down");
        return _uids[recipient][schema];
    }
}

/// @dev Uses the real CoinbaseEASProvider and real LexifiHookV4. Only EAS and its indexer are
///      faked, so attestations can be malformed, revoked or forged. Verdicts are asserted through
///      `checkAccess().level >= minimumLevel(op)` and the hook itself, never through `reason`.
contract CountryEligibilityPolicyTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint8 constant OP_SWAP = 0;
    uint8 constant OP_LP = 1;
    uint8 constant OP_REMOVE = 2;

    ILexifiPolicy.AccessLevel constant DENIED = ILexifiPolicy.AccessLevel.DENIED;
    ILexifiPolicy.AccessLevel constant RETAIL = ILexifiPolicy.AccessLevel.RETAIL;
    ILexifiPolicy.AccessLevel constant ACCREDITED = ILexifiPolicy.AccessLevel.ACCREDITED;
    ILexifiPolicy.AccessLevel constant INSTITUTIONAL = ILexifiPolicy.AccessLevel.INSTITUTIONAL;

    address constant TOKEN = address(0x1000000000000000000000000000000000000001);
    address constant USDC = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    address coinbase = makeAddr("coinbaseAttester");
    address safe = makeAddr("safe");
    address issuer = makeAddr("issuer");
    address user = makeAddr("user");
    address other = makeAddr("other");

    PoolManager manager;
    MockEAS eas;
    MockIndexer indexer;
    CoinbaseEASProvider provider;
    LexifiHookV4 hook;
    LexifiPolicyConfigV2 registry;
    CountryEligibilityPolicy policy;
    PoolKey key;
    PoolId poolId;

    bytes32 schemaAccount;
    bytes32 schemaCountry;
    bytes32 schemaBizAccount;
    bytes32 schemaBizCountry;
    uint256 nonce;

    function setUp() public {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        eas = new MockEAS();
        indexer = new MockIndexer();
        provider = new CoinbaseEASProvider(address(eas), address(indexer), coinbase);

        schemaAccount = provider.SCHEMA_ACCOUNT();
        schemaCountry = provider.SCHEMA_COUNTRY();
        schemaBizAccount = provider.SCHEMA_BIZ_ACCOUNT();
        schemaBizCountry = provider.SCHEMA_BIZ_COUNTRY();

        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG
            ) | (uint160(0x5555) << 144)
        );
        deployCodeTo(
            "LexifiHookV4.sol:LexifiHookV4", abi.encode(IPoolManager(address(manager)), safe), hookAddr
        );
        hook = LexifiHookV4(hookAddr);
        registry = new LexifiPolicyConfigV2(IPoolAdminSource(address(hook)));
        policy = new CountryEligibilityPolicy(address(provider), address(registry));

        key = PoolKey({
            currency0: Currency.wrap(TOKEN),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        poolId = key.toId();
        vm.prank(issuer);
        hook.createPool(key, SQRT_PRICE_1_1, address(policy));
    }

    // ═══════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════

    function _configure(
        ILexifiPolicy.AccessLevel minSwap,
        ILexifiPolicy.AccessLevel minLp,
        bool allowOnly,
        bytes2[] memory countries
    ) internal {
        bytes memory data = policy.encodeConfig(minSwap, minLp, allowOnly, countries);
        bytes32 family = policy.CONFIG_FAMILY();
        vm.prank(issuer);
        registry.setConfig(family, poolId, data);
    }

    function _open() internal {
        _configure(RETAIL, RETAIL, false, new bytes2[](0));
    }

    function _list(bytes2 a) internal pure returns (bytes2[] memory out) {
        out = new bytes2[](1);
        out[0] = a;
    }

    function _attest(address recipient, bytes32 schema, bytes memory data)
        internal
        returns (bytes32 uid)
    {
        uid = _write(recipient, schema, data, coinbase, recipient, schema, 0, 0);
    }

    function _write(
        address indexedFor,
        bytes32 indexedUnder,
        bytes memory data,
        address attester,
        address recipient,
        bytes32 schema,
        uint64 expiration,
        uint64 revocation
    ) internal returns (bytes32 uid) {
        uid = keccak256(abi.encode("uid", ++nonce));
        eas.setAttestation(
            IEAS.Attestation({
                uid: uid,
                schema: schema,
                time: uint64(block.timestamp),
                expirationTime: expiration,
                revocationTime: revocation,
                refUID: bytes32(0),
                recipient: recipient,
                attester: attester,
                revocable: true,
                data: data
            })
        );
        indexer.setUid(indexedFor, indexedUnder, uid);
    }

    function _verifyPerson(address who, string memory country) internal {
        _attest(who, schemaAccount, abi.encode(true));
        _attest(who, schemaCountry, abi.encode(country));
    }

    function _verifyBusiness(address who, string memory country) internal {
        _attest(who, schemaBizAccount, abi.encode(true));
        _attest(who, schemaBizCountry, abi.encode(country));
    }

    function _passes(address who, uint8 op) internal view returns (bool) {
        (ILexifiPolicy.AccessLevel level,) = policy.checkAccess(poolId, who, op, 1e18);
        return uint8(level) >= uint8(policy.minimumLevel(poolId, op));
    }

    function _hookSwap(address who) internal returns (bool ok) {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });
        vm.prank(address(manager));
        (ok,) = address(hook).call(abi.encodeCall(IHooks.beforeSwap, (who, key, p, "")));
    }

    function _hookAddLiquidity(address who) internal returns (bool ok) {
        IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 1_000_000e18,
            salt: bytes32(0)
        });
        vm.prank(address(manager));
        (ok,) = address(hook).call(abi.encodeCall(IHooks.beforeAddLiquidity, (who, key, p, "")));
    }

    // ═══════════════════════════════════════════
    //  THE CORE RULE, THROUGH THE REAL HOOK
    // ═══════════════════════════════════════════

    function test_Hook_NonUsWallet_CanSwapAndAddLiquidity() public {
        _open();
        _verifyPerson(user, "GB");
        assertTrue(_hookSwap(user), "GB swap");
        assertTrue(_hookAddLiquidity(user), "GB LP");
    }

    function test_Hook_UsWallet_CannotSwapOrAddLiquidity() public {
        _open();
        _verifyPerson(user, "US");
        assertFalse(_hookSwap(user), "US swap");
        assertFalse(_hookAddLiquidity(user), "US LP");
    }

    function test_Hook_UnverifiedWallet_CannotSwapOrAddLiquidity() public {
        _open();
        assertFalse(_hookSwap(user), "unverified swap");
        assertFalse(_hookAddLiquidity(user), "unverified LP");
    }

    function test_Hook_AccountOnlyWallet_Denied() public {
        _open();
        _attest(user, schemaAccount, abi.encode(true));
        assertFalse(_hookSwap(user), "no country attestation");
    }

    function test_UsTerritories_AlwaysDenied() public {
        _open();
        string[7] memory codes = ["US", "PR", "GU", "VI", "AS", "MP", "UM"];
        for (uint256 i = 0; i < codes.length; i++) {
            address wallet = makeAddr(codes[i]);
            _verifyPerson(wallet, codes[i]);
            assertFalse(_passes(wallet, OP_SWAP), codes[i]);
            assertFalse(_passes(wallet, OP_LP), codes[i]);
        }
    }

    function test_RemoveLiquidity_NeverGated() public {
        _open();
        _verifyPerson(user, "US");
        assertTrue(_passes(user, OP_REMOVE), "US wallet can exit");
        assertTrue(_passes(other, OP_REMOVE), "unverified wallet can exit");
    }

    // ═══════════════════════════════════════════
    //  POOL CONFIG
    // ═══════════════════════════════════════════

    function test_BlockList_DeniesListedCountry() public {
        _configure(RETAIL, RETAIL, false, _list("RU"));
        _verifyPerson(user, "RU");
        _verifyPerson(other, "FR");
        assertFalse(_passes(user, OP_SWAP), "listed");
        assertTrue(_passes(other, OP_SWAP), "not listed");
    }

    function test_AllowList_AdmitsOnlyListedCountry() public {
        _configure(RETAIL, RETAIL, true, _list("GB"));
        _verifyPerson(user, "GB");
        _verifyPerson(other, "FR");
        assertTrue(_passes(user, OP_SWAP), "listed");
        assertFalse(_passes(other, OP_SWAP), "not listed");
    }

    function test_EmptyAllowList_DeniesEveryone() public {
        _configure(RETAIL, RETAIL, true, new bytes2[](0));
        _verifyPerson(user, "GB");
        assertFalse(_passes(user, OP_SWAP));
    }

    function test_PoolAdminCannotAllowUs() public {
        _configure(RETAIL, RETAIL, true, _list("US"));
        _verifyPerson(user, "US");
        assertFalse(_passes(user, OP_SWAP), "US stays denied when listed as eligible");
    }

    function test_StrangerCannotChangeConfig() public {
        bytes memory data = policy.encodeConfig(RETAIL, RETAIL, false, new bytes2[](0));
        bytes32 family = policy.CONFIG_FAMILY();
        vm.prank(other);
        vm.expectRevert(LexifiPolicyConfigV2.Unauthorized.selector);
        registry.setConfig(family, poolId, data);
    }

    function test_EncodeConfig_RejectsBadCodes() public {
        bytes2[3] memory bad = [bytes2("us"), bytes2("U1"), bytes2(0)];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(CountryEligibilityPolicy.InvalidCountryCode.selector, bad[i])
            );
            policy.encodeConfig(RETAIL, RETAIL, false, _list(bad[i]));
        }
    }

    function test_MinimumLevel_StillEnforced() public {
        _configure(INSTITUTIONAL, INSTITUTIONAL, false, new bytes2[](0));
        _verifyPerson(user, "GB"); // tier 2
        assertFalse(_passes(user, OP_SWAP), "tier 2 below minimum");
        _verifyBusiness(other, "GB"); // tier 3
        assertTrue(_passes(other, OP_SWAP), "tier 3 meets minimum");
    }

    function test_LpMinimum_ClampedToSwapMinimum() public {
        _configure(INSTITUTIONAL, RETAIL, false, new bytes2[](0));
        assertEq(uint8(policy.minimumLevel(poolId, OP_LP)), uint8(INSTITUTIONAL));
    }

    // ═══════════════════════════════════════════
    //  FAIL-CLOSED
    // ═══════════════════════════════════════════

    function test_Unconfigured_DeniesOnBothSides() public view {
        (ILexifiPolicy.AccessLevel level,) = policy.checkAccess(poolId, user, OP_SWAP, 1);
        assertEq(uint8(level), uint8(DENIED));
        assertEq(uint8(policy.minimumLevel(poolId, OP_SWAP)), uint8(INSTITUTIONAL));
    }

    function test_Unconfigured_DeniesVerifiedWallet() public {
        _verifyPerson(user, "GB");
        assertFalse(_hookSwap(user));
    }

    function test_InactiveConfig_DeniesOnBothSides() public {
        _verifyPerson(user, "GB");
        bytes memory data = abi.encode(
            CountryEligibilityPolicy.CountryConfig({
                minimumSwapLevel: RETAIL,
                minimumLpLevel: RETAIL,
                allowOnlyListed: false,
                countries: new bytes2[](0),
                active: false
            })
        );
        bytes32 family = policy.CONFIG_FAMILY();
        vm.prank(issuer);
        registry.setConfig(family, poolId, data);
        assertFalse(_passes(user, OP_SWAP));
        assertEq(uint8(policy.minimumLevel(poolId, OP_SWAP)), uint8(INSTITUTIONAL));
    }

    function test_DeniedMinimum_CannotTurnDenialsIntoPasses() public {
        _configure(DENIED, DENIED, false, new bytes2[](0));
        _verifyPerson(user, "US");
        assertFalse(_passes(user, OP_SWAP), "US");
        assertFalse(_passes(other, OP_SWAP), "unverified");
        assertFalse(_hookSwap(user), "hook US");
        assertFalse(_hookAddLiquidity(other), "hook unverified");
    }

    function test_GarbageConfig_DeniedByHook() public {
        _verifyPerson(user, "GB");
        bytes32 family = policy.CONFIG_FAMILY();
        vm.prank(issuer);
        registry.setConfig(family, poolId, hex"deadbeef");
        assertFalse(_hookSwap(user));
    }

    // ═══════════════════════════════════════════
    //  BOTH ATTESTATIONS MUST AGREE
    // ═══════════════════════════════════════════

    function test_BusinessOnly_NonUs_Passes() public {
        _open();
        _verifyBusiness(user, "GB");
        assertTrue(_passes(user, OP_SWAP));
    }

    function test_BusinessOnly_Us_Denied() public {
        _open();
        _verifyBusiness(user, "US");
        assertFalse(_passes(user, OP_SWAP));
    }

    function test_BusinessAccountWithNoCountry_Denied() public {
        _open();
        _attest(user, schemaBizAccount, abi.encode(true));
        assertFalse(_passes(user, OP_SWAP));
    }

    function test_PersonalNonUs_BusinessUs_Denied() public {
        _open();
        _verifyPerson(user, "GB");
        _verifyBusiness(user, "US");
        assertFalse(_passes(user, OP_SWAP));
    }

    function test_PersonalUs_BusinessNonUs_Denied() public {
        _open();
        _verifyPerson(user, "US");
        _verifyBusiness(user, "GB");
        assertFalse(_passes(user, OP_SWAP));
    }

    function test_FailedLookup_CannotHideAUsAttestation() public {
        _open();
        _verifyPerson(user, "GB");
        _verifyBusiness(user, "US");
        indexer.setFailing(schemaBizCountry, true);
        assertFalse(_passes(user, OP_SWAP), "lookup failure must deny");
    }

    // ═══════════════════════════════════════════
    //  ATTESTATION VALIDITY
    // ═══════════════════════════════════════════

    function test_RevokedCountryAttestation_Denied() public {
        _open();
        _attest(user, schemaAccount, abi.encode(true));
        _write(user, schemaCountry, abi.encode("GB"), coinbase, user, schemaCountry, 0, uint64(block.timestamp));
        assertFalse(_passes(user, OP_SWAP));
    }

    function test_ExpiredCountryAttestation_Denied() public {
        _open();
        _attest(user, schemaAccount, abi.encode(true));
        _write(user, schemaCountry, abi.encode("GB"), coinbase, user, schemaCountry, uint64(block.timestamp - 1), 0);
        assertFalse(_passes(user, OP_SWAP));
    }

    function test_UnexpiredCountryAttestation_Passes() public {
        _open();
        _attest(user, schemaAccount, abi.encode(true));
        _write(user, schemaCountry, abi.encode("GB"), coinbase, user, schemaCountry, uint64(block.timestamp + 1), 0);
        assertTrue(_passes(user, OP_SWAP));
    }

    function test_ForgedAttester_Denied() public {
        _open();
        _attest(user, schemaAccount, abi.encode(true));
        _write(user, schemaCountry, abi.encode("GB"), other, user, schemaCountry, 0, 0);
        assertFalse(_passes(user, OP_SWAP));
    }

    function test_AttestationForAnotherWallet_Denied() public {
        _open();
        _attest(user, schemaAccount, abi.encode(true));
        _write(user, schemaCountry, abi.encode("GB"), coinbase, other, schemaCountry, 0, 0);
        assertFalse(_passes(user, OP_SWAP));
    }

    /// The provider does not compare the schema, so this one is caught only by the policy.
    function test_AttestationUnderWrongSchema_Denied() public {
        _open();
        _attest(user, schemaAccount, abi.encode(true));
        _write(user, schemaCountry, abi.encode("GB"), coinbase, user, schemaAccount, 0, 0);
        assertFalse(_passes(user, OP_SWAP));
    }

    function test_MalformedCountryValues_Denied() public {
        _open();
        bytes[8] memory values = [
            abi.encode("us"),
            abi.encode("Us"),
            abi.encode("USA"),
            abi.encode("G"),
            abi.encode(""),
            abi.encodePacked("GB"),
            // Correct length and text, but non-zero padding after the two letters.
            abi.encodePacked(uint256(32), uint256(2), bytes32("GBX")),
            // Correct text and padding, but an offset that is not the canonical 32.
            abi.encodePacked(uint256(64), uint256(2), bytes32("GB"))
        ];
        for (uint256 i = 0; i < values.length; i++) {
            address wallet = address(uint160(0xA000 + i));
            _attest(wallet, schemaAccount, abi.encode(true));
            _attest(wallet, schemaCountry, values[i]);
            assertFalse(_passes(wallet, OP_SWAP), vm.toString(i));
        }
    }

    // ═══════════════════════════════════════════
    //  FUZZ
    // ═══════════════════════════════════════════

    function testFuzz_EveryValidCode_PassesUnlessAlwaysBlocked(uint8 a, uint8 b) public {
        _open();
        bytes memory text = new bytes(2);
        text[0] = bytes1(uint8(65 + (a % 26)));
        text[1] = bytes1(uint8(65 + (b % 26)));
        bytes2 code = bytes2(text);
        _verifyPerson(user, string(text));
        assertEq(_passes(user, OP_SWAP), !policy.isAlwaysBlocked(code));
    }

    /// Any bytes that are not a canonical two-letter encoding must deny.
    function testFuzz_ArbitraryAttestationData_NeverPasses(bytes memory data) public {
        vm.assume(data.length != 96);
        _open();
        _attest(user, schemaAccount, abi.encode(true));
        _attest(user, schemaCountry, data);
        assertFalse(_passes(user, OP_SWAP));
    }

    function testFuzz_ThreeWordData_OnlyCanonicalCanPass(uint256 offset, uint256 length, bytes32 text) public {
        vm.assume(offset != 32 || length != 2);
        _open();
        _attest(user, schemaAccount, abi.encode(true));
        _attest(user, schemaCountry, abi.encodePacked(offset, length, text));
        assertFalse(_passes(user, OP_SWAP));
    }

    function testFuzz_AllowListedCountryNeverIncludesUs(bool allowOnly, uint8 minSwap, uint8 minLp) public {
        _configure(
            ILexifiPolicy.AccessLevel(minSwap % 4),
            ILexifiPolicy.AccessLevel(minLp % 4),
            allowOnly,
            _list("US")
        );
        _verifyBusiness(user, "US"); // tier 3, the highest level a wallet can hold
        assertFalse(_passes(user, OP_SWAP));
        assertFalse(_passes(user, OP_LP));
    }
}
