const std = @import("std");
const core = @import("../lib.zig");
const bitcoin_primitives = @import("bitcoin-primitives");

const secp256k1 = bitcoin_primitives.secp256k1;
const bip32 = bitcoin_primitives.bips.bip32;
const helper = @import("../../helper/helper.zig");
const nuts = core.nuts;
const zul = @import("zul");

const RWMutex = helper.RWMutex;
const MintInfo = core.nuts.MintInfo;
const MintQuoteBolt11Response = core.nuts.nut04.MintQuoteBolt11Response;
const MeltQuoteBolt11Response = core.nuts.nut05.MeltQuoteBolt11Response;
const MintQuoteState = core.nuts.nut04.QuoteState;
const MintKeySet = core.nuts.MintKeySet;
const CurrencyUnit = core.nuts.CurrencyUnit;

pub const MintQuote = @import("types.zig").MintQuote;
pub const MeltQuote = @import("types.zig").MeltQuote;

pub const MintDatabase = core.mint_memory.MintDatabase;
pub const MintMemoryDatabase = core.mint_memory.MintMemoryDatabase;

// TODO implement tests

/// Mint Fee Reserve
pub const FeeReserve = struct {
    /// Absolute expected min fee
    min_fee_reserve: core.amount.Amount = 0,
    /// Percentage expected fee
    percent_fee_reserve: f32 = 0,
};

/// Mint Keyset Info
pub const MintKeySetInfo = struct {
    /// Keyset [`Id`]
    id: core.nuts.Id,
    /// Keyset [`CurrencyUnit`]
    unit: core.nuts.CurrencyUnit,
    /// Keyset active or inactive
    /// Mint will only issue new [`BlindSignature`] on active keysets
    active: bool,
    /// Starting unix time Keyset is valid from
    valid_from: u64,
    /// When the Keyset is valid to
    /// This is not shown to the wallet and can only be used internally
    valid_to: ?u64,
    /// [`DerivationPath`] keyset
    derivation_path: []const bip32.ChildNumber,
    /// DerivationPath index of Keyset
    derivation_path_index: ?u32,
    /// Max order of keyset
    max_order: u8,
    /// Input Fee ppk
    input_fee_ppk: u64 = 0,

    pub fn deinit(self: *const MintKeySetInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.derivation_path);
    }

    pub fn clone(self: MintKeySetInfo, allocator: std.mem.Allocator) !MintKeySetInfo {
        var cloned = self;

        const derivation_path = try allocator.alloc(bip32.ChildNumber, self.derivation_path.len);
        errdefer allocator.free(derivation_path);

        @memcpy(derivation_path, self.derivation_path);
        cloned.derivation_path = derivation_path;

        return cloned;
    }
};

