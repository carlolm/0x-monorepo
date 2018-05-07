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

import "./mixins/MSettlement.sol";
import "./mixins/MAssetProxyDispatcher.sol";
import "./LibPartialAmount.sol";
import "../AssetProxy/IAssetProxy.sol";
import "./mixins/MMatchOrders.sol";

/// @dev Provides MixinSettlement
contract MixinSettlement is
    LibOrder,
    LibPartialAmount,
    MMatchOrders,
    MSettlement,
    MAssetProxyDispatcher
{
    bytes ZRX_PROXY_DATA;

    function zrxProxyData()
        external view
        returns (bytes memory)
    {
        return ZRX_PROXY_DATA;
    }

    function MixinSettlement(bytes memory _zrxProxyData)
        public
    {
        ZRX_PROXY_DATA = _zrxProxyData;
    }

    /// @dev Settles an order by transferring appropriate funds between maker, taker, and fee recipient.
    /// @param order Order struct containing order specifications.
    /// @param takerAddress Address of order taker.
    /// @param takerAssetFilledAmount Amount of order filled by the taker.
    /// @return makerAssetFilledAmount Amount spent by order maker.
    /// @return makerFeePaid Fee amount paid by maker.
    /// @return takerFeePaid Fee amount paid by taker.
    function settleOrder(
        Order memory order,
        address takerAddress,
        uint256 takerAssetFilledAmount)
        internal
        returns (
            uint256 makerAssetFilledAmount,
            uint256 makerFeePaid,
            uint256 takerFeePaid
        )
    {
        makerAssetFilledAmount = getPartialAmount(takerAssetFilledAmount, order.takerAssetAmount, order.makerAssetAmount);
        dispatchTransferFrom(
            order.makerAssetData,
            order.makerAddress,
            takerAddress,
            makerAssetFilledAmount
        );
        dispatchTransferFrom(
            order.takerAssetData,
            takerAddress,
            order.makerAddress,
            takerAssetFilledAmount
        );
        makerFeePaid = getPartialAmount(takerAssetFilledAmount, order.takerAssetAmount, order.makerFee);
        dispatchTransferFrom(
            ZRX_PROXY_DATA,
            order.makerAddress,
            order.feeRecipientAddress,
            makerFeePaid
        );
        takerFeePaid = getPartialAmount(takerAssetFilledAmount, order.takerAssetAmount, order.takerFee);
        dispatchTransferFrom(
            ZRX_PROXY_DATA,
            takerAddress,
            order.feeRecipientAddress,
            takerFeePaid
        );
        return (makerAssetFilledAmount, makerFeePaid, takerFeePaid);
    }

    /// @dev Settles matched order by transferring appropriate funds between order makers, taker, and fee recipient.
    /// @param leftOrder First matched order.
    /// @param rightOrder Second matched order.
    /// @param matchedFillResults Struct holding amounts to transfer between makers, taker, and fee recipients.
    /// @param takerAddress Address that matched the orders. The taker receives the spread between orders as profit.
    function settleMatchedOrders(
        Order memory leftOrder,
        Order memory rightOrder,
        MatchedFillResults memory matchedFillResults,
        address takerAddress)
        internal
    {
        // Optimized for:
        // * leftOrder.feeRecipient =?= rightOrder.feeRecipient

        // Not optimized for:
        // * {left, right}.{MakerAsset, TakerAsset} == ZRX
        // * {left, right}.maker, takerAddress == {left, right}.feeRecipient

        // leftOrder.MakerAsset == rightOrder.TakerAsset
        // Taker should be left with a positive balance (the spread)
        dispatchTransferFrom(
            leftOrder.makerAssetData,
            leftOrder.makerAddress,
            takerAddress,
            matchedFillResults.left.makerAssetFilledAmount);
        dispatchTransferFrom(
            leftOrder.makerAssetData,
            takerAddress,
            rightOrder.makerAddress,
            matchedFillResults.right.takerAssetFilledAmount);

        // rightOrder.MakerAsset == leftOrder.TakerAsset
        // leftOrder.takerAssetFilledAmount ~ rightOrder.makerAssetFilledAmount
        // The change goes to right, not to taker.
        assert(matchedFillResults.right.makerAssetFilledAmount >= matchedFillResults.left.takerAssetFilledAmount);
        dispatchTransferFrom(
            rightOrder.makerAssetData,
            rightOrder.makerAddress,
            leftOrder.makerAddress,
            matchedFillResults.right.makerAssetFilledAmount);

        // Maker fees
        dispatchTransferFrom(
            ZRX_PROXY_DATA,
            leftOrder.makerAddress,
            leftOrder.feeRecipientAddress,
            matchedFillResults.left.makerFeePaid);
        dispatchTransferFrom(
            ZRX_PROXY_DATA,
            rightOrder.makerAddress,
            rightOrder.feeRecipientAddress,
            matchedFillResults.right.makerFeePaid);

        // Taker fees
        // If we assume distinct(left, right, takerAddress) and
        // distinct(MakerAsset, TakerAsset, zrx) then the only remaining
        // opportunity for optimization is when both feeRecipientAddress' are
        // the same.
        if(leftOrder.feeRecipientAddress == rightOrder.feeRecipientAddress) {
            dispatchTransferFrom(
                ZRX_PROXY_DATA,
                takerAddress,
                leftOrder.feeRecipientAddress,
                safeAdd(
                    matchedFillResults.left.takerFeePaid,
                    matchedFillResults.right.takerFeePaid
                )
            );
        } else {
            dispatchTransferFrom(
                ZRX_PROXY_DATA,
                takerAddress,
                leftOrder.feeRecipientAddress,
                matchedFillResults.left.takerFeePaid);
            dispatchTransferFrom(
                ZRX_PROXY_DATA,
                takerAddress,
                rightOrder.feeRecipientAddress,
                matchedFillResults.right.takerFeePaid);
        }
    }
}
