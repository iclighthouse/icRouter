# icETH

icRouter enables the integration of Ethereum and IC network through the Threshold Signature Scheme (TSS, also known as chain-key technology). 
icETH and icERC20 are 1:1 ICRC1 tokens minted after cross-chaining from ethereum to IC network, and you can retrieve the original ethereum tokens at any time. This is all done in a bridgeless way, and their security depends on the security of IC network.

## About Ethereum Integration

A true World Computer enables a multi-chain environment where centralized bridges are obsolete and smart contracts can seamlessly communicate across blockchains. ICP already integrates with the Bitcoin and Ethereum networks.

https://internetcomputer.org/ethereum-integration

## Introduction

The integration of ethereum on the IC network without bridges is achieved through chain-key (threshold signature) technology for ECDSA signatures, and the smart contracts of IC can directly access the RPC nodes of ethereum through HTTPS Outcall technology. This is the technical solution implemented in stage 1, which can be decentralized by configuring multiple RPC API providers. 

The user sends an ethereum asset, ETH or ERC20 token, to an address controlled by the IC smart contract (Minter), which receives the ethereum asset and mint icETH or icERC20 token on the IC network at a 1:1 ratio. When users want to retrieve the real ethereum asset, they only need to return icETH or icERC20 token to Minter smart contract to retrieve the ethereum assets.

### Minter Smart Contract

By chain-key (threshold signature) technology to manage the transfer of assets between the ethereum and IC networks, no one holds the private key of the Minter smart contract's account on ethereum, and its private key fragments are held by the IC network nodes. So its security depends on the security of the IC network.

## Usage

UI: http://iclight.io or other wallets.

### Interface for command line or developer

### 1. ETH -> icETH & ERC20 -> icERC20

(1) Get the ethereum address used for deposit.
```
get_deposit_address: (_owner: Account) -> (EthAddress);
```

(2) Send ETH or ERC20 to the dedicated deposit address.

(3) Minting icETH or icERC20. Should wait for network confirmation before calling this method.
```
update_balance: (_token: opt EthAddress, _owner: Account) -> (variant {
       Err: ResultError;
       Ok: UpdateBalanceResult;
});
```

### 2. icETH -> ETH & icERC20 -> ERC20

(1) Get the IC account used for depositing icETH/icERC20.
```
get_withdrawal_account: (_owner: Account) -> (Account) query;
```

(2) Send icETH or icERC20 to the dedicated deposit account.

(3) Retrieving ETH or ERC20 token. 
```
retrieve: (_token: opt EthAddress, _address: EthAddress, _amount: Wei, _subaccount: opt vec nat8) -> (variant {
       Err: ResultError;
       Ok: RetrieveResult;
});
```

## Demo

http://iclight.io

## Related technologies used

- Threshold ECDSA https://github.com/dfinity/examples/tree/master/motoko/threshold-ecdsa
- libsecp256k1 https://github.com/av1ctor/libsecp256k1.mo