/// Cashu Mint
pub const Mint = struct {
    /// Mint Url
    mint_url: []const u8,
    /// Mint Info
    mint_info: MintInfo,
    /// Mint Storage backend
    localstore: helper.RWMutex(MintDatabase),
    /// Active Mint Keysets
    keysets: RWMutex(std.AutoHashMap(nuts.Id, nuts.MintKeySet)),
    secp_ctx: secp256k1.Secp256k1,
    xpriv: bip32.ExtendedPrivKey,

    // using for allocating data belongs to mint
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Mint) void {
        var it = self.keysets.value.iterator();

        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }

        self.keysets.value.deinit();
    }

    /// Create new [`Mint`]
    pub fn init(
        allocator: std.mem.Allocator,
        mint_url: []const u8,
        seed: []const u8,
        mint_info: MintInfo,
        localstore: MintDatabase,
        // Hashmap where the key is the unit and value is (input fee ppk, max_order)
        supported_units: std.AutoHashMap(core.nuts.CurrencyUnit, std.meta.Tuple(&.{ u64, u8 })),
    ) !Mint {
        const secp_ctx = secp256k1.Secp256k1.genNew();
        errdefer secp_ctx.deinit();

        const xpriv = try bip32.ExtendedPrivKey.initMaster(.MAINNET, seed);

        var active_keysets = std.AutoHashMap(core.nuts.Id, MintKeySet).init(allocator);
        errdefer {
            var it = active_keysets.valueIterator();
            while (it.next()) |v| v.deinit();
            active_keysets.deinit();
        }

        const keyset_infos = try localstore.getKeysetInfos(allocator);
        defer keyset_infos.deinit();

        var active_keyset_units = std.ArrayList(core.nuts.CurrencyUnit).init(allocator);
        errdefer active_keyset_units.deinit();

        if (keyset_infos.value.items.len > 0) {
            std.log.debug("setting all keysets to inactive, size = {d}", .{keyset_infos.value.items.len});
            // TODO this part of code

            for (keyset_infos.value.items) |keyset| {
                // Set all to in active
                var ks = keyset;
                ks.active = false;

                try localstore.addKeysetInfo(ks);
            }

            const keysets_by_unit = v: {
                // allocating through arena for easy deallocation
                var result = std.AutoHashMap(CurrencyUnit, std.ArrayList(MintKeySetInfo)).init(keyset_infos.arena.allocator());

                for (keyset_infos.value.items) |ks| {
                    var gop = try result.getOrPut(ks.unit);
                    if (!gop.found_existing) {
                        // already exist
                        gop.value_ptr.* = std.ArrayList(MintKeySetInfo).init(keyset_infos.arena.allocator());
                    }

                    try gop.value_ptr.append(ks);
                }

                break :v result;
            };

            var it = keysets_by_unit.iterator();

            while (it.next()) |entry| {
                const unit = entry.key_ptr.*;
                const _keysets = entry.value_ptr.*;

                std.sort.block(MintKeySetInfo, _keysets.items, {}, (struct {
                    fn compare(_: void, l: MintKeySetInfo, r: MintKeySetInfo) bool {
                        if (r.derivation_path_index) |r_dpi| {
                            if (l.derivation_path_index) |l_dpi| {
                                if (l_dpi < r_dpi) return true;
                            } else return true;
                        }

                        // other all cases false
                        return false;
                    }
                }).compare);

                const highest_index_keyset = _keysets.getLast();

                var keysets = try std.ArrayList(MintKeySetInfo).initCapacity(keyset_infos.arena.allocator(), _keysets.items.len);

                for (_keysets.items) |ks| {
                    if (ks.derivation_path_index != null) keysets.appendAssumeCapacity(ks);
                }

                if (supported_units.get(unit)) |supp_unit| {
                    const input_fee_ppk, const max_order = supp_unit;

                    const derivation_path_index: u32 = if (keysets.items.len == 0)
                        1
                    else if (highest_index_keyset.input_fee_ppk == input_fee_ppk and highest_index_keyset.max_order == max_order) {
                        const id = highest_index_keyset.id;
                        const keyset = try MintKeySet.generateFromXpriv(
                            keyset_infos.arena.allocator(),
                            secp_ctx,
                            xpriv,
                            highest_index_keyset.max_order,
                            highest_index_keyset.unit,
                            highest_index_keyset.derivation_path,
                        );

                        try active_keysets.put(id, keyset);
                        var keyset_info = highest_index_keyset;
                        keyset_info.active = true;

                        try localstore.addKeysetInfo(keyset_info);
                        try localstore.setActiveKeyset(unit, id);
                        continue;
                    } else highest_index_keyset.derivation_path_index orelse 0 + 1;

                    const derivation_path = derivationPathFromUnit(unit, derivation_path_index);

                    const keyset, const keyset_info = try createNewKeysetAlloc(
                        keyset_infos.arena.allocator(),
                        secp_ctx,
                        xpriv,
                        &derivation_path,
                        derivation_path_index,
                        unit,
                        max_order,
                        input_fee_ppk,
                    );

                    const id = keyset_info.id;
                    try localstore.addKeysetInfo(keyset_info);
                    try localstore.setActiveKeyset(unit, id);
                    try active_keysets.put(id, keyset);
                    try active_keyset_units.append(unit);
                }
            }
        }

        var it = supported_units.iterator();

        while (it.next()) |su_entry| {
            const unit = su_entry.key_ptr.*;
            const fee, const max_order = su_entry.value_ptr.*;

            for (active_keyset_units.items) |u| {
                if (std.meta.eql(u, unit)) break;
            } else {
                // not contains in array
                const derivation_path = derivationPathFromUnit(unit, 0);

                var keyset, const keyset_info = try createNewKeysetAlloc(
                    allocator,
                    secp_ctx,
                    xpriv,
                    &derivation_path,
                    0,
                    unit,
                    max_order,
                    fee,
                );
                defer keyset_info.deinit(allocator);
                errdefer keyset.deinit();

                const id = keyset_info.id;
                _ = try localstore.addKeysetInfo(keyset_info);
                try localstore.setActiveKeyset(unit, id);
                var old = try active_keysets.fetchPut(id, keyset) orelse continue;
                old.value.deinit();
            }
        }

        return .{
            .allocator = allocator,
            .keysets = .{
                .value = active_keysets,
                .lock = .{},
            },
            .mint_url = mint_url,
            .secp_ctx = secp_ctx,
            .xpriv = xpriv,
            .localstore = .{
                .value = localstore,
                .lock = .{},
            },
            .mint_info = mint_info,
        };
    }

    /// Creating new [`MintQuote`], all arguments are cloned and reallocated
    /// caller responsible on free resources of result
    pub fn newMintQuote(
        self: *Mint,
        allocator: std.mem.Allocator,
        mint_url: []const u8,
        request: []const u8,
        unit: nuts.CurrencyUnit,
        amount: core.amount.Amount,
        expiry: u64,
        ln_lookup: []const u8,
    ) !MintQuote {
        const nut04 = self.mint_info.nuts.nut04;
        if (nut04.disabled) return error.MintingDisabled;
        // TODO return check

        // if (nut04.getSettings(unit, .bolt11)) |settings| {
        //     if (settings.max_amount) |max_amount| if (amount > max_amount) return error.MintOverLimit;

        //     if (settings.min_amount) |min_amount| if (amount < min_amount) return error.MintUnderLimit;
        // } else return error.UnsupportedUnit;

        const quote = try MintQuote.initAlloc(
            allocator,
            mint_url,
            request,
            unit,
            amount,
            expiry,
            ln_lookup,
        );
        errdefer quote.deinit(allocator);

        std.log.debug("New mint quote: {any}", .{quote});

        self.localstore.lock.lock();

        defer self.localstore.lock.unlock();
        try self.localstore.value.addMintQuote(quote);

        return quote;
    }

    /// Creating new [`MeltQuote`], all arguments are cloned and reallocated
    /// caller responsible on free resources of result
    pub fn newMeltQuote(
        self: *Mint,
        request: []const u8,
        unit: nuts.CurrencyUnit,
        amount: core.amount.Amount,
        fee_reserve: core.amount.Amount,
        expiry: u64,
        request_lookup_id: []const u8,
    ) !MeltQuote {
        const nut05 = self.mint_info.nuts.nut05;
        if (nut05.disabled) return error.MeltingDisabled;
        // TODO return check

        // if (nut04.getSettings(unit, .bolt11)) |settings| {
        //     if (settings.max_amount) |max_amount| if (amount > max_amount) return error.MintOverLimit;

        //     if (settings.min_amount) |min_amount| if (amount < min_amount) return error.MintUnderLimit;
        // } else return error.UnsupportedUnit;

        const quote = MeltQuote.init(
            request,
            unit,
            amount,
            fee_reserve,
            expiry,
            request_lookup_id,
        );

        std.log.debug("New melt quote: {any}", .{quote});

        self.localstore.lock.lock();

        defer self.localstore.lock.unlock();
        try self.localstore.value.addMeltQuote(quote);

        return quote;
    }

    /// Check mint quote
    /// caller own result and should deinit
    pub fn checkMintQuote(self: *Mint, allocator: std.mem.Allocator, quote_id: zul.UUID) !MintQuoteBolt11Response {
        const quote = v: {
            self.localstore.lock.lockShared();
            defer self.localstore.lock.unlockShared();
            break :v (try self.localstore.value.getMintQuote(allocator, quote_id)) orelse return error.UnknownQuote;
        };
        defer quote.deinit(allocator);

        const paid = quote.state == .paid;

        // Since the pending state is not part of the NUT it should not be part of the response.
        // In practice the wallet should not be checking the state of a quote while waiting for the mint response.
        const state = switch (quote.state) {
            .pending => MintQuoteState.paid,
            else => quote.state,
        };

        const result = MintQuoteBolt11Response{
            .quote = quote.id.toHex(.lower),
            .request = quote.request,
            .paid = paid,
            .state = state,
            .expiry = quote.expiry,
        };
        return try result.clone(allocator);
    }

    /// Retrieve the public keys of the active keyset for distribution to wallet clients
    pub fn pubkeys(self: *Mint, allocator: std.mem.Allocator) !core.nuts.KeysResponse {
        const keyset_infos = try self.localstore.value.getKeysetInfos(allocator);
        defer keyset_infos.deinit();

        for (keyset_infos.value.items) |keyset_info| {
            try self.ensureKeysetLoaded(keyset_info.id);
        }

        self.keysets.lock.lockShared();
        defer self.keysets.lock.unlockShared();

        // core.nuts.KeySet
        var it = self.keysets.value.valueIterator();

        var result = try std.ArrayList(core.nuts.KeySet).initCapacity(allocator, it.len);
        errdefer {
            for (result.items) |*ks| ks.deinit(allocator);
            result.deinit();
        }

        while (it.next()) |k| {
            result.appendAssumeCapacity(try k.toKeySet(allocator));
        }

        return .{
            .keysets = result.items,
        };
    }

    /// Ensure Keyset is loaded in mint
    pub fn ensureKeysetLoaded(self: *Mint, id: core.nuts.Id) !void {
        // check if keyset already in
        {
            self.keysets.lock.lockShared();
            defer self.keysets.lock.unlockShared();

            if (self.keysets.value.contains(id)) return;
        }

        const keyset_info = try self.localstore.value.getKeysetInfo(self.allocator, id) orelse return error.UnknownKeySet;
        errdefer keyset_info.deinit(self.allocator);

        self.keysets.lock.lock();
        defer self.keysets.lock.unlock();

        // ensuring that map got enough space
        try self.keysets.value.ensureUnusedCapacity(1);

        // allocating through internal because we own this inside Mint
        const mint_keyset = try self.generateKeyset(self.allocator, keyset_info);
        errdefer mint_keyset.deinit(self.allocator);

        self.keysets.value.putAssumeCapacity(
            id,
            mint_keyset,
        );

        return;
    }

    /// Generate [`MintKeySet`] from [`MintKeySetInfo`]
    pub fn generateKeyset(self: *Mint, allocator: std.mem.Allocator, keyset_info: MintKeySetInfo) !core.nuts.MintKeySet {
        return try core.nuts.MintKeySet.generateFromXpriv(
            allocator,
            self.secp_ctx,
            self.xpriv,
            keyset_info.max_order,
            keyset_info.unit,
            keyset_info.derivation_path,
        );
    }

    /// Return a list of all supported keysets
    /// caller responsible to deallocate result
    pub fn getKeysets(self: *Mint, allocator: std.mem.Allocator) !core.nuts.KeysetResponse {
        const keysets = try self.localstore.value.getKeysetInfos(allocator);
        defer keysets.deinit();

        var _active_keysets = try self.localstore.value.getActiveKeysets(allocator);
        defer _active_keysets.deinit();

        var active_keysets = std.AutoHashMap(core.nuts.Id, void).init(allocator);
        defer active_keysets.deinit();

        var it = _active_keysets.valueIterator();
        while (it.next()) |value| try active_keysets.put(value.*, {});

        var result = try std.ArrayList(core.nuts.KeySetInfo).initCapacity(allocator, keysets.value.items.len);
        errdefer result.deinit();

        for (keysets.value.items) |ks| {
            result.appendAssumeCapacity(.{
                .id = ks.id,
                .unit = ks.unit,
                .active = active_keysets.contains(ks.id),
                .input_fee_ppk = ks.input_fee_ppk,
            });
        }

        return .{
            .keysets = try result.toOwnedSlice(),
        };
    }

    /// Add current keyset to inactive keysets
    /// Generate new keyset
    pub fn rotateKeyset(
        self: *Mint,
        allocator: std.mem.Allocator,
        unit: nuts.CurrencyUnit,
        derivation_path_index: u32,
        max_order: u8,
        input_fee_ppk: u64,
    ) !void {
        const derivation_path = derivationPathFromUnit(unit, derivation_path_index);
        var keyset, const keyset_info = try createNewKeysetAlloc(
            allocator,
            self.secp_ctx,
            self.xpriv,
            &derivation_path,
            derivation_path_index,
            unit,
            max_order,
            input_fee_ppk,
        );
        defer keyset_info.deinit(allocator);
        defer keyset.deinit();

        const id = keyset_info.id;
        try self.localstore.value.addKeysetInfo(keyset_info);
        try self.localstore.value.setActiveKeyset(unit, id);

        self.keysets.lock.lock();
        defer self.keysets.lock.unlock();
        try self.keysets.value.put(id, keyset);
    }

    /// Check state
    pub fn checkState(
        self: *Mint,
        allocator: std.mem.Allocator,
        check_state: core.nuts.nut07.CheckStateRequest,
    ) !core.nuts.nut07.CheckStateResponse {
        const _states = try self.localstore.value.getProofsStates(allocator, check_state.ys);
        defer _states.deinit();

        var states = try std.ArrayList(core.nuts.nut07.ProofState).initCapacity(allocator, _states.items.len);
        errdefer {
            for (states.items) |s| s.deinit(allocator);
            states.deinit();
        }

        const min_length = @min(_states.items.len, check_state.ys.len);

        for (check_state.ys[0..min_length], _states.items[0..min_length]) |y, s| {
            const state: core.nuts.nut07.State = s orelse .unspent;

            states.appendAssumeCapacity(.{
                .y = y,
                .state = state,
                .witness = null,
            });
        }

        return .{ .states = try states.toOwnedSlice() };
    }

    /// Retrieve the public keys of the active keyset for distribution to wallet clients
    pub fn keysetPubkeys(self: *Mint, allocator: std.mem.Allocator, keyset_id: nuts.Id) !nuts.KeysResponse {
        try self.ensureKeysetLoaded(keyset_id);
        self.keysets.lock.lock();
        defer self.keysets.lock.unlock();

        const keyset = self.keysets.value.get(keyset_id) orelse return error.UnknownKeySet;

        const keysets = try allocator.alloc(nuts.KeySet, 1);
        errdefer allocator.free(keysets);

        keysets[0] = try keyset.toKeySet(allocator);

        return .{
            .keysets = keysets,
        };
    }

    /// Flag mint quote as paid
    pub fn payMintQuoteForRequestId(
        self: *Mint,
        request_lookup_id: []const u8,
    ) !void {
        const mint_quote = (try self.localstore.value.getMintQuoteByRequestLookupId(self.allocator, request_lookup_id)) orelse return;

        std.log.debug("Quote {any} paid by lookup id {s}", .{
            mint_quote,
            request_lookup_id,
        });

        _ = try self.localstore.value.updateMintQuoteState(mint_quote.id, .paid);
    }

    /// Blind Sign
    pub fn blindSign(
        self: *Mint,
        gpa: std.mem.Allocator,
        blinded_message: core.nuts.BlindedMessage,
    ) !core.nuts.BlindSignature {
        try self.ensureKeysetLoaded(blinded_message.keyset_id);

        const keyset_info = try self
            .localstore.value
            .getKeysetInfo(gpa, blinded_message.keyset_id) orelse return error.UnknownKeySet;
        errdefer keyset_info.deinit(gpa);

        const active = self
            .localstore
            .value
            .getActiveKeysetId(keyset_info.unit) orelse return error.InactiveKeyset;

        // Check that the keyset is active and should be used to sign
        if (!std.meta.eql(keyset_info.id, active)) {
            return error.InactiveKeyset;
        }

        const keyset = v: {
            self.keysets.lock.lock();
            defer self.keysets.lock.unlock();

            break :v self.keysets.value.get(blinded_message.keyset_id) orelse return error.UknownKeySet;
        };

        const key_pair = keyset.keys.inner.get(blinded_message.amount) orelse return error.AmountKey;

        const c = try core.dhke.signMessage(
            self.secp_ctx,
            key_pair.secret_key,
            blinded_message.blinded_secret,
        );

        const blinded_signature = try core.nuts.initBlindSignature(
            self.secp_ctx,
            blinded_message.amount,
            c,
            keyset_info.id,
            blinded_message.blinded_secret,
            key_pair.secret_key,
        );

        return blinded_signature;
    }

    /// Process mint request
    pub fn processMintRequest(
        self: *Mint,
        gpa: std.mem.Allocator,
        mint_request: core.nuts.nut04.MintBolt11Request,
    ) !core.nuts.nut04.MintBolt11Response {
        const quote_id = try zul.UUID.parse(&mint_request.quote);

        const state = try self.localstore.value.updateMintQuoteState(quote_id, .pending);

        std.log.debug("process_mitn_request: quote_id {s}", .{quote_id.toHex(.lower)});
        switch (state) {
            .unpaid => return error.UnpaidQuote,
            .pending => return error.PendingQuote,
            .issued => return error.IssuedQuote,
            .paid => {},
        }

        var blinded_messages = try std.ArrayList(secp256k1.PublicKey).initCapacity(gpa, mint_request.outputs.len);
        errdefer blinded_messages.deinit();

        for (mint_request.outputs) |b| {
            blinded_messages.appendAssumeCapacity(b.blinded_secret);
        }

        const _blind_signatures = try self.localstore.value.getBlindSignatures(gpa, blinded_messages.items);
        defer _blind_signatures.deinit();

        for (_blind_signatures.items) |bs| {
            if (bs != null) {
                std.log.debug("output has already been signed", .{});
                std.log.debug("Mint {x} did not succeed returning quote to Paid state", .{mint_request.quote});

                _ = try self.localstore
                    .value.updateMintQuoteState(quote_id, .paid);
                return error.BlindedMessageAlreadySigned;
            }
        }

        var blind_signatures = try std.ArrayList(core.nuts.BlindSignature).initCapacity(gpa, mint_request.outputs.len);
        errdefer blind_signatures.deinit();

        for (mint_request.outputs) |blinded_message| {
            const blind_signature = try self.blindSign(gpa, blinded_message);
            blind_signatures.appendAssumeCapacity(blind_signature);
        }

        try self.localstore
            .value
            .addBlindSignatures(blinded_messages.items, blind_signatures.items, &mint_request.quote);

        _ = try self.localstore.value.updateMintQuoteState(quote_id, .issued);

        std.log.debug("process_mint_request: issued {s}", .{quote_id.toHex(.lower)});

        return .{
            .signatures = try blind_signatures.toOwnedSlice(),
        };
    }

    /// Fee required for proof set
    pub fn getProofsFee(self: *Mint, gpa: std.mem.Allocator, proofs: []const nuts.Proof) !core.amount.Amount {
        var sum_fee: u64 = 0;

        for (proofs) |proof| {
            const input_fee_ppk = try self
                .localstore
                .value
                .getKeysetInfo(gpa, proof.keyset_id) orelse return error.UnknownKeySet;
            defer input_fee_ppk.deinit(gpa);

            sum_fee += input_fee_ppk.input_fee_ppk;
        }

        const fee = (sum_fee + 999) / 1000;

        return fee;
    }

    /// Check Tokens are not spent or pending
    pub fn checkYsSpendable(
        self: *Mint,
        ys: []const secp256k1.PublicKey,
        proof_state: nuts.nut07.State,
    ) !void {
        const proofs_state = try self
            .localstore
            .value
            .updateProofsStates(self.allocator, ys, proof_state);
        defer proofs_state.deinit();

        for (proofs_state.items) |p|
            if (p) |proof| switch (proof) {
                .pending => return error.TokenPending,
                .spent => return error.TokenAlreadySpent,
                else => continue,
            };
    }

    /// Verify [`Proof`] meets conditions and is signed
    pub fn verifyProof(self: *Mint, proof: nuts.Proof) !void {
        // Check if secret is a nut10 secret with conditions
        if (nuts.nut10.Secret.fromSecret(proof.secret, self.allocator)) |secret| {
            defer secret.deinit();

            // Checks and verifes known secret kinds.
            // If it is an unknown secret kind it will be treated as a normal secret.
            // Spending conditions will **not** be check. It is up to the wallet to ensure
            // only supported secret kinds are used as there is no way for the mint to enforce
            // only signing supported secrets as they are blinded at that point.

            switch (secret.value.kind) {
                .p2pk => try nuts.nut11.verifyP2pkProof(&proof, self.allocator),
                .htlc => try nuts.verifyHTLC(&proof, self.allocator),
            }
        } else |_| {}

        try self.ensureKeysetLoaded(proof.keyset_id);

        const sec_key = v: {
            self.keysets.lock.lock();
            defer self.keysets.lock.unlock();
            const keyset = self.keysets.value.get(proof.keyset_id) orelse return error.UnknownKeySet;

            break :v (keyset.keys.inner.get(proof.amount) orelse return error.AmountKey).secret_key;
        };

        try core.dhke.verifyMessage(self.secp_ctx, sec_key, proof.c, proof.secret.toBytes());
    }

    /// Process Swap
    /// expecting allocator as arena
    pub fn processSwapRequest(
        self: *Mint,
        arena: std.mem.Allocator,
        swap_request: nuts.SwapRequest,
    ) !nuts.SwapResponse {
        var blinded_messages = try std.ArrayList(secp256k1.PublicKey).initCapacity(arena, swap_request.outputs.len);

        for (swap_request.outputs) |b| {
            blinded_messages.appendAssumeCapacity(b.blinded_secret);
        }

        const _blind_signatures = try self.localstore.value.getBlindSignatures(arena, blinded_messages.items);

        for (_blind_signatures.items) |bs| {
            if (bs != null) {
                std.log.debug("output has already been signed", .{});

                return error.BlindedMessageAlreadySigned;
            }
        }

        const proofs_total = swap_request.inputAmount();
        const output_total = swap_request.outputAmount();

        const fee = try self.getProofsFee(arena, swap_request.inputs);

        if (proofs_total < output_total + fee) {
            std.log.info("Swap request without enough inputs: {}, outputs {}, fee {}", .{
                proofs_total, output_total, fee,
            });

            return error.InsufficientInputs;
        }

        var input_ys = try std.ArrayList(secp256k1.PublicKey).initCapacity(arena, swap_request.inputs.len);

        for (swap_request.inputs) |p| {
            input_ys.appendAssumeCapacity(try core.dhke.hashToCurve(p.secret.toBytes()));
        }

        try self.localstore.value.addProofs(swap_request.inputs);
        try self.checkYsSpendable(input_ys.items, .pending);

        // Check that there are no duplicate proofs in request

        {
            var h = std.AutoHashMap(secp256k1.PublicKey, void).init(arena);

            try h.ensureTotalCapacity(@intCast(input_ys.items.len));

            for (input_ys.items) |i| {
                if (h.fetchPutAssumeCapacity(i, {}) != null) {
                    _ = try self.localstore.value.updateProofsStates(arena, input_ys.items, .unspent);
                    return error.DuplicateProofs;
                }
            }
        }

        for (swap_request.inputs) |proof| {
            self.verifyProof(proof) catch |err| {
                std.log.info("Error verifying proof in swap", .{});
                return err;
            };
        }

        var input_keyset_ids = std.AutoHashMap(nuts.Id, void).init(arena);

        try input_keyset_ids.ensureTotalCapacity(@intCast(swap_request.inputs.len));

        for (swap_request.inputs) |p| input_keyset_ids.putAssumeCapacity(p.keyset_id, {});

        var keyset_units = std.AutoHashMap(nuts.CurrencyUnit, void).init(arena);

        {
            var it = input_keyset_ids.keyIterator();

            while (it.next()) |id| {
                const keyset = try self.localstore.value.getKeysetInfo(arena, id.*) orelse {
                    std.log.debug("Swap request with unknown keyset in inputs", .{});
                    _ = try self.localstore.value.updateProofsStates(arena, input_ys.items, .unspent);
                    continue;
                };

                try keyset_units.put(keyset.unit, {});
            }
        }

        var output_keyset_ids = std.AutoHashMap(nuts.Id, void).init(arena);

        try output_keyset_ids.ensureTotalCapacity(@intCast(swap_request.outputs.len));
        for (swap_request.outputs) |p| output_keyset_ids.putAssumeCapacity(p.keyset_id, {});

        {
            var it = output_keyset_ids.keyIterator();
            while (it.next()) |id| {
                const keyset = try self.localstore.value.getKeysetInfo(arena, id.*) orelse {
                    std.log.debug("Swap request with unknown keyset in outputs", .{});
                    _ = try self.localstore.value.updateProofsStates(arena, input_ys.items, .unspent);
                    continue;
                };

                keyset_units.putAssumeCapacity(keyset.unit, {});
            }
        }

        // Check that all proofs are the same unit
        // in the future it maybe possible to support multiple units but unsupported for
        // now
        if (keyset_units.count() > 1) {
            std.log.err("Only one unit is allowed in request: {any}", .{keyset_units});

            _ = try self.localstore
                .value
                .updateProofsStates(arena, input_ys.items, .unspent);

            return error.MultipleUnits;
        }

        var enforced_sig_flag = try core.nuts.nut11.enforceSigFlag(arena, swap_request.inputs);

        // let EnforceSigFlag {
        //     sig_flag,
        //     pubkeys,
        //     sigs_required,
        // } = enforce_sig_flag(swap_request.inputs.clone());

        if (enforced_sig_flag.sig_flag == .sig_all) {
            var _pubkeys = try std.ArrayList(secp256k1.PublicKey).initCapacity(arena, enforced_sig_flag.pubkeys.count());

            var it = enforced_sig_flag.pubkeys.keyIterator();

            while (it.next()) |key| {
                _pubkeys.appendAssumeCapacity(key.*);
            }

            for (swap_request.outputs) |*blinded_message| {
                nuts.nut11.verifyP2pkBlindedMessages(blinded_message, _pubkeys.items, enforced_sig_flag.sigs_required) catch |err| {
                    std.log.info("Could not verify p2pk in swap request", .{});
                    _ = try self.localstore
                        .value
                        .updateProofsStates(arena, input_ys.items, .unspent);
                    return err;
                };
            }
        }

        var promises = try std.ArrayList(nuts.BlindSignature).initCapacity(arena, swap_request.outputs.len);

        for (swap_request.outputs) |blinded_message| {
            const blinded_signature = try self.blindSign(arena, blinded_message);
            promises.appendAssumeCapacity(blinded_signature);
        }

        _ = try self.localstore
            .value
            .updateProofsStates(arena, input_ys.items, .spent);

        try self.localstore
            .value
            .addBlindSignatures(
            blinded_messages.items,
            promises.items,
            null,
        );

        return .{
            .signatures = promises.items,
        };
    }

    /// Check melt quote status
    pub fn checkMeltQuote(self: *Mint, gpa: std.mem.Allocator, quote_id: zul.UUID) !MeltQuoteBolt11Response {
        const quote = try self.localstore
            .value
            .getMeltQuote(gpa, quote_id) orelse return error.UnknownQuote;
        errdefer quote.deinit();

        return MeltQuoteBolt11Response.fromMeltQuote(quote);
    }

    /// Verify melt request is valid
    pub fn verifyMeltRequest(
        self: *Mint,
        gpa: std.mem.Allocator,
        melt_request: nuts.nut05.MeltBolt11Request,
    ) !MeltQuote {
        const quote_id = try zul.UUID.parse(melt_request.quote);
        const state = try self
            .localstore
            .value
            .updateMeltQuoteState(quote_id, .pending);

        switch (state) {
            .unpaid => {},
            .pending => return error.PendingQuote,
            .paid => return error.PaidQuote,
        }

        var ys = try std.ArrayList(secp256k1.PublicKey).initCapacity(gpa, melt_request.inputs.len);
        defer ys.deinit();

        for (melt_request.inputs) |p| {
            ys.appendAssumeCapacity(try core.dhke.hashToCurve(p.secret.toBytes()));
        }

        // Ensure proofs are unique and not being double spent
        {
            var h = std.AutoHashMap(secp256k1.PublicKey, void).init(gpa);
            defer h.deinit();

            for (ys.items) |pk| try h.put(pk, {});
            if (h.count() != melt_request.inputs.len) return error.DuplicateProofs;
        }

        try self.localstore
            .value
            .addProofs(melt_request.inputs);

        try self.checkYsSpendable(ys.items, .pending);

        for (melt_request.inputs) |proof| {
            try self.verifyProof(proof);
        }

        const quote = try self.localstore
            .value
            .getMeltQuote(gpa, quote_id) orelse return error.UnknownQuote;
        errdefer quote.deinit(gpa);

        const proofs_total = melt_request.proofsAmount();

        const fee = try self.getProofsFee(gpa, melt_request.inputs);

        const required_total = quote.amount + quote.fee_reserve + fee;

        if (proofs_total < required_total) {
            std.log.info(
                "Swap request without enough inputs: {any}, quote amount {any}, fee_reserve: {any} fee {any}",
                .{
                    proofs_total,
                    quote.amount,
                    quote.fee_reserve,
                    fee,
                },
            );
            return error.InsufficientInputs;
        }

        var input_keyset_ids = std.AutoHashMap(nuts.Id, void).init(gpa);
        defer input_keyset_ids.deinit();

        {
            for (melt_request.inputs) |p| {
                try input_keyset_ids.put(p.keyset_id, {});
            }
        }

        var keyset_units = std.AutoHashMap(nuts.CurrencyUnit, void).init(gpa);
        defer keyset_units.deinit();
        {
            var it = input_keyset_ids.keyIterator();

            while (it.next()) |id| {
                const keyset = try self.localstore
                    .value
                    .getKeysetInfo(gpa, id.*) orelse return error.UnknownKeySet;
                defer keyset.deinit(gpa);

                try keyset_units.put(keyset.unit, {});
            }
        }

        var enforce_sig_flag = try nuts.nut11.enforceSigFlag(gpa, melt_request.inputs);
        defer enforce_sig_flag.deinit();

        if (enforce_sig_flag.sig_flag == .sig_all) return error.SigAllUsedInMelt;

        if (melt_request.outputs) |outputs| {
            var output_keysets_ids = std.AutoHashMap(nuts.Id, void).init(gpa);
            defer output_keysets_ids.deinit();

            for (outputs) |b| {
                try output_keysets_ids.put(b.keyset_id, {});
            }

            {
                var it = output_keysets_ids.keyIterator();
                while (it.next()) |id| {
                    var keyset = try self.localstore
                        .value
                        .getKeysetInfo(gpa, id.*) orelse return error.UnknownKeySet;
                    defer keyset.deinit(gpa);

                    // Get the active keyset for the unit
                    const active_keyset_id = self.localstore
                        .value
                        .getActiveKeysetId(keyset.unit) orelse return error.InactiveKeyset;

                    // Check output is for current active keyset
                    if (!(std.meta.eql(id.*, active_keyset_id))) {
                        return error.InactiveKeyset;
                    }

                    try keyset_units.put(keyset.unit, {});
                }
            }
        }

        // Check that all input and output proofs are the same unit
        if (keyset_units.count() > 1) {
            return error.MultipleUnits;
        }

        std.log.debug("Verified melt quote: {s}", .{melt_request.quote});

        return quote;
    }

    /// Process unpaid melt request
    /// In the event that a melt request fails and the lighthing payment is not made
    /// The [`Proofs`] should be returned to an unspent state and the quote should be unpaid
    pub fn processUnpaidMelt(self: *Mint, melt_request: core.nuts.nut05.MeltBolt11Request) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var input_ys = try std.ArrayList(secp256k1.PublicKey).initCapacity(arena.allocator(), melt_request.inputs.len);
        defer input_ys.deinit();

        for (melt_request.inputs) |p| input_ys.appendAssumeCapacity(try core.dhke.hashToCurve(p.secret.toBytes()));

        _ = try self.localstore
            .value
            .updateProofsStates(arena.allocator(), input_ys.items, .unspent);

        _ = try self.localstore
            .value
            .updateMeltQuoteState(try zul.UUID.parse(melt_request.quote), .unpaid);
    }

    /// Update mint quote
    pub fn updateMintQuote(self: *Mint, quote: MintQuote) !void {
        try self.localstore.value.addMintQuote(quote);
    }

    /// Process melt request marking [`Proofs`] as spent
    /// The melt request must be verifyed using [`Self::verify_melt_request`] before calling [`Self::process_melt_request`]
    pub fn processMeltRequest(
        self: *Mint,
        arena: std.mem.Allocator,
        melt_request: nuts.nut05.MeltBolt11Request,
        payment_preimage: ?[]const u8,
        total_spent: core.amount.Amount,
    ) !core.nuts.nut05.MeltQuoteBolt11Response {
        std.log.debug("Processing melt quote: {s}", .{melt_request.quote});

        const quote_id = try zul.UUID.parse(melt_request.quote);

        const quote = try self
            .localstore
            .value
            .getMeltQuote(arena, quote_id) orelse return error.UnknownQuote;

        var input_ys = std.ArrayList(secp256k1.PublicKey).init(arena);

        for (melt_request.inputs) |p| try input_ys.append(try core.dhke.hashToCurve(p.secret.toBytes()));

        if (self.localstore
            .value
            .updateProofsStates(arena, input_ys.items, .spent)) |states| states.deinit() else |err| return err;

        _ = try self.localstore
            .value
            .updateMeltQuoteState(quote_id, .paid);

        var change: ?std.ArrayList(core.nuts.BlindSignature) = null;

        // Check if there is change to return
        if (melt_request.proofsAmount() > total_spent) {
            // Check if wallet provided change outputs
            if (melt_request.outputs) |outputs| {
                var blinded_messages = try std.ArrayList(secp256k1.PublicKey).initCapacity(arena, outputs.len);
                defer blinded_messages.deinit();

                for (outputs) |o| blinded_messages.appendAssumeCapacity(o.blinded_secret);

                if ((if (self.localstore
                    .value
                    .getBlindSignatures(arena, blinded_messages.items)) |bm|
                    bm.getLastOrNull()
                else |err|
                    return err) != null)
                {
                    std.log.info("Output has already been signed", .{});
                    return error.BlindedMessageAlreadySigned;
                }

                const change_target = melt_request.proofsAmount() - total_spent;
                const amounts = try core.amount.split(change_target, arena);
                var change_sigs = try std.ArrayList(nuts.BlindSignature).initCapacity(arena, amounts.items.len);

                if (outputs.len < amounts.items.len) {
                    std.log.debug("Providing change requires {} blinded messages, but only {} provided", .{ amounts.items.len, outputs.len });
                    // In the case that not enough outputs are provided to return all change
                    // Reverse sort the amounts so that the most amount of change possible is
                    // returned. The rest is burnt
                    std.sort.block(u64, amounts.items, {}, (struct {
                        fn compare(_: void, a: u64, b: u64) bool {
                            return b < a;
                        }
                    }).compare);
                }

                const _outputs = try arena.dupe(nuts.BlindedMessage, outputs);

                const zip_len = @min(amounts.items.len, _outputs.len);

                for (amounts.items[0..zip_len], _outputs[0..zip_len]) |amount, *blinded_message| {
                    blinded_message.amount = amount;

                    const blinded_signature = try self.blindSign(
                        arena,
                        blinded_message.*,
                    );

                    try change_sigs.append(blinded_signature);
                }

                try self.localstore
                    .value
                    .addBlindSignatures(
                    blinded_messages.items,
                    change_sigs.items,
                    melt_request.quote,
                );

                change = change_sigs;
            }
        }

        return .{
            .amount = quote.amount,
            .paid = true,
            .payment_preimage = payment_preimage,
            .change = if (change) |c| c.items else null,
            .quote = quote.id.toHex(.lower),
            .fee_reserve = quote.fee_reserve,
            .state = .paid,
            .expiry = quote.expiry,
        };
    }
};

