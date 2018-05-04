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
import "./MMatchOrders.sol";

contract MSettlement is LibOrder, MMatchOrders {

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
        );

    /// @dev Settles matched order by transferring appropriate funds between order makers, taker, and fee recipient.
    /// @param leftOrder First matched order.
    /// @param rightOrder Second matched order.
    /// @param matchedFillOrderAmounts Struct holding amounts to transfer between makers, taker, and fee recipients.
    /// @param taker Address that matched the orders. The taker receives the spread between orders as profit.
    function settleMatchedOrders(
        Order memory leftOrder,
        Order memory rightOrder,
        MatchedOrderFillAmounts memory matchedFillOrderAmounts,
        address taker)
        internal;
}
