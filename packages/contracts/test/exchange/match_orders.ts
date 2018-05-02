import { LogWithDecodedArgs, ZeroEx } from '0x.js';
import { BlockchainLifecycle } from '@0xproject/dev-utils';
import { BigNumber } from '@0xproject/utils';
import * as chai from 'chai';
import ethUtil = require('ethereumjs-util');
import * as _ from 'lodash';

import { DummyERC20TokenContract } from '../../src/contract_wrappers/generated/dummy_e_r_c20_token';
import { DummyERC721TokenContract } from '../../src/contract_wrappers/generated/dummy_e_r_c721_token';
import { ERC20ProxyContract } from '../../src/contract_wrappers/generated/e_r_c20_proxy';
import { ERC721ProxyContract } from '../../src/contract_wrappers/generated/e_r_c721_proxy';
import {
    CancelContractEventArgs,
    ExchangeContract,
    ExchangeStatusContractEventArgs,
    FillContractEventArgs,
} from '../../src/contract_wrappers/generated/exchange';
import { assetProxyUtils } from '../../src/utils/asset_proxy_utils';
import { constants } from '../../src/utils/constants';
import { crypto } from '../../src/utils/crypto';
import { ERC20Wrapper } from '../../src/utils/erc20_wrapper';
import { ERC721Wrapper } from '../../src/utils/erc721_wrapper';
import { ExchangeWrapper } from '../../src/utils/exchange_wrapper';
import { OrderFactory } from '../../src/utils/order_factory';
import { orderUtils } from '../../src/utils/order_utils';
import { AssetProxyId, ContractName, ERC20BalancesByOwner, ExchangeStatus, SignedOrder } from '../../src/utils/types';
import { chaiSetup } from '../utils/chai_setup';
import { deployer } from '../utils/deployer';
import { provider, web3Wrapper } from '../utils/web3_wrapper';

chaiSetup.configure();
const expect = chai.expect;
const blockchainLifecycle = new BlockchainLifecycle(web3Wrapper);