/// Generate new [`MintKeySetInfo`] from path
fn createNewKeysetAlloc(
    allocator: std.mem.Allocator,
    secp: secp256k1.Secp256k1,
    xpriv: bip32.ExtendedPrivKey,
    derivation_path: []const bip32.ChildNumber,
    derivation_path_index: ?u32,
    unit: core.nuts.CurrencyUnit,
    max_order: u8,
    input_fee_ppk: u64,
) !struct { MintKeySet, MintKeySetInfo } {
    const keyset = try MintKeySet.generate(
        allocator,
        secp,
        xpriv
            .derivePriv(secp, derivation_path) catch @panic("RNG busted"),
        unit,
        max_order,
    );

    const keyset_info = try MintKeySetInfo.clone(.{
        .id = keyset.id,
        .unit = keyset.unit,
        .active = true,
        .valid_from = @intCast(std.time.timestamp()),
        .valid_to = null,
        .derivation_path = derivation_path,
        .derivation_path_index = derivation_path_index,
        .max_order = max_order,
        .input_fee_ppk = input_fee_ppk,
    }, allocator);

    return .{ keyset, keyset_info };
}

fn derivationPathFromUnit(unit: core.nuts.CurrencyUnit, index: u32) [3]bip32.ChildNumber {
    return .{
        bip32.ChildNumber.fromHardenedIdx(0) catch @panic("0 is a valid index"),
        bip32.ChildNumber.fromHardenedIdx(unit.derivationIndex()) catch @panic("0 is a valid index"),
        bip32.ChildNumber.fromHardenedIdx(index) catch @panic("0 is a valid index"),
    };
}

