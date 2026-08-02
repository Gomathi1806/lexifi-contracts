// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

contract Phase1Prover is IUnlockCallback {
    IPoolManager public immutable manager;

    enum Action { ADD_LIQUIDITY, SWAP }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    receive() external payable {}

    function addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) external payable returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.unlock(
                abi.encode(Action.ADD_LIQUIDITY, abi.encode(key, tickLower, tickUpper, liquidityDelta, msg.sender))
            ),
            (BalanceDelta)
        );
        _refundETH(msg.sender);
    }

    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified
    ) external payable returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.unlock(
                abi.encode(Action.SWAP, abi.encode(key, zeroForOne, amountSpecified, msg.sender))
            ),
            (BalanceDelta)
        );
        _refundETH(msg.sender);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        (Action action, bytes memory inner) = abi.decode(rawData, (Action, bytes));

        if (action == Action.ADD_LIQUIDITY) {
            (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta, address payer) =
                abi.decode(inner, (PoolKey, int24, int24, int256, address));

            (BalanceDelta delta,) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, liquidityDelta, bytes32(0)),
                ""
            );

            _settle(key.currency0, delta.amount0(), payer);
            _settle(key.currency1, delta.amount1(), payer);
            return abi.encode(delta);
        } else {
            (PoolKey memory key, bool zeroForOne, int256 amountSpecified, address payer) =
                abi.decode(inner, (PoolKey, bool, int256, address));

            BalanceDelta delta = manager.swap(
                key,
                IPoolManager.SwapParams(
                    zeroForOne,
                    amountSpecified,
                    zeroForOne
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                ),
                ""
            );

            _settle(key.currency0, delta.amount0(), payer);
            _settle(key.currency1, delta.amount1(), payer);
            return abi.encode(delta);
        }
    }

    function _settle(Currency currency, int128 delta, address payer) internal {
        if (delta < 0) {
            uint256 amount = uint256(uint128(-delta));
            if (currency.isAddressZero()) {
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount);
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(uint128(delta)));
        }
    }

    function _refundETH(address to) internal {
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = to.call{value: bal}("");
            require(ok);
        }
    }
}