describe.only('MatchOrders', () => {
    let makerAddressLeft: string;
    let makerAddressRight: string;
    let owner: string;
    let takerAddress: string;
    let feeRecipientAddressLeft: string;
    let feeRecipientAddressRight: string;

    let erc20TokenA: DummyERC20TokenContract;
    let erc20TokenB: DummyERC20TokenContract;
    let zrxToken: DummyERC20TokenContract;
    let erc721Token: DummyERC721TokenContract;
    let exchange: ExchangeContract;
    let erc20Proxy: ERC20ProxyContract;
    let erc721Proxy: ERC721ProxyContract;

    let signedOrder: SignedOrder;
    let erc20Balances: ERC20BalancesByOwner;
    let exchangeWrapper: ExchangeWrapper;
    let erc20Wrapper: ERC20Wrapper;
    let erc721Wrapper: ERC721Wrapper;
    let orderFactoryLeft: OrderFactory;
    let orderFactoryRight: OrderFactory;

    let erc721MakerAssetIds: BigNumber[];
    let erc721TakerAssetIds: BigNumber[];

    let defaultMakerAssetAddress: string;
    let defaultTakerAssetAddress: string;

    let zeroEx: ZeroEx;

    before(async () => {
        const accounts = await web3Wrapper.getAvailableAddressesAsync();
        const usedAddresses = ([
            owner,
            makerAddressLeft,
            makerAddressRight,
            takerAddress,
            feeRecipientAddressLeft,
            feeRecipientAddressRight,
        ] = accounts);

        erc20Wrapper = new ERC20Wrapper(deployer, provider, usedAddresses, owner);
        erc721Wrapper = new ERC721Wrapper(deployer, provider, usedAddresses, owner);

        [erc20TokenA, erc20TokenB, zrxToken] = await erc20Wrapper.deployDummyTokensAsync();
        erc20Proxy = await erc20Wrapper.deployProxyAsync();
        await erc20Wrapper.setBalancesAndAllowancesAsync();

        [erc721Token] = await erc721Wrapper.deployDummyTokensAsync();
        erc721Proxy = await erc721Wrapper.deployProxyAsync();
        await erc721Wrapper.setBalancesAndAllowancesAsync();
        const erc721Balances = await erc721Wrapper.getBalancesAsync();
        erc721MakerAssetIds = erc721Balances[makerAddressLeft][erc721Token.address];
        erc721MakerAssetIds = erc721Balances[makerAddressRight][erc721Token.address];
        erc721TakerAssetIds = erc721Balances[takerAddress][erc721Token.address];

        const exchangeInstance = await deployer.deployAsync(ContractName.Exchange, [
            assetProxyUtils.encodeERC20ProxyData(zrxToken.address),
        ]);
        exchange = new ExchangeContract(exchangeInstance.abi, exchangeInstance.address, provider);
        zeroEx = new ZeroEx(provider, {
            exchangeContractAddress: exchange.address,
            networkId: constants.TESTRPC_NETWORK_ID,
        });
        exchangeWrapper = new ExchangeWrapper(exchange, zeroEx);
        await exchangeWrapper.registerAssetProxyAsync(AssetProxyId.ERC20, erc20Proxy.address, owner);
        await exchangeWrapper.registerAssetProxyAsync(AssetProxyId.ERC721, erc721Proxy.address, owner);

        await erc20Proxy.addAuthorizedAddress.sendTransactionAsync(exchange.address, {
            from: owner,
        });
        await erc721Proxy.addAuthorizedAddress.sendTransactionAsync(exchange.address, {
            from: owner,
        });

        defaultMakerAssetAddress = erc20TokenA.address;
        defaultTakerAssetAddress = erc20TokenB.address;

        const defaultOrderParams = {
            ...constants.STATIC_ORDER_PARAMS,
            exchangeAddress: exchange.address,
            makerAssetData: assetProxyUtils.encodeERC20ProxyData(defaultMakerAssetAddress),
            takerAssetData: assetProxyUtils.encodeERC20ProxyData(defaultTakerAssetAddress),
        };
        const privateKeyLeft = constants.TESTRPC_PRIVATE_KEYS[accounts.indexOf(makerAddressLeft)];
        orderFactoryLeft = new OrderFactory(privateKeyLeft, defaultOrderParams);

        const privateKeyRight = constants.TESTRPC_PRIVATE_KEYS[accounts.indexOf(makerAddressRight)];
        orderFactoryRight = new OrderFactory(privateKeyRight, defaultOrderParams);
    });
    beforeEach(async () => {
        await blockchainLifecycle.startAsync();
    });
    afterEach(async () => {
        await blockchainLifecycle.revertAsync();
    });
    describe('internal functions', () => {
        it('should include transferViaTokenTransferProxy', () => {
            expect((exchange as any).transferViaTokenTransferProxy).to.be.undefined();
        });
    });

    describe('matchOrders', () => {
        beforeEach(async () => {
            erc20Balances = await erc20Wrapper.getBalancesAsync();
        });

        it('should transfer the correct amounts when orders fill each other perfectly', async () => {
            const signedOrderLeft = orderFactoryLeft.newSignedOrder({
                makerAddress: makerAddressLeft,
                makerAssetData: assetProxyUtils.encodeERC20ProxyData(defaultMakerAssetAddress),
                takerAssetData: assetProxyUtils.encodeERC20ProxyData(defaultTakerAssetAddress),
                makerAssetAmount: new BigNumber(5),
                takerAssetAmount: new BigNumber(10),
                feeRecipientAddress: feeRecipientAddressLeft,
            });

            const signedOrderRight = orderFactoryRight.newSignedOrder({
                makerAddress: makerAddressRight,
                makerAssetData: assetProxyUtils.encodeERC20ProxyData(defaultTakerAssetAddress),
                takerAssetData: assetProxyUtils.encodeERC20ProxyData(defaultMakerAssetAddress),
                makerAssetAmount: new BigNumber(10),
                takerAssetAmount: new BigNumber(2),
                feeRecipientAddress: feeRecipientAddressRight,
            });

            const takerAssetFilledAmountBefore = await exchangeWrapper.getTakerAssetFilledAmountAsync(
                orderUtils.getOrderHashHex(signedOrderLeft),
            );
            expect(takerAssetFilledAmountBefore).to.be.bignumber.equal(0);

            await exchangeWrapper.matchOrdersAsync(signedOrderLeft, signedOrderRight, takerAddress);

            // Find the amount bought from each order
            const amountBoughtByLeftMaker = await exchangeWrapper.getTakerAssetFilledAmountAsync(
                orderUtils.getOrderHashHex(signedOrderLeft),
            );

            const amountBoughtByRightMaker = await exchangeWrapper.getTakerAssetFilledAmountAsync(
                orderUtils.getOrderHashHex(signedOrderRight),
            );

            console.log('amountBoughtByLeftMaker = ' + amountBoughtByLeftMaker);
            console.log('amountBoughtByRightMaker = ' + amountBoughtByRightMaker);

            const newBalances = await erc20Wrapper.getBalancesAsync();

            const amountSoldByLeftMaker = amountBoughtByLeftMaker
                .times(signedOrderLeft.makerAssetAmount)
                .dividedToIntegerBy(signedOrderLeft.takerAssetAmount);

            const amountSoldByRightMaker = amountBoughtByRightMaker
                .times(signedOrderRight.makerAssetAmount)
                .dividedToIntegerBy(signedOrderRight.takerAssetAmount);

            const amountReceivedByRightMaker = amountBoughtByLeftMaker
                .times(signedOrderRight.takerAssetAmount)
                .dividedToIntegerBy(signedOrderRight.makerAssetAmount);

            const amountReceivedByLeftMaker = amountSoldByRightMaker;

            const amountReceivedByTaker = amountSoldByLeftMaker.minus(amountReceivedByRightMaker);

            console.log('amountSoldByLeftMaker = ' + amountSoldByLeftMaker);
            console.log('amountSoldByRightMaker = ' + amountSoldByRightMaker);
            console.log('amountReceivedByLeftMaker = ' + amountReceivedByLeftMaker);
            console.log('amountReceivedByRightMaker = ' + amountReceivedByRightMaker);
            console.log('amountReceivedByTaker = ' + amountReceivedByTaker);

            const makerAssetAddressLeft = defaultMakerAssetAddress;
            const takerAssetAddressLeft = defaultTakerAssetAddress;
            const makerAssetAddressRight = defaultTakerAssetAddress;
            const takerAssetAddressRight = defaultMakerAssetAddress;

            // Verify Makers makerAsset
            expect(newBalances[makerAddressLeft][makerAssetAddressLeft]).to.be.bignumber.equal(
                erc20Balances[makerAddressLeft][makerAssetAddressLeft].minus(amountSoldByLeftMaker),
            );

            expect(newBalances[makerAddressRight][makerAssetAddressRight]).to.be.bignumber.equal(
                erc20Balances[makerAddressRight][makerAssetAddressRight].minus(amountSoldByRightMaker),
            );

            // Verify Maker's takerAssetAddressLeft
            expect(newBalances[makerAddressLeft][takerAssetAddressLeft]).to.be.bignumber.equal(
                erc20Balances[makerAddressLeft][takerAssetAddressLeft].add(amountReceivedByLeftMaker),
            );

            expect(newBalances[makerAddressRight][takerAssetAddressRight]).to.be.bignumber.equal(
                erc20Balances[makerAddressRight][takerAssetAddressRight].add(amountReceivedByRightMaker),
            );

            // Verify Taker's assets
            expect(newBalances[takerAddress][makerAssetAddressLeft]).to.be.bignumber.equal(
                erc20Balances[takerAddress][makerAssetAddressLeft].add(amountReceivedByTaker),
            );
            expect(newBalances[takerAddress][takerAssetAddressLeft]).to.be.bignumber.equal(
                erc20Balances[takerAddress][takerAssetAddressLeft],
            );
            expect(newBalances[takerAddress][makerAssetAddressRight]).to.be.bignumber.equal(
                erc20Balances[takerAddress][makerAssetAddressRight],
            );
            expect(newBalances[takerAddress][takerAssetAddressRight]).to.be.bignumber.equal(
                erc20Balances[takerAddress][takerAssetAddressRight].add(amountReceivedByTaker),
            );

            // Verify Fees - Left Maker

            const leftMakerFeePaid = signedOrderLeft.makerFee
                .times(amountSoldByLeftMaker)
                .dividedToIntegerBy(signedOrderLeft.makerAssetAmount);
            expect(newBalances[makerAddressLeft][zrxToken.address]).to.be.bignumber.equal(
                erc20Balances[makerAddressLeft][zrxToken.address].minus(leftMakerFeePaid),
            );

            // Verify Fees - Right Maker
            const rightMakerFeePaid = signedOrderRight.makerFee
                .times(amountSoldByRightMaker)
                .dividedToIntegerBy(signedOrderRight.makerAssetAmount);
            expect(newBalances[makerAddressRight][zrxToken.address]).to.be.bignumber.equal(
                erc20Balances[makerAddressRight][zrxToken.address].minus(rightMakerFeePaid),
            );

            // Verify Fees - Taker
            const takerFeePaidLeft = signedOrderLeft.takerFee
                .times(amountSoldByLeftMaker)
                .dividedToIntegerBy(signedOrderLeft.makerAssetAmount);
            const takerFeePaidRight = signedOrderRight.takerFee
                .times(amountSoldByRightMaker)
                .dividedToIntegerBy(signedOrderRight.makerAssetAmount);
            const takerFeePaid = takerFeePaidLeft.add(takerFeePaidRight);
            expect(newBalances[takerAddress][zrxToken.address]).to.be.bignumber.equal(
                erc20Balances[takerAddress][zrxToken.address].minus(takerFeePaid),
            );

            // Verify Fees - Left Fee Recipient
            const feesReceivedLeft = leftMakerFeePaid.add(takerFeePaidLeft);
            expect(newBalances[feeRecipientAddressLeft][zrxToken.address]).to.be.bignumber.equal(
                erc20Balances[feeRecipientAddressLeft][zrxToken.address].add(feesReceivedLeft),
            );

            // Verify Fees - Right Fee Receipient
            const feesReceivedRight = rightMakerFeePaid.add(takerFeePaidRight);
            expect(newBalances[feeRecipientAddressRight][zrxToken.address]).to.be.bignumber.equal(
                erc20Balances[feeRecipientAddressRight][zrxToken.address].add(feesReceivedLeft),
            );
        });
    });
}); // tslint:disable-line:max-file-line-count