const expectEqual = std.testing.expectEqual;

test "mint mod generate keyset from seed" {
    const seed = "test_seed";

    var secp = secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    var keyset = try MintKeySet.generateFromSeed(
        std.testing.allocator,
        secp,
        seed,
        2,
        .sat,
        &derivationPathFromUnit(.sat, 0),
    );
    defer keyset.deinit();

    try expectEqual(.sat, keyset.unit);
    try expectEqual(2, keyset.keys.inner.count());

    try expectEqual(try secp256k1.PublicKey.fromString("0257aed43bf2c1cdbe3e7ae2db2b27a723c6746fc7415e09748f6847916c09176e"), keyset.keys.inner.get(1).?.public_key);
    try expectEqual(try secp256k1.PublicKey.fromString("03ad95811e51adb6231613f9b54ba2ba31e4442c9db9d69f8df42c2b26fbfed26e"), keyset.keys.inner.get(2).?.public_key);
}

test "mint mod generate keyset from xpriv" {
    const seed = "test_seed";

    var secp = secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    const xpriv = try bip32.ExtendedPrivKey.initMaster(.MAINNET, seed);

    var keyset = try MintKeySet.generateFromXpriv(
        std.testing.allocator,
        secp,
        xpriv,
        2,
        .sat,
        &derivationPathFromUnit(.sat, 0),
    );
    defer keyset.deinit();

    try expectEqual(.sat, keyset.unit);
    try expectEqual(2, keyset.keys.inner.count());

    try expectEqual(try secp256k1.PublicKey.fromString("0257aed43bf2c1cdbe3e7ae2db2b27a723c6746fc7415e09748f6847916c09176e"), keyset.keys.inner.get(1).?.public_key);
    try expectEqual(try secp256k1.PublicKey.fromString("03ad95811e51adb6231613f9b54ba2ba31e4442c9db9d69f8df42c2b26fbfed26e"), keyset.keys.inner.get(2).?.public_key);
}

