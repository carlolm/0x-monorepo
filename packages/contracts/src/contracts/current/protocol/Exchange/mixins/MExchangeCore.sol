/*

  Copyright 2018 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.4.21;
pragma experimental ABIEncoderV2;

import "../LibOrder.sol";

contract MExchangeCore is LibOrder {

    struct FillResults {
        uint256 makerAssetFilledAmount;
        uint256 takerAssetFilledAmount;
        uint256 makerFeePaid;
        uint256 takerFeePaid;
    }

    /// @dev Gets information about an order.
    /// @param order Order to gather information on.
    /// @return status Status of order. Statuses are defined in the LibStatus.Status struct.
    /// @return orderHash Keccak-256 EIP712 hash of the order.
    /// @return filledAmount Amount of order that has been filled.
    function getOrderInfo(Order memory order)
        public
        view
        returns (
            uint8 orderStatus,
            bytes32 orderHash,
            uint256 filledAmount);

    /// @dev Validates context for fillOrder. Succeeds or throws.
    /// @param order to be filled.
    /// @param orderStatus Status of order to be filled.
    /// @param orderHash Hash of order to be filled.
    /// @param filledAmount Amount of order already filled.
    /// @param signature Proof that the orders was created by its maker.
    /// @param takerAddress Address of order taker.
    /// @param takerAssetFillAmount Desired amount of order to fill by taker.
    function validateFillOrderContextOrRevert(
        Order memory order,
        uint8 orderStatus,
        bytes32 orderHash,
        uint256 filledAmount,
        bytes memory signature,
        address takerAddress,
        uint256 takerAssetFillAmount)
        internal;

    /// @dev Calculates amounts filled and fees paid by maker and taker.
    /// @param order to be filled.
    /// @param orderStatus Status of order to be filled.
    /// @param filledAmount Amount of order already filled.
    /// @param takerAssetFillAmount Desired amount of order to fill by taker.
    /// @return status Return status of calculating fill amounts. Returns Status.SUCCESS on success.
    /// @return fillResults Amounts filled and fees paid by maker and taker.
    function getFillAmounts(
        Order memory order,
        uint8 orderStatus,
        uint256 filledAmount,
        uint256 takerAssetFillAmount)
        public
        pure
        returns (
            uint8 status,
            FillResults memory fillResults);

    /// @dev Updates state with results of a fill order.
    /// @param order that was filled.
    /// @param takerAddress Address of taker who filled the order.
    /// @return fillResults Amounts filled and fees paid by maker and taker.
    function updateFilledState(
        Order memory order,
        address takerAddress,
        bytes32 orderHash,
        FillResults memory fillResults)
        internal;

    /// @dev Fills the input order.
    /// @param order Order struct containing order specifications.
    /// @param takerAssetFillAmount Desired amount of takerToken to sell.
    /// @param signature Proof that order has been created by maker.
    /// @return Amounts filled and fees paid by maker and taker.
    function fillOrder(
        Order memory order,
        uint256 takerAssetFillAmount,
        bytes memory signature)
        public
        returns (FillResults memory fillResults);

    /// @dev Validates context for cancelOrder. Succeeds or throws.
    /// @param order that was cancelled.
    /// @param orderStatus Status of order that was cancelled.
    /// @param orderHash Hash of order that was cancelled.
    function validateCancelOrderContextOrRevert(
        Order memory order,
        uint8 orderStatus,
        bytes32 orderHash)
        internal;

    /// @dev Updates state with results of cancelling an order.
    ///      State is only updated if the order is currently fillable.
    ///      Otherwise, updating state would have no effect.
    /// @param order that was cancelled.
    /// @param orderStatus Status of order that was cancelled.
    /// @param orderHash Hash of order that was cancelled.
    /// @return stateUpdated Returns true only if state was updated.
    function updateCancelledState(
        Order memory order,
        uint8 orderStatus,
        bytes32 orderHash)
        internal
        returns (bool stateUpdated);

    /// @dev After calling, the order can not be filled anymore.
    /// @param order Order struct containing order specifications.
    /// @return True if the order state changed to cancelled.
    ///         False if the transaction was already cancelled or expired.
    function cancelOrder(Order memory order)
        public
        returns (bool);

    /// @param salt Orders created with a salt less or equal to this value will be cancelled.
    function cancelOrdersUpTo(uint256 salt)
        external;

    /// @dev Checks if rounding error > 0.1%.
    /// @param numerator Numerator.
    /// @param denominator Denominator.
    /// @param target Value to multiply with numerator/denominator.
    /// @return Rounding error is present.
    function isRoundingError(uint256 numerator, uint256 denominator, uint256 target)
        public pure
        returns (bool isError);
}
