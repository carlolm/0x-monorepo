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

import "./mixins/MExchangeCore.sol";
import "./mixins/MSettlement.sol";
import "./mixins/MSignatureValidator.sol";
import "./mixins/MTransactions.sol";
import "./LibOrder.sol";
import "./LibStatus.sol";
import "./LibPartialAmount.sol";
import "../../utils/SafeMath/SafeMath.sol";

/// @dev Provides MExchangeCore
/// @dev Consumes MSettlement
/// @dev Consumes MSignatureValidator
contract MixinExchangeCore is
    SafeMath,
    LibStatus,
    LibOrder,
    LibPartialAmount,
    MExchangeCore,
    MSettlement,
    MSignatureValidator,
    MTransactions
{
    // Mapping of orderHash => amount of takerAsset already bought by maker
    mapping (bytes32 => uint256) public filled;

    // Mapping of orderHash => cancelled
    mapping (bytes32 => bool) public cancelled;

    // Mapping of makerAddress => lowest salt an order can have in order to be fillable
    // Orders with a salt less than their maker's epoch are considered cancelled
    mapping (address => uint256) public makerEpoch;

    event Fill(
        address indexed makerAddress,
        address takerAddress,
        address indexed feeRecipientAddress,
        uint256 makerAssetFilledAmount,
        uint256 takerAssetFilledAmount,
        uint256 makerFeePaid,
        uint256 takerFeePaid,
        bytes32 indexed orderHash,
        bytes makerAssetData,
        bytes takerAssetData
    );

    event Cancel(
        address indexed makerAddress,
        address indexed feeRecipientAddress,
        bytes32 indexed orderHash,
        bytes makerAssetData,
        bytes takerAssetData
    );

    event CancelUpTo(
        address indexed makerAddress,
        uint256 makerEpoch
    );


    ////// Core exchange functions //////


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
            uint256 filledAmount)
    {
        // Compute the order hash and fetch filled amount
        orderHash = getOrderHash(order);
        filledAmount = filled[orderHash];

        // If order.takerAssetAmount is zero, then the order will always
        // be considered filled because 0 == takerAssetAmount == filledAmount
        // Instead of distinguishing between unfilled and filled zero taker
        // amount orders, we choose not to support them.
        if (order.takerAssetAmount == 0) {
            orderStatus = uint8(Status.INVALID);
            return (orderStatus, orderHash, filledAmount);
        }

        // If order.makerAssetAmount is zero, we also reject the order.
        // While the Exchange contract handles them correctly, they create
        // edge cases in the supporting infrastructure because they have
        // an 'infinite' price when computed by a simple division.
        if (order.makerAssetAmount == 0) {
            orderStatus = uint8(Status.INVALID);
            return (orderStatus, orderHash, filledAmount);
        }

        // Validate order expiration
        if (block.timestamp >= order.expirationTimeSeconds) {
            orderStatus = uint8(Status.ORDER_EXPIRED);
            return (orderStatus, orderHash, filledAmount);
        }

        // Validate order availability
        if (filledAmount >= order.takerAssetAmount) {
            orderStatus = uint8(Status.ORDER_FULLY_FILLED);
            return (orderStatus, orderHash, filledAmount);
        }

        // Check if order has been cancelled
        if (cancelled[orderHash]) {
            orderStatus = uint8(Status.ORDER_CANCELLED);
            return (orderStatus, orderHash, filledAmount);
        }

        // Validate order is not cancelled
        if (makerEpoch[order.makerAddress] > order.salt) {
            orderStatus = uint8(Status.ORDER_CANCELLED);
            return (orderStatus, orderHash, filledAmount);
        }

        // Order is Fillable
        orderStatus = uint8(Status.ORDER_FILLABLE);
        return (orderStatus, orderHash, filledAmount);
    }

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
        internal
    {
        // Ensure order status is not invalid
        if (orderStatus == uint8(Status.INVALID)) {
            emit ExchangeStatus(uint8(orderStatus), orderHash);
            revert();
        }

        // Validate Maker signature (check only if first time seen)
        if (filledAmount == 0 && !isValidSignature(orderHash, order.makerAddress, signature)) {
            emit ExchangeStatus(uint8(Status.INVALID_SIGNATURE), orderHash);
            revert();
        }

        // Validate sender is allowed to fill this order
        if (order.senderAddress != address(0) && order.senderAddress != msg.sender) {
            emit ExchangeStatus(uint8(Status.INVALID_SENDER), orderHash);
            revert();
        }

        // Validate taker is allowed to fill this order
        if (order.takerAddress != address(0) && order.takerAddress != takerAddress) {
            emit ExchangeStatus(uint8(Status.INVALID_TAKER), orderHash);
            revert();
        }

        // Ensure valid takerAssetFillAmount
        if(takerAssetFillAmount <= 0) {
            emit ExchangeStatus(uint8(Status.TAKER_ASSET_FILL_AMOUNT_TOO_LOW), orderHash);
            revert();
        }
    }

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
            FillResults memory fillResults)
    {
        // Fill Amount must be greater than 0
        if(takerAssetFillAmount <= 0) {
            status = uint8(Status.TAKER_ASSET_FILL_AMOUNT_TOO_LOW);
            return;
        }

        // Ensure the order is fillable
        if (orderStatus != uint8(Status.ORDER_FILLABLE)) {
            status = uint8(orderStatus);
            return;
        }

        // Compute takerAssetFilledAmount
        uint256 remainingtakerAssetAmount = safeSub(order.takerAssetAmount, filledAmount);
        fillResults.takerAssetFilledAmount = min256(takerAssetFillAmount, remainingtakerAssetAmount);

        // Validate fill order rounding
        if (isRoundingError(
            fillResults.takerAssetFilledAmount,
            order.takerAssetAmount,
            order.makerAssetAmount))
        {
            status = uint8(Status.ROUNDING_ERROR_TOO_LARGE);
            return;
        }

        // Compute proportional transfer amounts
        // TODO: All three are multiplied by the same fraction. This can
        // potentially be optimized.
        fillResults.makerAssetFilledAmount = getPartialAmount(
            fillResults.takerAssetFilledAmount,
            order.takerAssetAmount,
            order.makerAssetAmount);
        fillResults.makerFeePaid = getPartialAmount(
            fillResults.takerAssetFilledAmount,
            order.takerAssetAmount,
            order.makerFee);
        fillResults.takerFeePaid = getPartialAmount(
            fillResults.takerAssetFilledAmount,
            order.takerAssetAmount,
            order.takerFee);

        status = uint8(Status.SUCCESS);
        return;
    }

    /// @dev Updates state with results of a fill order.
    /// @param order that was filled.
    /// @param takerAddress Address of taker who filled the order.
    /// @return fillResults Amounts filled and fees paid by maker and taker.
    function updateFilledState(
        Order memory order,
        address takerAddress,
        bytes32 orderHash,
        FillResults memory fillResults)
        internal
    {
        // Update state
        filled[orderHash] = safeAdd(filled[orderHash], fillResults.takerAssetFilledAmount);

        // Log order
        emitFillEvent(order, takerAddress, orderHash, fillResults);
    }

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
        returns (FillResults memory fillResults)
    {
        // Fetch current order status
        bytes32 orderHash;
        uint8 orderStatus;
        uint256 filledAmount;
        (orderStatus, orderHash, filledAmount) = getOrderInfo(order);

        // Fetch taker address
        address takerAddress = getCurrentContextAddress();

        // Either our context is valid or we revert
        validateFillOrderContextOrRevert(order, orderStatus, orderHash, filledAmount, signature, takerAddress, takerAssetFillAmount);

        // Compute proportional fill amounts
        uint8 status;
        (status, fillResults) = getFillAmounts(order, orderStatus, filledAmount, takerAssetFillAmount);
        if (status != uint8(Status.SUCCESS)) {
            emit ExchangeStatus(uint8(status), orderHash);
            return fillResults;
        }

        // Settle order
        (fillResults.makerAssetFilledAmount, fillResults.makerFeePaid, fillResults.takerFeePaid) =
            settleOrder(order, takerAddress, fillResults.takerAssetFilledAmount);

        // Update exchange internal state
        updateFilledState(order, takerAddress, orderHash, fillResults);
        return fillResults;
    }

    /// @dev Validates context for cancelOrder. Succeeds or throws.
    /// @param order that was cancelled.
    /// @param orderStatus Status of order that was cancelled.
    /// @param orderHash Hash of order that was cancelled.
    function validateCancelOrderContextOrRevert(
        Order memory order,
        uint8 orderStatus,
        bytes32 orderHash)
        internal
    {
        // Ensure order is valid
        if (orderStatus == uint8(Status.INVALID)) {
            emit ExchangeStatus(uint8(orderStatus), orderHash);
            revert();
        }

        // Validate transaction signed by maker
        address makerAddress = getCurrentContextAddress();
        if(order.makerAddress != makerAddress) {
            emit ExchangeStatus(uint8(Status.INVALID_MAKER), orderHash);
            revert();
        }

        // Validate sender is allowed to cancel this order
        if (order.senderAddress != address(0) && order.senderAddress != msg.sender) {
            emit ExchangeStatus(uint8(Status.INVALID_SENDER), orderHash);
            revert();
        }
    }

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
        returns (bool stateUpdated)
    {
        // Ensure order is fillable (otherwise cancelling does nothing)
        if (orderStatus != uint8(Status.ORDER_FILLABLE)) {
            emit ExchangeStatus(uint8(orderStatus), orderHash);
            stateUpdated = false;
            return stateUpdated;
        }

        // Perform cancel
        cancelled[orderHash] = true;
        stateUpdated = true;

        // Log cancel
        emit Cancel(
            order.makerAddress,
            order.feeRecipientAddress,
            orderHash,
            order.makerAssetData,
            order.takerAssetData
        );

        return stateUpdated;
    }

    /// @dev After calling, the order can not be filled anymore.
    /// @param order Order struct containing order specifications.
    /// @return True if the order state changed to cancelled.
    ///         False if the transaction was already cancelled or expired.
    function cancelOrder(Order memory order)
        public
        returns (bool)
    {
        // Fetch current order status
        bytes32 orderHash;
        uint8 orderStatus;
        uint256 filledAmount;
        (orderStatus, orderHash, filledAmount) = getOrderInfo(order);

        // Validate context
        validateCancelOrderContextOrRevert(order, orderStatus, orderHash);

        // Perform cancel
        return updateCancelledState(order, orderStatus, orderHash);
    }

    /// @param salt Orders created with a salt less or equal to this value will be cancelled.
    function cancelOrdersUpTo(uint256 salt)
        external
    {
        uint256 newMakerEpoch = salt + 1;                // makerEpoch is initialized to 0, so to cancelUpTo we need salt+1
        require(newMakerEpoch > makerEpoch[msg.sender]); // epoch must be monotonically increasing
        makerEpoch[msg.sender] = newMakerEpoch;
        emit CancelUpTo(msg.sender, newMakerEpoch);
    }

    /// @dev Checks if rounding error > 0.1%.
    /// @param numerator Numerator.
    /// @param denominator Denominator.
    /// @param target Value to multiply with numerator/denominator.
    /// @return Rounding error is present.
    function isRoundingError(uint256 numerator, uint256 denominator, uint256 target)
        public pure
        returns (bool isError)
    {
        uint256 remainder = mulmod(target, numerator, denominator);
        if (remainder == 0) {
            return false; // No rounding error.
        }

        uint256 errPercentageTimes1000000 = safeDiv(
            safeMul(remainder, 1000000),
            safeMul(numerator, target)
        );
        isError = errPercentageTimes1000000 > 1000;
        return isError;
    }

    /// @dev Logs a Fill event with the given arguments.
    ///      The sole purpose of this function is to get around the stack variable limit.
    function emitFillEvent(
        Order memory order,
        address takerAddress,
        bytes32 orderHash,
        FillResults memory fillResults)
        internal
    {
        emit Fill(
            order.makerAddress,
            takerAddress,
            order.feeRecipientAddress,
            fillResults.makerAssetFilledAmount,
            fillResults.takerAssetFilledAmount,
            fillResults.makerFeePaid,
            fillResults.takerFeePaid,
            orderHash,
            order.makerAssetData,
            order.takerAssetData
        );
    }
}