const MintConfig = struct {
    active_keysets: std.AutoHashMap(CurrencyUnit, core.nuts.Id),
    keysets: []const MintKeySetInfo = &.{},
    mint_quotes: []const MintQuote = &.{},
    melt_quotes: []const MeltQuote = &.{},
    pending_proofs: []const core.nuts.Proof = &.{},
    spent_proofs: []const core.nuts.Proof = &.{},
    blinded_signatures: std.AutoHashMap([33]u8, core.nuts.BlindSignature),
    mint_url: []const u8 = &.{},
    seed: []const u8 = &.{},
    mint_info: MintInfo = .{},
    supported_units: std.AutoHashMap(CurrencyUnit, std.meta.Tuple(&.{ u64, u8 })),
};

fn createMint(arena: std.mem.Allocator, config: MintConfig) !Mint {
    const db = try MintMemoryDatabase.initFrom(arena, config.active_keysets, config.keysets, config.mint_quotes, config.melt_quotes, config.pending_proofs, config.spent_proofs, config.blinded_signatures);

    const _db = try MintDatabase.initFrom(MintMemoryDatabase, arena, db);

    return Mint.init(
        arena,
        config.mint_url,
        config.seed,
        config.mint_info,
        _db,
        config.supported_units,
    );
}

test "mint mod rotate keyset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const config = MintConfig{
        .active_keysets = std.AutoHashMap(CurrencyUnit, core.nuts.Id).init(allocator),
        .blinded_signatures = std.AutoHashMap([33]u8, core.nuts.BlindSignature).init(allocator),
        .supported_units = std.AutoHashMap(CurrencyUnit, std.meta.Tuple(&.{ u64, u8 })).init(allocator),
    };

    var mint = try createMint(allocator, config);

    // dont deallocate due arena allocator
    var keysets = try mint.getKeysets(allocator);

    try expectEqual(0, keysets.keysets.len);

    // generate the first keyset and set it to active
    try mint.rotateKeyset(allocator, .sat, 0, 1, 1);

    // dont deallocate due arena allocator
    keysets = try mint.getKeysets(allocator);

    try expectEqual(1, keysets.keysets.len);
    try expectEqual(true, keysets.keysets[0].active);

    const first_keyset_id = keysets.keysets[0].id;

    // set the first keyset to inactive and generate a new keyset
    try mint.rotateKeyset(allocator, .sat, 1, 1, 1);

    // dont deallocate due arena allocator
    keysets = try mint.getKeysets(allocator);

    try expectEqual(2, keysets.keysets.len);

    for (keysets.keysets) |keyset| {
        if (std.meta.eql(keyset.id, first_keyset_id)) {
            try expectEqual(false, keyset.active);
        } else {
            try expectEqual(true, keyset.active);
        }
    }
}
