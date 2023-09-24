import Trie "mo:base/Trie";
import List "mo:base/List";
import Iter "mo:base/Iter";
import Buffer "mo:base/Buffer";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Time "mo:base/Time";
import Option "mo:base/Option";
import Tools "Tools";
module {
    public type BlockHeight = Nat;
    public type Timestamp = Nat; // seconds
    public type AccountId = Blob;
    public type ListPage = Nat;
    public type ListSize = Nat;
    public type TrieList<K, V> = {data: [(K, V)]; total: Nat; totalPage: Nat; };

    public type ICEvents<T> = Trie.Trie<BlockHeight, (T, Timestamp)>;
    public type AccountEvents = Trie.Trie<AccountId, List.List<BlockHeight>>;

    private func keyb(t: Blob) : Trie.Key<Blob> { return { key = t; hash = Blob.hash(t) }; };
    private func keyn(t: Nat) : Trie.Key<Nat> { return { key = t; hash = Tools.natHash(t) }; };

    public func now() : Timestamp{
        return Int.abs(Time.now() / 1000000000);
    };
    public func trieItems2<V>(_trie: Trie.Trie<Nat, V>, _firstIndex: Nat, _height: Nat, _page: ListPage, _size: ListSize) : TrieList<Nat, V>{
        var length = Nat.sub(_height, _firstIndex);
        if (length == 0){
            return {data = []; totalPage = 0; total = 0};
        };
        let page = _page;
        let size = Nat.max(_size, 1);
        let start = Nat.sub(_height, Nat.sub(page, 1) * size);
        var data : [(Nat, V)] = [];
        var i: Nat = start;
        while(i > 0 and Nat.sub(start, i) < size){
            i -= 1;
            switch(Trie.get<Nat, V>(_trie, keyn(i), Nat.equal)){
                case(?(item)){ data := Tools.arrayAppend(data, [(i, item)]); };
                case(_){};
            };
        };
        return {data = data; totalPage = Nat.sub(Nat.max(length,1), 1) / size + 1; total = length};
    };

    public func putAccountEvent(_var: AccountEvents, _firstIndex: Nat, _a: AccountId, _blockIndex: BlockHeight) : AccountEvents{
        var res : AccountEvents = Trie.empty();
        switch(Trie.get(_var, keyb(_a), Blob.equal)){
            case(?(ids)){
                var list = List.push(_blockIndex, ids);
                if (_firstIndex > 0){ // Option.get(List.last(ids), 0) < _firstIndex
                    var i : Nat = 0;
                    list := List.filter(list, func (t: Nat): Bool{ 
                        i += 1;
                        t >= _firstIndex and i <= 10000
                    });
                };
                res := Trie.put(_var, keyb(_a), Blob.equal, list).0;
            };
            case(_){
                res := Trie.put(_var, keyb(_a), Blob.equal, List.push(_blockIndex, null)).0;
            };
        };
        return res;
    };
    public func getEvent<T>(_var: ICEvents<T>, _blockIndex: BlockHeight) : ?(T, Timestamp){
        switch(Trie.get(_var, keyn(_blockIndex), Nat.equal)){
            case(?(event)){ return ?event };
            case(_){ return null };
        };
    };
    public func getEvents<T>(_var: ICEvents<T>, _start : BlockHeight, _length : Nat) : [(T, Timestamp)]{
        assert(_length > 0);
        var events : [(T, Timestamp)] = [];
        for (index in Iter.range(_start, _start + _length - 1)){
            switch(Trie.get(_var, keyn(index), Nat.equal)){
                case(?(event)){ events := Tools.arrayAppend([event], events)};
                case(_){};
            };
        };
        return events;
    };
    public func putEvent<T>(_var: ICEvents<T>, _blockIndex: BlockHeight, _event: T) : ICEvents<T>{
        return Trie.put(_var, keyn(_blockIndex), Nat.equal, (_event, now())).0;
    };
    public func clearEvents<T>(_var: ICEvents<T>, _clearFrom: BlockHeight, _clearTo: BlockHeight) : ICEvents<T>{
        var res : ICEvents<T> = _var;
        for (i in Iter.range(_clearFrom, _clearTo)){
            res := Trie.remove(res, keyn(i), Nat.equal).0;
        };
        return res;
    };

    public func getAccountEvents<T>(_events: ICEvents<T>, _list: AccountEvents, _accountId: AccountId) : [(T, Timestamp)]{ //latest 1000 records
        switch(Trie.get(_list, keyb(_accountId), Blob.equal)){
            case(?(ids)){
                var i : Nat = 0;
                return Array.mapFilter(List.toArray(ids), func (t: BlockHeight): ?(T, Timestamp){
                    i += 1;
                    if (i <= 1000){
                        return getEvent(_events, t);
                    }else{
                        return null;
                    };
                });
            };
            case(_){};
        };
        return [];
    };

};