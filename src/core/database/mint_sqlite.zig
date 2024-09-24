const std = @import("std");
const nuts = @import("../nuts/lib.zig");
const dhke = @import("../dhke.zig");
const zul = @import("zul");
const bitcoin_primitives = @import("bitcoin-primitives");
const secp256k1 = bitcoin_primitives.secp256k1;
const sqlite = @import("zqlite");
const secret = @import("../secret.zig");

const Arened = @import("../../helper/helper.zig").Parsed;
const MintKeySetInfo = @import("../mint/mint.zig").MintKeySetInfo;
const MintQuote = @import("../mint/mint.zig").MintQuote;
const MeltQuote = @import("../mint/mint.zig").MeltQuote;

/// Executes ones, on first connection, this like migration
fn initializeDB(conn: sqlite.Conn) !void {
    const sql =
        \\CREATE TABLE if not exists active_keysets ( currency_unit INTEGER PRIMARY KEY, id BLOB);
        \\CREATE TABLE if not exists keysets ( id BLOB PRIMARY KEY, keyset_info JSONB);
        \\CREATE TABLE if not exists melt_quote ( id BLOB PRIMARY KEY, quote JSONB);
        \\CREATE TABLE if not exists mint_quote ( id BLOB PRIMARY KEY, quote JSONB);
        \\ CREATE TABLE IF NOT EXISTS proof (
        \\     y BLOB PRIMARY KEY,
        \\     amount INTEGER NOT NULL,
        \\     keyset_id TEXT NOT NULL,
        \\     secret TEXT NOT NULL,
        \\     c BLOB NOT NULL,
        \\     witness TEXT,
        \\     state TEXT CHECK ( state IN ('SPENT', 'PENDING' ) ) NOT NULL
        \\ );
        \\ 
        \\ CREATE INDEX IF NOT EXISTS state_index ON proof(state);
        \\ CREATE INDEX IF NOT EXISTS secret_index ON proof(secret);
        \\CREATE TABLE if not exists proof_states ( id BLOB PRIMARY KEY, proof INTEGER);
        \\CREATE TABLE if not exists blind_signatures ( id BLOB PRIMARY KEY, blind_signature BLOB);
    ;

    try conn.execNoArgs(sql);
}

