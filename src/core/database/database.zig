const std = @import("std");
const nuts = @import("../nuts/lib.zig");
const dhke = @import("../dhke.zig");
const zul = @import("zul");
const bitcoin_primitives = @import("bitcoin-primitives");
const secp256k1 = bitcoin_primitives.secp256k1;

const Arened = @import("../../helper/helper.zig").Parsed;
const MintKeySetInfo = @import("../mint/mint.zig").MintKeySetInfo;
const MintQuote = @import("../mint/mint.zig").MintQuote;
const MeltQuote = @import("../mint/mint.zig").MeltQuote;

pub const MintMemoryDatabase = @import("mint_memory.zig").MintMemoryDatabase;

pub const MintDatabase = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    ptr: *anyopaque,
    size: usize,
    align_of: usize,

    deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,

    setActiveKeysetFn: *const fn (ptr: *anyopaque, unit: nuts.CurrencyUnit, id: nuts.Id) anyerror!void,
    getActiveKeysetIdFn: *const fn (ptr: *anyopaque, unit: nuts.CurrencyUnit) ?nuts.Id,
    getActiveKeysetsFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!std.AutoHashMap(nuts.CurrencyUnit, nuts.Id),
    addKeysetInfoFn: *const fn (ptr: *anyopaque, keyset: MintKeySetInfo) anyerror!void,
    getKeysetInfoFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, keyset_id: nuts.Id) anyerror!?MintKeySetInfo,
    getKeysetInfosFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) anyerror!Arened(std.ArrayList(MintKeySetInfo)),
    addMintQuoteFn: *const fn (ptr: *anyopaque, quote: MintQuote) anyerror!void,
    getMintQuoteFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, quote_id: zul.UUID) anyerror!?MintQuote,
    updateMintQuoteStateFn: *const fn (ptr: *anyopaque, quote_id: zul.UUID, state: nuts.nut04.QuoteState) anyerror!nuts.nut04.QuoteState,
    getMintQuotesFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!std.ArrayList(MintQuote),
    getMintQuoteByRequestLookupIdFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, request_lookup_id: zul.UUID) anyerror!?MintQuote,
    getMintQuoteByRequestFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, request: []const u8) anyerror!?MintQuote,
    removeMintQuoteStateFn: *const fn (ptr: *anyopaque, quote_id: zul.UUID) anyerror!void,
    addMeltQuoteFn: *const fn (ptr: *anyopaque, quote: MeltQuote) anyerror!void,
    getMeltQuoteFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, quote_id: zul.UUID) anyerror!?MeltQuote,
    updateMeltQuoteStateFn: *const fn (ptr: *anyopaque, quote_id: zul.UUID, state: nuts.nut05.QuoteState) anyerror!nuts.nut05.QuoteState,
    getMeltQuotesFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) anyerror!std.ArrayList(MeltQuote),
    getMeltQuoteByRequestLookupIdFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, request_lookup_id: zul.UUID) anyerror!?MeltQuote,
    getMeltQuoteByRequestFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, request: []const u8) anyerror!?MeltQuote,
    removeMeltQuoteStateFn: *const fn (ptr: *anyopaque, quote_id: zul.UUID) anyerror!void,
    addProofsFn: *const fn (ptr: *anyopaque, proofs: []const nuts.Proof) anyerror!void,

    getProofsByYsFn: *const fn (
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        ys: []const secp256k1.PublicKey,
    ) anyerror!std.ArrayList(?nuts.Proof),

    updateProofsStatesFn: *const fn (
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        ys: []const secp256k1.PublicKey,
        state: nuts.nut07.State,
    ) anyerror!std.ArrayList(?nuts.nut07.State),
    getProofsStatesFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, ys: []const secp256k1.PublicKey) anyerror!std.ArrayList(?nuts.nut07.State),

    getProofsByKeysetIdFn: *const fn (
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        keyset_id: nuts.Id,
    ) anyerror!Arened(std.meta.Tuple(&.{
        std.ArrayList(nuts.Proof),
        std.ArrayList(?nuts.nut07.State),
    })),
    addBlindSignaturesFn: *const fn (
        ptr: *anyopaque,
        blinded_messages: []const secp256k1.PublicKey,
        blind_signatures: []const nuts.BlindSignature,
    ) anyerror!void,
    getBlindSignaturesFn: *const fn (
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        blinded_messages: []const secp256k1.PublicKey,
    ) anyerror!std.ArrayList(?nuts.BlindSignature),
    getBlindSignaturesForKeysetFn: *const fn (
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        keyset_id: nuts.Id,
    ) anyerror!std.ArrayList(nuts.BlindSignature),

    // interface for generating clojure to ptr: anytype for this zig interface
    pub fn initFrom(comptime T: type, _allocator: std.mem.Allocator, value: T) !Self {

        // implement gen structure
        const gen = struct {
            pub fn setActiveKeyset(pointer: *anyopaque, unit: nuts.CurrencyUnit, id: nuts.Id) anyerror!void {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.setActiveKeyset(unit, id);
            }

            pub fn getActiveKeysetId(pointer: *anyopaque, unit: nuts.CurrencyUnit) ?nuts.Id {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getActiveKeysetId(unit);
            }

            pub fn getActiveKeysets(pointer: *anyopaque, gpa: std.mem.Allocator) anyerror!std.AutoHashMap(nuts.CurrencyUnit, nuts.Id) {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getActiveKeysets(gpa);
            }
            pub fn addKeysetInfo(pointer: *anyopaque, keyset: MintKeySetInfo) anyerror!void {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.addKeysetInfo(keyset);
            }
            pub fn getKeysetInfo(pointer: *anyopaque, gpa: std.mem.Allocator, keyset_id: nuts.Id) anyerror!?MintKeySetInfo {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getKeysetInfo(gpa, keyset_id);
            }
            pub fn getKeysetInfos(pointer: *anyopaque, gpa: std.mem.Allocator) anyerror!Arened(std.ArrayList(MintKeySetInfo)) {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getKeysetInfos(gpa);
            }
            pub fn addMintQuote(pointer: *anyopaque, quote: MintQuote) anyerror!void {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.addMintQuote(quote);
            }
            pub fn getMintQuote(pointer: *anyopaque, gpa: std.mem.Allocator, quote_id: zul.UUID) anyerror!?MintQuote {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getMintQuote(gpa, quote_id);
            }
            pub fn updateMintQuoteState(pointer: *anyopaque, quote_id: zul.UUID, state: nuts.nut04.QuoteState) anyerror!nuts.nut04.QuoteState {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.updateMintQuoteState(quote_id, state);
            }
            pub fn getMintQuotes(pointer: *anyopaque, gpa: std.mem.Allocator) anyerror!std.ArrayList(MintQuote) {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getMintQuotes(gpa);
            }
            pub fn getMintQuoteByRequestLookupId(pointer: *anyopaque, gpa: std.mem.Allocator, request_lookup_id: zul.UUID) anyerror!?MintQuote {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getMintQuoteByRequestLookupId(gpa, request_lookup_id);
            }
            pub fn getMintQuoteByRequest(pointer: *anyopaque, gpa: std.mem.Allocator, request: []const u8) anyerror!?MintQuote {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getMintQuoteByRequest(gpa, request);
            }
            pub fn removeMintQuoteState(pointer: *anyopaque, quote_id: zul.UUID) anyerror!void {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.removeMintQuoteState(quote_id);
            }
            pub fn addMeltQuote(pointer: *anyopaque, quote: MeltQuote) anyerror!void {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.addMeltQuote(quote);
            }
            pub fn getMeltQuote(pointer: *anyopaque, gpa: std.mem.Allocator, quote_id: zul.UUID) anyerror!?MeltQuote {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getMeltQuote(gpa, quote_id);
            }
            pub fn updateMeltQuoteState(pointer: *anyopaque, quote_id: zul.UUID, state: nuts.nut05.QuoteState) anyerror!nuts.nut05.QuoteState {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.updateMeltQuoteState(quote_id, state);
            }
            pub fn getMeltQuotes(pointer: *anyopaque, gpa: std.mem.Allocator) anyerror!std.ArrayList(MeltQuote) {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getMeltQuotes(gpa);
            }
            pub fn getMeltQuoteByRequestLookupId(pointer: *anyopaque, gpa: std.mem.Allocator, request_lookup_id: zul.UUID) anyerror!?MeltQuote {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getMeltQuoteByRequestLookupId(gpa, request_lookup_id);
            }
            pub fn getMeltQuoteByRequest(pointer: *anyopaque, gpa: std.mem.Allocator, request: []const u8) anyerror!?MeltQuote {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getMeltQuoteByRequest(gpa, request);
            }
            pub fn removeMeltQuoteState(pointer: *anyopaque, quote_id: zul.UUID) anyerror!void {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.removeMeltQuoteState(quote_id);
            }
            pub fn addProofs(pointer: *anyopaque, proofs: []const nuts.Proof) anyerror!void {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.addProofs(proofs);
            }

            pub fn getProofsByYs(
                pointer: *anyopaque,
                gpa: std.mem.Allocator,
                ys: []const secp256k1.PublicKey,
            ) anyerror!std.ArrayList(?nuts.Proof) {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getProofsByYs(gpa, ys);
            }

            pub fn updateProofsStates(
                pointer: *anyopaque,
                gpa: std.mem.Allocator,
                ys: []const secp256k1.PublicKey,
                state: nuts.nut07.State,
            ) anyerror!std.ArrayList(?nuts.nut07.State) {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.updateProofsStates(gpa, ys, state);
            }

            pub fn getProofsStates(
                pointer: *anyopaque,
                gpa: std.mem.Allocator,
                ys: []const secp256k1.PublicKey,
            ) anyerror!std.ArrayList(?nuts.nut07.State) {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getProofsStates(gpa, ys);
            }

            pub fn getProofsByKeysetId(
                pointer: *anyopaque,
                gpa: std.mem.Allocator,
                keyset_id: nuts.Id,
            ) anyerror!Arened(std.meta.Tuple(&.{
                std.ArrayList(nuts.Proof),
                std.ArrayList(?nuts.nut07.State),
            })) {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getProofsByKeysetId(gpa, keyset_id);
            }

            pub fn addBlindSignatures(
                pointer: *anyopaque,
                blinded_messages: []const secp256k1.PublicKey,
                blind_signatures: []const nuts.BlindSignature,
            ) anyerror!void {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.addBlindSignatures(blinded_messages, blind_signatures);
            }

            pub fn getBlindSignatures(
                pointer: *anyopaque,
                gpa: std.mem.Allocator,
                blinded_messages: []const secp256k1.PublicKey,
            ) anyerror!std.ArrayList(?nuts.BlindSignature) {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getBlindSignatures(gpa, blinded_messages);
            }

            pub fn getBlindSignaturesForKeyset(
                pointer: *anyopaque,
                gpa: std.mem.Allocator,
                keyset_id: nuts.Id,
            ) anyerror!std.ArrayList(nuts.BlindSignature) {
                const self: *T = @ptrCast(@alignCast(pointer));
                return self.getBlindSignaturesForKeyset(gpa, keyset_id);
            }
            pub fn deinit(pointer: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *T = @ptrCast(@alignCast(pointer));

                if (std.meta.hasFn(T, "deinit")) {
                    self.deinit();
                }

                allocator.destroy(self);
            }
        };

        const ptr: *T align(1) = try _allocator.create(T);
        ptr.* = value;

        return .{
            .ptr = ptr,
            .allocator = _allocator,
            .size = @sizeOf(T),
            .align_of = @alignOf(T),

            .getBlindSignaturesForKeysetFn = gen.getBlindSignaturesForKeyset,

            .getBlindSignaturesFn = gen.getBlindSignatures,
            .addBlindSignaturesFn = gen.addBlindSignatures,
            .getProofsByKeysetIdFn = gen.getProofsByKeysetId,
            .getProofsStatesFn = gen.getProofsStates,
            .updateProofsStatesFn = gen.updateProofsStates,
            .deinitFn = gen.deinit,
            .getProofsByYsFn = gen.getProofsByYs,

            .setActiveKeysetFn = gen.setActiveKeyset,
            .getActiveKeysetIdFn = gen.getActiveKeysetId,
            .getActiveKeysetsFn = gen.getActiveKeysets,
            .addKeysetInfoFn = gen.addKeysetInfo,
            .getKeysetInfoFn = gen.getKeysetInfo,
            .getKeysetInfosFn = gen.getKeysetInfos,
            .addMintQuoteFn = gen.addMintQuote,
            .getMintQuoteFn = gen.getMintQuote,
            .updateMintQuoteStateFn = gen.updateMintQuoteState,
            .getMintQuotesFn = gen.getMintQuotes,
            .getMintQuoteByRequestLookupIdFn = gen.getMintQuoteByRequestLookupId,
            .getMintQuoteByRequestFn = gen.getMintQuoteByRequest,
            .removeMintQuoteStateFn = gen.removeMintQuoteState,
            .addMeltQuoteFn = gen.addMeltQuote,
            .getMeltQuoteFn = gen.getMeltQuote,
            .updateMeltQuoteStateFn = gen.updateMeltQuoteState,
            .getMeltQuotesFn = gen.getMeltQuotes,
            .getMeltQuoteByRequestLookupIdFn = gen.getMeltQuoteByRequestLookupId,
            .getMeltQuoteByRequestFn = gen.getMeltQuoteByRequest,
            .removeMeltQuoteStateFn = gen.removeMeltQuoteState,
            .addProofsFn = gen.addProofs,
        };
    }

    /// free resources of database
    pub fn deinit(self: Self) void {
        self.deinitFn(self.ptr, self.allocator);
        // clearing pointer
    }

    pub fn setActiveKeyset(self: Self, unit: nuts.CurrencyUnit, id: nuts.Id) anyerror!void {
        return self.setActiveKeysetFn(self.ptr, unit, id);
    }

    pub fn getActiveKeysetId(self: Self, unit: nuts.CurrencyUnit) ?nuts.Id {
        return self.getActiveKeysetIdFn(self.ptr, unit);
    }

    pub fn getActiveKeysets(self: Self, gpa: std.mem.Allocator) anyerror!std.AutoHashMap(nuts.CurrencyUnit, nuts.Id) {
        return self.getActiveKeysetsFn(self.ptr, gpa);
    }
    pub fn addKeysetInfo(self: Self, keyset: MintKeySetInfo) anyerror!void {
        return self.addKeysetInfoFn(self.ptr, keyset);
    }
    pub fn getKeysetInfo(self: Self, gpa: std.mem.Allocator, keyset_id: nuts.Id) anyerror!?MintKeySetInfo {
        return self.getKeysetInfoFn(self.ptr, gpa, keyset_id);
    }
    pub fn getKeysetInfos(self: Self, gpa: std.mem.Allocator) anyerror!Arened(std.ArrayList(MintKeySetInfo)) {
        return self.getKeysetInfosFn(self.ptr, gpa);
    }
    pub fn addMintQuote(self: Self, quote: MintQuote) anyerror!void {
        return self.addMintQuoteFn(self.ptr, quote);
    }
    pub fn getMintQuote(self: Self, gpa: std.mem.Allocator, quote_id: zul.UUID) anyerror!?MintQuote {
        return self.getMintQuoteFn(self.ptr, gpa, quote_id);
    }
    pub fn updateMintQuoteState(self: Self, quote_id: zul.UUID, state: nuts.nut04.QuoteState) anyerror!nuts.nut04.QuoteState {
        return self.updateMintQuoteStateFn(self.ptr, quote_id, state);
    }
    pub fn getMintQuotes(self: Self, allocator: std.mem.Allocator) anyerror!std.ArrayList(MintQuote) {
        return self.getMintQuotesFn(self.ptr, allocator);
    }
    pub fn getMintQuoteByRequestLookupId(self: Self, gpa: std.mem.Allocator, request_lookup_id: zul.UUID) anyerror!?MintQuote {
        return self.getMintQuoteByRequestLookupIdFn(self.ptr, gpa, request_lookup_id);
    }
    pub fn getMintQuoteByRequest(self: Self, gpa: std.mem.Allocator, request: []const u8) anyerror!?MintQuote {
        return self.getMintQuoteByRequestFn(self.ptr, gpa, request);
    }
    pub fn removeMintQuoteState(self: Self, quote_id: zul.UUID) anyerror!void {
        return self.removeMintQuoteStateFn(self.ptr, quote_id);
    }
    pub fn addMeltQuote(self: Self, quote: MeltQuote) anyerror!void {
        return self.addMeltQuoteFn(self.ptr, quote);
    }
    pub fn getMeltQuote(self: Self, gpa: std.mem.Allocator, quote_id: zul.UUID) anyerror!?MeltQuote {
        return self.getMeltQuoteFn(self.ptr, gpa, quote_id);
    }
    pub fn updateMeltQuoteState(self: Self, quote_id: zul.UUID, state: nuts.nut05.QuoteState) anyerror!nuts.nut05.QuoteState {
        return self.updateMeltQuoteStateFn(self.ptr, quote_id, state);
    }
    pub fn getMeltQuotes(self: Self, gpa: std.mem.Allocator) anyerror!std.ArrayList(MeltQuote) {
        return self.getMeltQuotesFn(self.ptr, gpa);
    }
    pub fn getMeltQuoteByRequestLookupId(self: Self, gpa: std.mem.Allocator, request_lookup_id: zul.UUID) anyerror!?MeltQuote {
        return self.getMeltQuoteByRequestLookupIdFn(self.ptr, gpa, request_lookup_id);
    }
    pub fn getMeltQuoteByRequest(self: Self, gpa: std.mem.Allocator, request: []const u8) anyerror!?MeltQuote {
        return self.getMeltQuoteByRequestFn(self.ptr, gpa, request);
    }
    pub fn removeMeltQuoteState(self: Self, quote_id: zul.UUID) anyerror!void {
        return self.removeMeltQuoteStateFn(self.ptr, quote_id);
    }
    pub fn addProofs(self: Self, proofs: []const nuts.Proof) anyerror!void {
        return self.addProofsFn(self.ptr, proofs);
    }

    pub fn getProofsByYs(
        self: Self,
        gpa: std.mem.Allocator,
        ys: []const secp256k1.PublicKey,
    ) anyerror!std.ArrayList(?nuts.Proof) {
        return self.getProofsByYsFn(self.ptr, gpa, ys);
    }

    pub fn updateProofsStates(
        self: Self,
        gpa: std.mem.Allocator,
        ys: []const secp256k1.PublicKey,
        state: nuts.nut07.State,
    ) anyerror!std.ArrayList(?nuts.nut07.State) {
        return self.updateProofsStatesFn(self.ptr, gpa, ys, state);
    }

    pub fn getProofsStates(
        self: Self,
        gpa: std.mem.Allocator,
        ys: []const secp256k1.PublicKey,
    ) anyerror!std.ArrayList(?nuts.nut07.State) {
        return self.getProofsStatesFn(self.ptr, gpa, ys);
    }

    pub fn getProofsByKeysetId(
        self: Self,
        gpa: std.mem.Allocator,
        keyset_id: nuts.Id,
    ) anyerror!Arened(std.meta.Tuple(&.{
        std.ArrayList(nuts.Proof),
        std.ArrayList(?nuts.nut07.State),
    })) {
        return self.getProofsByKeysetIdFn(self.ptr, gpa, keyset_id);
    }

    pub fn addBlindSignatures(
        self: Self,
        blinded_messages: []const secp256k1.PublicKey,
        blind_signatures: []const nuts.BlindSignature,
    ) anyerror!void {
        return self.addBlindSignaturesFn(self.ptr, blinded_messages, blind_signatures);
    }

    pub fn getBlindSignatures(
        self: Self,
        gpa: std.mem.Allocator,
        blinded_messages: []const secp256k1.PublicKey,
    ) anyerror!std.ArrayList(?nuts.BlindSignature) {
        return self.getBlindSignaturesFn(self.ptr, gpa, blinded_messages);
    }

    pub fn getBlindSignaturesForKeyset(
        self: Self,
        gpa: std.mem.Allocator,
        keyset_id: nuts.Id,
    ) anyerror!std.ArrayList(nuts.BlindSignature) {
        return self.getBlindSignaturesForKeysetFn(self.ptr, gpa, keyset_id);
    }
};
