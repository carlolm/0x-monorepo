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
import "./mixins/MMatchOrders.sol";
import "./mixins/MSettlement.sol";
import "./mixins/MTransactions.sol";
import "../../utils/SafeMath/SafeMath.sol";
import "./LibOrder.sol";
import "./LibStatus.sol";
import "./LibPartialAmount.sol";
import "../../utils/LibBytes/LibBytes.sol";

contract MixinMatchOrders is
    SafeMath,
    LibBytes,
    LibStatus,
    LibOrder,
    LibPartialAmount,
    MExchangeCore,
    MMatchOrders,
    MSettlement,
    MTransactions
    {

    /// @dev Validates context for matchOrders. Succeeds or throws.
    /// @param left First order to match.
    /// @param right Second order to match.
    function validateMatchOrdersContextOrRevert(
        Order memory left,
        Order memory right)
        internal
    {
        // The Left Order's maker asset must be the same as the Right Order's taker asset.
        require(areBytesEqual(left.makerAssetData, right.takerAssetData));

        // The Left Order's taker asset must be the same as the Right Order's maker asset.
        require(areBytesEqual(left.takerAssetData, right.makerAssetData));

        // Make sure there is a positive spread.
        // There is a positive spread iff the cost per unit bought (MakerAmount/TakerAmount) for each order is greater
        // than the profit per unit sold of the matched order (TakerAmount/MakerAmount).
        // This is satisfied by the equations below:
        // <left.makerAssetAmount> / <left.takerAssetAmount> >= <right.takerAssetAmount> / <right.makerAssetAmount>
        // AND
        // <right.makerAssetAmount> / <right.takerAssetAmount> >= <left.takerAssetAmount> / <left.makerAssetAmount>
        // These equations can be combined to get the following:
        require(safeMul(left.makerAssetAmount, right.makerAssetAmount) >= safeMul(left.takerAssetAmount, right.takerAssetAmount));
    }

    /// @dev Validates context for matchOrders.
    ///      Each order is filled at their respective price point. However, the calculations are
    ///      carried out as though the orders are both being filled at the right order's price point.
    ///      The profit made by the left order goes to the taker (who matched the two orders).
    /// @param left First order to match.
    /// @param right Second order to match.
    /// @param leftStatus Order status of left order.
    /// @param rightStatus Order status of right order.
    /// @param leftFilledAmount Amount of left order already filled.
    /// @param rightFilledAmount Amount of right order already filled.
    /// @return status Return status of calculating fill amounts. Returns Status.SUCCESS on success.
    /// @return matchedFillOrderAmounts Amounts to fill left and right orders.
    function getMatchedFillAmounts(
        Order memory left,
        Order memory right,
        uint8 leftStatus,
        uint8 rightStatus,
        uint256 leftFilledAmount,
        uint256 rightFilledAmount)
        internal
        returns (
            uint8 status,
            MatchedOrderFillAmounts memory matchedFillOrderAmounts)
    {
        // We settle orders at the price point defined by the right order (profit goes to the order taker)
        // The constraint can be either on the left or on the right.
        // The constraint is on the left iff the amount required to fill the left order
        // is less than or equal to the amount we can spend from the right order:
        //    <leftTakerAssetAmountRemaining> <= <rightTakerAssetAmountRemaining> * <rightMakerToTakerRatio>
        //    <leftTakerAssetAmountRemaining> <= <rightTakerAssetAmountRemaining> * <right.makerAssetAmount> / <right.takerAssetAmount>
        //    <leftTakerAssetAmountRemaining> * <right.takerAssetAmount> <= <rightTakerAssetAmountRemaining> * <right.makerAssetAmount>
        uint256 rightTakerAssetAmountRemaining = safeSub(right.takerAssetAmount, rightFilledAmount);
        uint256 leftTakerAssetAmountRemaining = safeSub(left.takerAssetAmount, leftFilledAmount);
        if(safeMul(leftTakerAssetAmountRemaining, right.takerAssetAmount) <= safeMul(rightTakerAssetAmountRemaining, right.makerAssetAmount))
        {
            // Left order is the constraint: maximally fill left
            (   status,
                matchedFillOrderAmounts.left
            ) = getFillAmounts(
                left,
                leftStatus,
                leftFilledAmount,
                leftTakerAssetAmountRemaining,
                msg.sender);
            if(status != uint8(Status.SUCCESS)) {
                return;
            }

            // The right order just spent <leftTakerAssetAmountRemaining> of their maker asset to fill the left order.
            // The amount right gets in return is:
            //    <leftOrderAmountBought> * <rightProfitPerUnitSold>
            // =  <matchedFillOrderAmounts.left.takerAssetFilledAmount> * <right.takerAssetAmount> / <right.makerAssetAmount>
            if(isRoundingError(right.takerAssetAmount, right.makerAssetAmount, matchedFillOrderAmounts.left.takerAssetFilledAmount)) {
                status = uint8(Status.ROUNDING_ERROR_TOO_LARGE);
                return;
            }
            uint256 rightFill = getPartialAmount(
                right.takerAssetAmount,
                right.makerAssetAmount,
                matchedFillOrderAmounts.left.takerAssetFilledAmount);

            // Compute fill amounts for right order
            (   status,
                matchedFillOrderAmounts.right
            ) = getFillAmounts(
                right,
                rightStatus,
                rightFilledAmount,
                rightFill,
                msg.sender);
            if(status != uint8(Status.SUCCESS)) {
                return;
            }

            // The right order must spend at least as much as we're transferring to the left order's maker.
            // If the amount transferred from the right order is greater than what is transferred, it is a rounding error amount.
            // Ensure this difference is negligible by dividing the values with each other. The result should equal to ~1.
            assert(matchedFillOrderAmounts.right.makerAssetFilledAmount >= matchedFillOrderAmounts.left.takerAssetFilledAmount);
            if(isRoundingError(matchedFillOrderAmounts.right.makerAssetFilledAmount, matchedFillOrderAmounts.left.takerAssetFilledAmount, 1)) {
                status = uint8(Status.ROUNDING_ERROR_TOO_LARGE);
                return;
            }
        } else {
            // Right order is the constraint: maximally fill right
            (   status,
                matchedFillOrderAmounts.right
            ) = getFillAmounts(
                right,
                rightStatus,
                rightFilledAmount,
                rightTakerAssetAmountRemaining,
                msg.sender);
            if(status != uint8(Status.SUCCESS)) {
                return;
            }

            // The left order just spent <rightTakerAssetAmountRemaining> of their maker asset to fill the right order.
            // The amount left gets in return is:
            //    <rightOrderAmountBought> * <rightCostPerUnitSold>
            //   (let Y = <matchedFillOrderAmounts.right.takerAssetFilledAmount>; let X = matchedFillOrderAmounts.right.makerAssetFilledAmount)
            // = Y * X / Y
            // = X = <matchedFillOrderAmounts.right.makerAssetFilledAmount>
            //
            // Sanity check: that the amount transferred by the right order does not exceed the amount required to fill the left order.
            assert(matchedFillOrderAmounts.right.makerAssetFilledAmount <= leftTakerAssetAmountRemaining);
            (   status,
                matchedFillOrderAmounts.left
            ) = getFillAmounts(
                left,
                leftStatus,
                leftFilledAmount,
                matchedFillOrderAmounts.right.makerAssetFilledAmount,
                msg.sender);
            if(status != uint8(Status.SUCCESS)) {
                return;
            }

            // Sanity check: the amount sent from the right order must equal the amount received by the left order.
            assert(matchedFillOrderAmounts.right.makerAssetFilledAmount == matchedFillOrderAmounts.left.takerAssetFilledAmount);
        }
    }

    /// @dev Match two complementary orders that have a positive spread.
    ///      Each order is filled at their respective price point. However, the calculations are
    ///      carried out as though the orders are both being filled at the right order's price point.
    ///      The profit made by the left order goes to the taker (who matched the two orders).
    /// @param left First order to match.
    /// @param right Second order to match.
    /// @param leftSignature Proof that order was created by the left maker.
    /// @param rightSignature Proof that order was created by the right maker.
    /// @return leftFillResults Amounts filled and fees paid by maker and taker of left order.
    /// @return leftFillResults Amounts filled and fees paid by maker and taker of right order.
    function matchOrders(
        Order memory left,
        Order memory right,
        bytes leftSignature,
        bytes rightSignature)
        public
        returns (
            MatchedOrderFillAmounts memory matchedFillOrderAmounts)
    {
        // Get left status
        uint8 leftStatus;
        bytes32 leftOrderHash;
        uint256 leftFilledAmount;
        (   leftStatus,
            leftOrderHash,
            leftFilledAmount
        ) = getOrderStatus(left);
        if(leftStatus != uint8(Status.ORDER_FILLABLE)) {
            emit ExchangeStatus(uint8(leftStatus), leftOrderHash);
            return;
        }

        // Get right status
        uint8 rightStatus;
        bytes32 rightOrderHash;
        uint256 rightFilledAmount;
        (   rightStatus,
            rightOrderHash,
            rightFilledAmount
        ) = getOrderStatus(right);
        if(rightStatus != uint8(Status.ORDER_FILLABLE)) {
            emit ExchangeStatus(uint8(rightStatus), leftOrderHash);
            return;
        }

        // Fetch taker address
        address takerAddress = getCurrentContextAddress();

        // Either our context is valid or we revert
        validateMatchOrdersContextOrRevert(left, right);

        // Compute proportional fill amounts
        uint8 matchedFillAmountsStatus;
        (   matchedFillAmountsStatus,
            matchedFillOrderAmounts
        ) = getMatchedFillAmounts(
            left,
            right,
            leftStatus,
            rightStatus,
            leftFilledAmount,
            rightFilledAmount);
        if(matchedFillAmountsStatus != uint8(Status.SUCCESS)) {
            return;
        }

        // Settle matched orders. Succeeds or throws.
        settleMatchedOrders(left, right, matchedFillOrderAmounts, takerAddress);

        // Update exchange state
        updateFilledState(
            left,
            right.makerAddress,
            leftOrderHash,
            matchedFillOrderAmounts.left
        );
        updateFilledState(
            right,
            left.makerAddress,
            rightOrderHash,
            matchedFillOrderAmounts.right
        );

        // Return results
        return matchedFillOrderAmounts;
    }
}
