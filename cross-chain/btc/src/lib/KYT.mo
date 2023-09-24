/**
 * Module     : KYT Module
 * Author     : ICLighthouse Team
 * Stability  : Experimental
 * Github     : https://github.com/iclighthouse/
 */

import Trie "mo:base/Trie";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Text "mo:base/Text";
import Option "mo:base/Option";
import Hex "Hex";
import Tools "Tools";

module {
    public type Account = { owner : Principal; subaccount : ?[Nat8] };
    public type AccountId = Blob;
    public type Address = Text;
    public type TxHash = Text;
    public type HashId = Blob;
    public type TokenId = Blob;
    public type TokenCanisterId = Principal;
    public type Chain = Text;
    public type ICAccount = (TokenCanisterId, Account);
    public type ChainAccount = (Chain, TokenId, Address);
    public type AccountAddresses = Trie.Trie<AccountId, [ChainAccount]>;
    public type AddressAccounts = Trie.Trie<Address, [ICAccount]>;
    public type TxAccounts = Trie.Trie<HashId, [(ChainAccount, ICAccount)]>;
    public type KYT_DATA = (AccountAddresses, AddressAccounts, TxAccounts);

    private func keyb(t: Blob) : Trie.Key<Blob> { return { key = t; hash = Blob.hash(t) }; };
    private func keyt(t: Text) : Trie.Key<Text> { return { key = t; hash = Text.hash(t) }; };
    private func _accountId(_owner: Principal, _subaccount: ?[Nat8]) : Blob{
        return Blob.fromArray(Tools.principalToAccount(_owner, _subaccount));
    };
    public func fromHex(_hexWith0x: Text) : ?[Nat8]{
        if (_hexWith0x.size() >= 2){
            var hex = Option.get(Text.stripStart(_hexWith0x, #text("0x")), _hexWith0x);
            if (hex.size() % 2 > 0){ hex := "0"#hex; };
            if (hex == "") { return ?[] };
            switch(Hex.decode(hex)){
                case(#ok(r)){ return ?r; };
                case(_){ return null; };
            };
        };
        return null;
    };

    public func putAddressAccount(_data0: AccountAddresses, _data1: AddressAccounts, _address: ChainAccount, _account: ICAccount) : (AccountAddresses, AddressAccounts){
        var kyt_accountAddresses = _data0;
        var kyt_addressAccounts = _data1;
        let account = _account.1;
        let accountId = _accountId(account.owner, account.subaccount);
        switch(Trie.get(kyt_accountAddresses, keyb(accountId), Blob.equal)){
            case(?values){
                let _values = Array.filter(values, func (t: ChainAccount): Bool{ _address != t });
                kyt_accountAddresses := Trie.put(kyt_accountAddresses, keyb(accountId), Blob.equal, Tools.arrayAppend(_values, [_address])).0;
            };
            case(_){
                kyt_accountAddresses := Trie.put(kyt_accountAddresses, keyb(accountId), Blob.equal, [_address]).0;
            };
        };
        let address = _address.2;
        switch(Trie.get(kyt_addressAccounts, keyt(address), Text.equal)){
            case(?values){
                let _values = Array.filter(values, func (t: ICAccount): Bool{ _account != t });
                kyt_addressAccounts := Trie.put(kyt_addressAccounts, keyt(address), Text.equal, Tools.arrayAppend(_values, [_account])).0;
            };
            case(_){
                kyt_addressAccounts := Trie.put(kyt_addressAccounts, keyt(address), Text.equal, [_account]).0;
            };
        };
        return (kyt_accountAddresses, kyt_addressAccounts);
    };
    public func getAccountAddress(_data: AccountAddresses, _accountId: AccountId) : ?[ChainAccount]{
        return Trie.get(_data, keyb(_accountId), Blob.equal);
    };
    public func getAddressAccount(_data: AddressAccounts, _address: Address) : ?[ICAccount]{
        return Trie.get(_data, keyt(_address), Text.equal);
    };
    public func putTxAccount(_data: TxAccounts, _txHash: TxHash, _address: ChainAccount, _account: ICAccount) : TxAccounts{
        var kyt_txAccounts = _data;
        let hashId = Blob.fromArray(Option.get(fromHex(_txHash), []));
        switch(Trie.get(kyt_txAccounts, keyb(hashId), Blob.equal)){
            case(?values){
                let _values = Array.filter(values, func (t: (ChainAccount, ICAccount)): Bool{ _address != t.0 or _account != t.1 });
                kyt_txAccounts := Trie.put(kyt_txAccounts, keyb(hashId), Blob.equal, Tools.arrayAppend(_values, [(_address, _account)])).0;
            };
            case(_){
                kyt_txAccounts := Trie.put(kyt_txAccounts, keyb(hashId), Blob.equal, [(_address, _account)]).0;
            };
        };
        return kyt_txAccounts;
    };
    public func getTxAccount(_data: TxAccounts, _txHash: TxHash) : ?[(ChainAccount, ICAccount)]{
        let hashId = Blob.fromArray(Option.get(fromHex(_txHash), []));
        return Trie.get(_data, keyb(hashId), Blob.equal);
    };

};