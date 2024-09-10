#!/usr/local/bin/ic-repl -r ic
identity default "~/.config/dfx/identity/${IdentityName:-default}/identity.pem";
import Minter = "${Minter}" as "../${MinterDid}";
call Minter.setCkTokenWasm(file("icToken.wasm"),"${TokenVersion}", null);