# icRouter

icRouter is a token cross-chain infrastructure.


A cross-chain network of assets based on threshold signature technology, with no off-chain bridges, supporting Bitcoin, IC, and EVM networks (e.g., Ethereum).

In the past two years, a large number of cross-chain bridges have been attacked due to centralized node issues, resulting in billions of dollars in losses. 

With the development of threshold signature technology, which provides the possibility to implement asset cross-chain without off-chain bridge approach, IC Network's t-ECDSA technology has successfully implemented Bitcoin integration, which is implemented in a fully on-chain approach. This technology improves cross-chain security and reduces attack vectors.

The goal of the project is to implement a cross-chain network that enables the transfer of mainstream public chain assets to each other, supporting Bitcoin, EVM Blockchain, and more. We use IC network as information routing and asset routing to achieve bridgeless asset cross-chaining. 

Integration achieved:
- Bitcoin (BTC) <> IC
- Ethereum (ETH/ERC20) <> IC

## icBTCMinter

icBTCMinter is the integration of Bitcoin and IC network through the Threshold Signature Scheme (TSS, also known as chain-key technology). 

icBTCMinter is a dApp of SNS (ICLighthouse), with all administrative privileges given to SNS.  
Steps to register as a dApp of SNS:
- Add SNS Root as one of the controllers of icBTCMinter.
- Submit a proposal to SNS to add the dApp.
- Call changeOwner() method to set SNS governance as owner.

[More information ..](btc/)

## icETHMinter

icETHMinter is the integration of Ethereum and IC network through the Threshold Signature Scheme (TSS, also known as chain-key technology).

icETHMinter is a dApp of SNS (ICLighthouse), with all administrative privileges given to SNS.  
Steps to register as a dApp of SNS:
- Add SNS Root as one of the controllers of icETHMinter.
- Submit a proposal to SNS to add the dApp.
- Call changeOwner() method to set SNS governance as owner.
- Call the setKeeper() method to manage the keepers, who are providers of RPC URLs.

[More information ..](eth/)