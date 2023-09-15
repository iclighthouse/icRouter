// https://github.com/iclighthouse/motoko-sha3

import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Nat64 "mo:base/Nat64";
import Nat8 "mo:base/Nat8";
import Buffer "mo:base/Buffer";

module Sha3 {
    private let SHA3_WORDS = 25;
    private let KECCAKF_ROUNDS = 24;
    private let KECCAKF_RNDC : [Nat64] = [
        0x0000000000000001,
        0x0000000000008082,
        0x800000000000808a,
        0x8000000080008000,
        0x000000000000808b,
        0x0000000080000001,
        0x8000000080008081,
        0x8000000000008009,
        0x000000000000008a,
        0x0000000000000088,
        0x0000000080008009,
        0x000000008000000a,
        0x000000008000808b,
        0x800000000000008b,
        0x8000000000008089,
        0x8000000000008003,
        0x8000000000008002,
        0x8000000000000080,
        0x000000000000800a,
        0x800000008000000a,
        0x8000000080008081,
        0x8000000000008080,
        0x0000000080000001,
        0x8000000080008008,
    ];
    private let KECCAKF_ROTC : [Nat64] = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44];
    private let KECCAKF_PILN : [Nat] = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1];
    private func rotl64(x : Nat64, y : Nat64) : Nat64 = (x << y) | (x >> (64 - y));
    public func keccakf(st : [var Nat64]) : () {
        var bc = Array.init<Nat64>(5, 0);
        var count : Nat64 = 0;
        for (r in Iter.range(0, KECCAKF_ROUNDS -1)) {
            // Theta
            for (i in Iter.range(0, 4)) {
                bc[i] := st[i] ^ st[i +5] ^ st[i +10] ^ st[i +15] ^ st[i +20];
            };

            for (i in Iter.range(0, 4)) {
                let t = bc[(i + 4) % 5] ^ rotl64(bc[(i + 1) % 5], 1);
                for (tj in Iter.range(i / 5, 4)) {
                    let j = tj * 5 + i;
                    st[j] ^= t;
                };
            };

            // Rho Pi
            var t = st[1];
            for (i in Iter.range(0, 23)) {
                let j = KECCAKF_PILN[i];
                bc[0] := st[j];
                st[j] := rotl64(t, KECCAKF_ROTC[i]);
                t := bc[0];
            };

            // Chi
            for (tj in Iter.range(0, 4)) {
                let j = tj * 5;
                for (i in Iter.range(0, 4)) {
                    bc[i] := st[j + i];
                };
                for (i in Iter.range(0, 4)) {
                    st[j + i] ^= (Nat64.bitnot(bc[(i + 1) % 5])) & bc[(i + 2) % 5];
                };
            };

            // Iota
            st[0] ^= KECCAKF_RNDC[r];
        };
    };

    public func toNat8Array(num : Nat64) : [Nat8] {
        [
            Nat8.fromNat(Nat64.toNat((num >> 0) & 0xFF)),
            Nat8.fromNat(Nat64.toNat((num >> 8) & 0xFF)),
            Nat8.fromNat(Nat64.toNat((num >> 16) & 0xFF)),
            Nat8.fromNat(Nat64.toNat((num >> 24) & 0xFF)),
            Nat8.fromNat(Nat64.toNat((num >> 32) & 0xFF)),
            Nat8.fromNat(Nat64.toNat((num >> 40) & 0xFF)),
            Nat8.fromNat(Nat64.toNat((num >> 48) & 0xFF)),
            Nat8.fromNat(Nat64.toNat((num >> 56) & 0xFF)),
        ];
    };

    public func to_nat8(data : [var Nat64]) : [Nat8] {
        let dat = Array.freeze(data);
        let data_len = Array.size(dat);
        var buf = Array.init<Nat8>(8 * data_len, 0);

        for (d in Iter.range(0, data_len -1)) {
            let u8 = toNat8Array(data[d]);
            for (i in Iter.range(0, 7)) {
                buf[d * 8 + i] := u8[i];
            };
        };
        return Array.freeze(buf);
    };

    public func get_nat8(data : [var Nat64], idx : Nat) : Nat8 {
        let idx64 = idx / 8;
        var idx8 = idx % 8;
        idx8 *= 8;
        let n = Nat8.fromNat(Nat64.toNat((data[idx64] >> Nat64.fromNat(idx8)) & 0xFF));
        return n;
    };

    public func set_nat8(data : [var Nat64], idx : Nat, value : Nat8) {
        let idx64 = idx / 8;
        var idx8 = idx % 8;
        idx8 *= 8;

        let n = (data[idx64] >> Nat64.fromNat(idx8)) & 0xFF;
        data[idx64] := data[idx64] - n << Nat64.fromNat(idx8) + Nat64.fromNat(Nat8.toNat(value)) << Nat64.fromNat(idx8);
    };

    private class Context(bit : Nat, delim : Nat8) = {
        private var st : [var Nat64] = Array.init<Nat64>(SHA3_WORDS, 0);
        private let mdlen : Nat = bit / 8;
        private var rsiz : Nat = 200 - bit / 4;
        private var pt : Nat = 0;

        public func update(data : [Nat8]) {
            var j = pt;
            for (d in Iter.fromArray(data)) {
                var u8 = get_nat8(st, j);
                u8 ^= d;
                set_nat8(st, j, u8);
                j += 1;
                if (j >= rsiz) {
                    keccakf(st);
                    j := 0;
                };
            };
            pt := j;
        };

        public func finalize() : [Nat8] {
            var u8 = get_nat8(st, pt);
            u8 ^= delim;
            set_nat8(st, pt, u8);

            u8 := get_nat8(st, rsiz -1);
            u8 ^= 0x80;
            set_nat8(st, rsiz -1, u8);

            keccakf(st);
            var md : [var Nat8] = Array.init<Nat8>(mdlen, 0);

            for (i in Iter.range(0, mdlen -1)) {
                md[i] := get_nat8(st, i);
            };

            return Array.freeze(md);
        };
    };

    public class Sha3(bit : Nat) = {
        private var ctx : Context = Context(bit, 0x06);

        public func update(data : [Nat8]) {
            ctx.update(data);
        };

        public func finalize() : [Nat8] {
            return ctx.finalize();
        };
    };

    public class Keccak(bit : Nat) = {
        private var ctx : Context = Context(bit, 0x01);

        public func update(data : [Nat8]) {
            ctx.update(data);
        };

        public func finalize() : [Nat8] {
            return ctx.finalize();
        };
    };

};