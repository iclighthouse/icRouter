#!/usr/local/bin/ic-repl -r ic
identity default "~/.config/dfx/identity/${IdentityName:-default}/identity.pem";
import Minter = "${ETHMinter}" as "../did/icETHMinter.did";
call Minter.setCkTokenWasm(file("icToken.wasm"),"${TokenVersion}", null);