/// TODO simple solution for rw locks, use on all structure, as temp solution
/// Mint Memory Database
pub const Database = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    pool: sqlite.Pool,

    pub fn deinit(self: *Database) void {
        _ = self; // autofix
    }

    /// initFrom - take own on all data there, except slices (only own data in slices)
    pub fn initFrom(
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !Database {
        const pool = try sqlite.Pool.init(allocator, .{
            .size = 5,
            .on_first_connection = &initializeDB,
            .path = path,
        });

        return .{
            .pool = pool,
            .allocator = allocator,
        };
    }

    pub fn setActiveKeyset(self: *Self, unit: nuts.CurrencyUnit, id: nuts.Id) !void {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        try conn.exec("UPSERT INTO active_keysets (currency_unit, id) VALUES (?1, ?2);", .{ @intFromEnum(unit), sqlite.blob(std.mem.asBytes(id)) });
    }

    pub fn getActiveKeysetId(self: *Self, unit: nuts.CurrencyUnit) ?nuts.Id {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        if (try conn.row("SELECT id FROM active_keysets WHERE currency_unit = ?1", .{@intFromEnum(unit)})) |row| {
            defer row.deinit(); // must be called
            const id_blob = row.blob(0);

            const id: nuts.Id = @bitCast(id_blob);
            return id;
        }

        return null;
    }

    /// caller own result data, so responsible to deallocate
    pub fn getActiveKeysets(self: *Self, allocator: std.mem.Allocator) !std.AutoHashMap(nuts.CurrencyUnit, nuts.Id) {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        const rows = try conn.rows("SELECT id, currency_nuit FROM active_keysets", .{});
        defer rows.deinit();

        var result = std.AutoHashMap(nuts.CurrencyUnit, nuts.Id).init(allocator);
        errdefer result.deinit();

        while (rows.next()) |row| {
            defer row.deinit();

            const id_blob = row.blob(0);

            const id: nuts.Id = @bitCast(id_blob);
            const unit: nuts.CurrencyUnit = @enumFromInt(row.int(1));

            try result.put(unit, id);
        }
    }

    /// keyset inside is cloned, so caller own keyset
    pub fn addKeysetInfo(self: *Self, keyset: MintKeySetInfo) !void {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        const keyset_encoded = try std.json.stringifyAlloc(self.allocator, keyset, .{});
        defer self.allocator.free(keyset_encoded);

        try conn.exec("UPSERT INTO keysets (id, keyset_info) VALUES (?1, ?2);", .{
            sqlite.blob(std.mem.asBytes(keyset.id)),
            sqlite.blob(keyset_encoded),
        });
    }

    /// caller own result, so responsible to free
    pub fn getKeysetInfo(self: *Self, allocator: std.mem.Allocator, keyset_id: nuts.Id) !?MintKeySetInfo {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        if (try conn.row("SELECT keyset_info FROM keysets WHERE id = ?1", .{
            sqlite.blob(std.mem.asBytes(keyset_id)),
        })) |row| {
            defer row.deinit(); // must be called
            const keyset_info_encoded = row.blob(0);

            const decoded_ks_info = try std.json.parseFromSlice(MintKeySetInfo, self.allocator, keyset_info_encoded, .{});
            defer decoded_ks_info.deinit();

            return try decoded_ks_info.value.clone(allocator);
        }

        return null;
    }

    pub fn getKeysetInfos(self: *Self, allocator: std.mem.Allocator) !Arened(std.ArrayList(MintKeySetInfo)) {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        var res = try Arened(std.ArrayList(MintKeySetInfo)).init(allocator);
        errdefer res.deinit();

        res.value = try std.ArrayList(MintKeySetInfo).initCapacity(res.arena.allocator(), self.keysets.count());

        const rows = try conn.rows("SELECT id, keyset_info FROM keysets", .{});
        defer rows.deinit();

        while (rows.next()) |row| {
            defer row.deinit();

            const keyset_info_encoded = row.blob(0);

            // using arena allocator from result
            const decoded_ks_info = try std.json.parseFromSliceLeaky(MintKeySetInfo, res.arena.allocator(), keyset_info_encoded, .{});

            try res.value.append(decoded_ks_info);
        }

        return res;
    }

    pub fn addMintQuote(self: *Self, quote: MintQuote) !void {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        const quote_json = try std.json.stringifyAlloc(self.allocator, quote, .{});
        defer self.allocator.free(quote_json);

        try conn.exec("UPSERT INTO mint_quote (id, quote) VALUES (?1, ?2);", .{
            sqlite.blob(std.mem.asBytes(quote.id)),
            sqlite.blob(quote_json),
        });
    }

    // caller must free MintQuote
    pub fn getMintQuote(self: *Self, allocator: std.mem.Allocator, quote_id: zul.UUID) !?MintQuote {
        {
            var conn = self.pool.acquire();
            defer self.pool.release(conn);

            if (try conn.row("SELECT quote FROM mint_quote WHERE id = ?1", .{
                sqlite.blob(std.mem.asBytes(quote_id)),
            })) |row| {
                defer row.deinit(); // must be called
                const quote_json = row.blob(0);

                const quote = try std.json.parseFromSlice(MintQuote, self.allocator, quote_json, .{});
                defer quote.deinit();

                return try quote.value.clone(allocator);
            }

            return null;
        }
    }

    pub fn updateMintQuoteState(
        self: *Self,
        quote_id: zul.UUID,
        state: nuts.nut04.QuoteState,
    ) !nuts.nut04.QuoteState {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        var quote = (try self.getMintQuote(self.allocator, quote_id)) orelse return error.UnknownQuote;

        const old_state = quote.state;
        quote.state = state;

        const quote_json = try std.json.stringifyAlloc(self.allocator, MintQuote, .{});
        defer self.allocator.free(quote_json);

        try conn.exec("UPDATE mint_quote SET quote = ?1 WHERE id = ?2", .{
            sqlite.blob(quote_json),
            sqlite.blob(std.mem.asBytes(quote_id)),
        });

        return old_state;
    }

    /// caller must free array list and every elements
    pub fn getMintQuotes(self: *Self, allocator: std.mem.Allocator) !std.ArrayList(MintQuote) {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        const rows = try conn.rows("SELECT quote FROM mint_quote", .{});
        defer rows.deinit();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // creating result array list with caller allocator
        var res = std.ArrayList(MintQuote).init(allocator);
        errdefer {
            for (res.items) |it| it.deinit();
            res.deinit();
        }

        while (rows.next()) |row| {
            defer row.deinit(); // must be called
            const quote_json = row.blob(0);

            const quote = try std.json.parseFromSliceLeaky(MintQuote, self.allocator, quote_json, .{});

            try res.append(try quote.value.clone(allocator));
        }

        return res;
    }

    /// caller responsible to free resources
    pub fn getMintQuoteByRequestLookupId(
        self: *Self,
        allocator: std.mem.Allocator,
        request: zul.UUID,
    ) !?MintQuote {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // no need in free resources due arena
        const quotes = try self.getMintQuotes(arena.allocator());
        for (quotes.items) |q| {
            // if we found, cloning with allocator, so caller responsible on free resources
            if (q.request_lookup_id.eql(request)) return try q.clone(allocator);
        }

        return null;
    }
    /// caller responsible to free resources
    pub fn getMintQuoteByRequest(
        self: *Self,
        allocator: std.mem.Allocator,
        request: []const u8,
    ) !?MintQuote {
        const quotes = try self.getMintQuotes(self.allocator);
        defer {
            for (quotes.items) |q| q.deinit();
            quotes.deinit();
        }

        for (quotes.items) |q| {
            // if we found, cloning with allocator, so caller responsible on free resources
            if (std.mem.eql(u8, q.request, request)) return try q.clone(allocator);
        }

        return null;
    }

    pub fn removeMintQuoteState(
        self: *Self,
        quote_id: zul.UUID,
    ) !void {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        try conn.exec("DELETE FROM mint_quote WHERE id = ?1", .{sqlite.blob(std.mem.asBytes(quote_id))});
    }

    pub fn addMeltQuote(self: *Self, quote: MeltQuote) !void {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        const quote_json = try std.json.stringifyAlloc(self.allocator, quote, .{});
        defer self.allocator.free(quote_json);

        try conn.exec("UPSERT INTO melt_quote (id, quote) VALUES (?1, ?2);", .{
            sqlite.blob(std.mem.asBytes(quote.id)),
            sqlite.blob(quote_json),
        });
    }

    // caller must free MeltQuote
    pub fn getMeltQuote(self: *Self, allocator: std.mem.Allocator, quote_id: zul.UUID) !?MeltQuote {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        if (try conn.row("SELECT quote FROM melt_quote WHERE id = ?1", .{
            sqlite.blob(std.mem.asBytes(quote_id)),
        })) |row| {
            defer row.deinit(); // must be called
            const quote_json = row.blob(0);

            const quote = try std.json.parseFromSlice(MeltQuote, self.allocator, quote_json, .{});
            defer quote.deinit();

            return try quote.value.clone(allocator);
        }

        return null;
    }

    pub fn updateMeltQuoteState(
        self: *Self,
        quote_id: zul.UUID,
        state: nuts.nut05.QuoteState,
    ) !nuts.nut05.QuoteState {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        var quote = (try self.getMeltQuote(self.allocator, quote_id)) orelse return error.UnknownQuote;

        const old_state = quote.state;
        quote.state = state;

        const quote_json = try std.json.stringifyAlloc(self.allocator, MeltQuote, .{});
        defer self.allocator.free(quote_json);

        try conn.exec("UPDATE melt_quote SET quote = ?1 WHERE id = ?2", .{
            sqlite.blob(quote_json),
            sqlite.blob(std.mem.asBytes(quote_id)),
        });

        return old_state;
    }

    /// caller must free array list and every elements
    pub fn getMeltQuotes(self: *Self, allocator: std.mem.Allocator) !std.ArrayList(MeltQuote) {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        const rows = try conn.rows("SELECT quote FROM melt_quote", .{});
        defer rows.deinit();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // creating result array list with caller allocator
        var res = std.ArrayList(MeltQuote).init(allocator);
        errdefer {
            for (res.items) |it| it.deinit();
            res.deinit();
        }

        while (rows.next()) |row| {
            defer row.deinit(); // must be called
            const quote_json = row.blob(0);

            const quote = try std.json.parseFromSliceLeaky(MeltQuote, self.allocator, quote_json, .{});

            try res.append(try quote.value.clone(allocator));
        }

        return res;
    }

    /// caller responsible to free resources
    pub fn getMeltQuoteByRequestLookupId(
        self: *Self,
        allocator: std.mem.Allocator,
        request: zul.UUID,
    ) !?MeltQuote {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // no need in free resources due arena
        const quotes = try self.getMeltQuotes(arena.allocator());
        for (quotes.items) |q| {
            // if we found, cloning with allocator, so caller responsible on free resources
            if (q.request_lookup_id.eql(request)) return try q.clone(allocator);
        }

        return null;
    }

    /// caller responsible to free resources
    pub fn getMeltQuoteByRequest(
        self: *Self,
        allocator: std.mem.Allocator,
        request: []const u8,
    ) !?MeltQuote {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // no need in free resources due arena
        const quotes = try self.getMeltQuotes(arena.allocator());
        for (quotes.items) |q| {
            // if we found, cloning with allocator, so caller responsible on free resources
            if (std.mem.eql(u8, q.request, request)) return try q.clone(allocator);
        }

        return null;
    }

    pub fn removeMeltQuoteState(
        self: *Self,
        quote_id: zul.UUID,
    ) void {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        try conn.exec("DELETE FROM melt_quote WHERE id = ?1", .{sqlite.blob(std.mem.asBytes(quote_id))});
    }

    pub fn addProofs(self: *Self, proofs: []const nuts.Proof) !void {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        try conn.transaction();
        errdefer conn.rollback();

        for (proofs) |proof| {
            const witness_json: ?[]const u8 = if (proof.witness) |w| try std.json.stringifyAlloc(self.allocator, w, .{}) else null;
            defer if (witness_json) |wj| self.allocator.free(wj);

            try conn.exec(
                \\INSERT INTO proof
                \\(y, amount, keyset_id, secret, c, witness, state)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);
            , .{
                sqlite.blob(&(try proof.y()).pk.data),
                @as(i64, @intCast(proof.amount)),
                &proof.keyset_id.toString(),
                proof.secret.toBytes(),
                sqlite.blob(&proof.c.pk.data),
                witness_json,
                "UNSPENT",
            });
        }

        conn.commit();
    }

    // caller must free resources
    pub fn getProofsByYs(self: *Self, allocator: std.mem.Allocator, ys: []const secp256k1.PublicKey) !std.ArrayList(?nuts.Proof) {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        var ys_result = try std.ArrayList(?nuts.Proof).initCapacity(allocator, ys.len);
        errdefer ys_result.deinit();
        errdefer for (ys_result.items) |y| if (y) |_y| _y.deinit(allocator);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        for (ys) |y| {
            if (try conn.row("SELECT * FROM proof WHERE y=?1;", .{sqlite.blob(y.pk.data)})) |row| {
                defer row.deinit();

                const proof = try sqliteRowToProof(arena.allocator(), row);
                ys_result.appendAssumeCapacity(try proof.clone(allocator));
            } else ys_result.appendAssumeCapacity(null);
        }

        return ys_result;
    }

    // caller must deinit result std.ArrayList
    pub fn updateProofsStates(
        self: *Self,
        allocator: std.mem.Allocator,
        ys: []const secp256k1.PublicKey,
        proof_state: nuts.nut07.State,
    ) !std.ArrayList(?nuts.nut07.State) {
        _ = self; // autofix
        _ = allocator; // autofix
        _ = ys; // autofix
        _ = proof_state; // autofix
        return undefined;
    }

    // caller must free result
    pub fn getProofsStates(self: *Self, allocator: std.mem.Allocator, ys: []const secp256k1.PublicKey) !std.ArrayList(?nuts.nut07.State) {
        _ = self; // autofix
        _ = allocator; // autofix
        _ = ys; // autofix
        return undefined;
    }

    // result through Arena, for more easy deallocation
    pub fn getProofsByKeysetId(
        self: *Self,
        allocator: std.mem.Allocator,
        id: nuts.Id,
    ) !Arened(std.meta.Tuple(&.{
        std.ArrayList(nuts.Proof),
        std.ArrayList(?nuts.nut07.State),
    })) {
        _ = self; // autofix
        _ = allocator; // autofix
        _ = id; // autofix
        return undefined;
    }

    pub fn addBlindSignatures(
        self: *Self,
        blinded_messages: []const secp256k1.PublicKey,
        blind_signatures: []const nuts.BlindSignature,
    ) !void {
        _ = self; // autofix
        _ = blinded_messages; // autofix
        _ = blind_signatures; // autofix
        return undefined;
    }

    pub fn getBlindSignatures(
        self: *Self,
        allocator: std.mem.Allocator,
        blinded_messages: []const secp256k1.PublicKey,
    ) !std.ArrayList(?nuts.BlindSignature) {
        _ = self; // autofix
        _ = allocator; // autofix
        _ = blinded_messages; // autofix
        return undefined;
    }

    /// caller response to free resources
    pub fn getBlindSignaturesForKeyset(
        self: *Self,
        allocator: std.mem.Allocator,
        keyset_id: nuts.Id,
    ) !std.ArrayList(nuts.BlindSignature) {
        _ = self; // autofix
        _ = allocator; // autofix
        _ = keyset_id; // autofix
        return undefined;
    }
};

// amount, keyset_id, secret, c, witness
fn sqliteRowToProof(arena: std.mem.Allocator, row: sqlite.Row) !nuts.Proof {
    const amount = row.int(0);
    const keyset_id = row.text(1);
    const row_secret = row.text(2);
    const row_c = row.blob(3);
    const wintess = row.nullableText(4);

    return .{
        .amount = amount,
        .keyset_id = try nuts.Id.fromStr(keyset_id),
        .secret = .{ .inner = row_secret },
        .c = secp256k1.PublicKey.fromSlice(row_c),
        .witness = if (wintess) |w| try std.json.parseFromSliceLeaky(nuts.Witness, arena, w, .{}) else null,
        .dleq = null,
    };
}
