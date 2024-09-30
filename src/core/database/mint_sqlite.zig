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
    errdefer std.log.debug("{any}", .{@errorReturnTrace()});

    std.log.debug("initializing database", .{});
    try conn.busyTimeout(1000);
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
        \\
        \\ CREATE TABLE IF NOT EXISTS blind_signature (
        \\     y BLOB PRIMARY KEY,
        \\     amount INTEGER NOT NULL,
        \\     keyset_id TEXT NOT NULL,
        \\     quote_id TEXT,
        \\     c BLOB NOT NULL
        \\ );
        \\ 
        \\ CREATE INDEX IF NOT EXISTS keyset_id_index ON blind_signature(keyset_id);
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
        self.pool.deinit();
    }

    /// initFrom - take own on all data there, except slices (only own data in slices)
    pub fn initFrom(
        allocator: std.mem.Allocator,
        path: [*:0]const u8,
    ) !Database {
        const pool = try sqlite.Pool.init(allocator, .{
            .size = 5,
            .flags = sqlite.OpenFlags.Create | sqlite.OpenFlags.EXResCode,
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

        try conn.exec("INSERT INTO active_keysets (currency_unit, id) VALUES (?1, ?2) ON CONFLICT DO UPDATE SET id = ?2;", .{ @intFromEnum(unit), sqlite.blob(&id.toString()) });
    }

    pub fn getActiveKeysetId(self: *Self, unit: nuts.CurrencyUnit) ?nuts.Id {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        if (conn.row("SELECT id FROM active_keysets WHERE currency_unit = ?1", .{@intFromEnum(unit)}) catch return null) |row| {
            defer row.deinit(); // must be called
            const id_blob = row.blob(0);

            const id = nuts.Id.fromStr(id_blob) catch unreachable;

            return id;
        }

        return null;
    }

    /// caller own result data, so responsible to deallocate
    pub fn getActiveKeysets(self: *Self, allocator: std.mem.Allocator) !std.AutoHashMap(nuts.CurrencyUnit, nuts.Id) {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        var rows = try conn.rows("SELECT id, currency_unit FROM active_keysets", .{});
        defer rows.deinit();

        var result = std.AutoHashMap(nuts.CurrencyUnit, nuts.Id).init(allocator);
        errdefer result.deinit();

        while (rows.next()) |row| {
            const id_blob = row.blob(0);

            const id = nuts.Id.fromStr(id_blob) catch unreachable;
            const unit: nuts.CurrencyUnit = @enumFromInt(row.int(1));

            try result.put(unit, id);
        }

        return result;
    }

    /// keyset inside is cloned, so caller own keyset
    pub fn addKeysetInfo(self: *Self, keyset: MintKeySetInfo) !void {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        const keyset_encoded = try std.json.stringifyAlloc(self.allocator, keyset, .{});
        defer self.allocator.free(keyset_encoded);

        try conn.exec(
            \\INSERT INTO keysets (id, keyset_info)
            \\VALUES (?1, ?2)
            \\  ON CONFLICT (id) DO UPDATE SET keyset_info=?2;
        , .{
            sqlite.blob(&keyset.id.toBytes()),
            sqlite.blob(keyset_encoded),
        });
    }

    /// caller own result, so responsible to free
    pub fn getKeysetInfo(self: *Self, allocator: std.mem.Allocator, keyset_id: nuts.Id) !?MintKeySetInfo {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        if (try conn.row("SELECT keyset_info FROM keysets WHERE id = ?1", .{
            sqlite.blob(&keyset_id.toBytes()),
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

        res.value = std.ArrayList(MintKeySetInfo).init(res.arena.allocator());

        var rows = try conn.rows("SELECT id, keyset_info FROM keysets", .{});
        defer rows.deinit();

        while (rows.next()) |row| {
            const keyset_info_encoded = row.blob(1);
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

        try conn.exec("INSERT INTO mint_quote (id, quote) VALUES (?1, ?2) ON CONFLICT DO UPDATE SET quote = ?2;", .{
            sqlite.blob(&quote.id.bin),
            sqlite.blob(quote_json),
        });
    }

    // caller must free MintQuote
    pub fn getMintQuote(self: *Self, allocator: std.mem.Allocator, quote_id: zul.UUID) !?MintQuote {
        {
            var conn = self.pool.acquire();
            defer self.pool.release(conn);

            if (try conn.row("SELECT quote FROM mint_quote WHERE id = ?1", .{
                sqlite.blob(&quote_id.bin),
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

        const quote_json = try std.json.stringifyAlloc(self.allocator, quote, .{});
        defer self.allocator.free(quote_json);

        try conn.exec("UPDATE mint_quote SET quote = ?1 WHERE id = ?2", .{
            sqlite.blob(quote_json),
            sqlite.blob(&quote_id.bin),
        });

        return old_state;
    }

    /// caller must free array list and every elements
    pub fn getMintQuotes(self: *Self, allocator: std.mem.Allocator) !std.ArrayList(MintQuote) {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        var rows = try conn.rows("SELECT quote FROM mint_quote", .{});
        defer rows.deinit();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // creating result array list with caller allocator
        var res = std.ArrayList(MintQuote).init(allocator);
        errdefer {
            for (res.items) |it| it.deinit(allocator);
            res.deinit();
        }

        while (rows.next()) |row| {
            const quote_json = row.blob(0);

            const quote = try std.json.parseFromSliceLeaky(MintQuote, arena.allocator(), quote_json, .{});

            try res.append(try quote.clone(allocator));
        }

        return res;
    }

    /// caller responsible to free resources
    pub fn getMintQuoteByRequestLookupId(
        self: *Self,
        allocator: std.mem.Allocator,
        request: []const u8,
    ) !?MintQuote {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // no need in free resources due arena
        const quotes = try self.getMintQuotes(arena.allocator());
        for (quotes.items) |q| {
            // if we found, cloning with allocator, so caller responsible on free resources
            if (std.mem.eql(u8, q.request_lookup_id, request)) return try q.clone(allocator);
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
            for (quotes.items) |q| q.deinit(self.allocator);
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

        try conn.exec("DELETE FROM mint_quote WHERE id = ?1", .{sqlite.blob(&quote_id.bin)});
    }

    pub fn addMeltQuote(self: *Self, quote: MeltQuote) !void {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        const quote_json = try std.json.stringifyAlloc(self.allocator, quote, .{});
        defer self.allocator.free(quote_json);

        try conn.exec("INSERT INTO melt_quote (id, quote) VALUES (?1, ?2) ON CONFLICT DO UPDATE SET quote = ?2;", .{
            sqlite.blob(&quote.id.bin),
            sqlite.blob(quote_json),
        });
    }

    // caller must free MeltQuote
    pub fn getMeltQuote(self: *Self, allocator: std.mem.Allocator, quote_id: zul.UUID) !?MeltQuote {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        if (try conn.row("SELECT quote FROM melt_quote WHERE id = ?1", .{
            sqlite.blob(&quote_id.bin),
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

        const quote_json = try std.json.stringifyAlloc(self.allocator, quote, .{});
        defer self.allocator.free(quote_json);

        try conn.exec("UPDATE melt_quote SET quote = ?1 WHERE id = ?2", .{
            sqlite.blob(quote_json),
            sqlite.blob(&quote_id.bin),
        });

        return old_state;
    }

    /// caller must free array list and every elements
    pub fn getMeltQuotes(self: *Self, allocator: std.mem.Allocator) !std.ArrayList(MeltQuote) {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        var rows = try conn.rows("SELECT quote FROM melt_quote", .{});
        defer rows.deinit();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // creating result array list with caller allocator
        var res = std.ArrayList(MeltQuote).init(allocator);
        errdefer {
            for (res.items) |it| it.deinit(allocator);
            res.deinit();
        }

        while (rows.next()) |row| {
            const quote_json = row.blob(0);

            const quote = try std.json.parseFromSliceLeaky(MeltQuote, arena.allocator(), quote_json, .{});

            try res.append(try quote.clone(allocator));
        }

        return res;
    }

    /// caller responsible to free resources
    pub fn getMeltQuoteByRequestLookupId(
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
            if (std.mem.eql(u8, q.request_lookup_id, request)) return try q.clone(allocator);
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
    ) !void {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        try conn.exec("DELETE FROM melt_quote WHERE id = ?1", .{sqlite.blob(&quote_id.bin)});
    }

    pub fn addProofs(self: *Self, proofs: []const nuts.Proof) !void {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        try conn.transaction();
        errdefer conn.rollback();

        for (proofs) |proof| {
            // TODO fix witness encode
            // const witness_json: ?[]const u8 = if (proof.witness) |w| try std.json.stringifyAlloc(self.allocator, w, .{}) else null;
            const witness_json: ?[]const u8 = null;
            defer if (witness_json) |wj| self.allocator.free(wj);

            std.log.debug("insert proof y {s}", .{
                (try proof.y()).toString(),
            });

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

        try conn.commit();
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
            if (try conn.row("SELECT * FROM proof WHERE y=?1;", .{sqlite.blob(&y.serialize())})) |row| {
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
        proofs_state: nuts.nut07.State,
    ) !std.ArrayList(?nuts.nut07.State) {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        try conn.transaction();
        errdefer conn.rollback();

        var states = try std.ArrayList(?nuts.nut07.State).initCapacity(allocator, ys.len);
        errdefer states.deinit();

        const proofs_state_str = proofs_state.toString();

        for (ys) |y| {
            const y_bytes = y.serialize();

            const currenct_state: ?nuts.nut07.State = if (try conn.row("SELECT state FROM proof WHERE y = ?1", .{sqlite.blob(&y_bytes)})) |row| v: {
                defer row.deinit();
                break :v try nuts.nut07.State.fromString(row.text(0));
            } else null;

            states.appendAssumeCapacity(currenct_state);

            if (currenct_state) |cs| {
                if (cs != .spent) {
                    try conn.exec("UPDATE proof SET state = ?1 WHERE y = ?2", .{ proofs_state_str, sqlite.blob(&y_bytes) });
                }
            }
        }

        try conn.commit();

        return states;
    }

    // caller must free result
    pub fn getProofsStates(self: *Self, allocator: std.mem.Allocator, ys: []const secp256k1.PublicKey) !std.ArrayList(?nuts.nut07.State) {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        var states = try std.ArrayList(?nuts.nut07.State).initCapacity(allocator, ys.len);
        errdefer states.deinit();

        for (ys) |y| {
            const row = try conn.row("SELECT * FROM proof WHERE y=?1;", .{
                sqlite.blob(&y.serialize()),
            });

            const state: ?nuts.nut07.State = if (row) |r| v: {
                defer r.deinit();
                break :v try nuts.nut07.State.fromString(r.text(0));
            } else null;

            states.appendAssumeCapacity(state);
        }

        return states;
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
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        var rows = try conn.rows("SELECT amount, keyset_id, secret, c, witness, state FROM proof WHERE keyset_id=?1;", .{id.toString()});
        defer rows.deinit();

        var res = try Arened(std.meta.Tuple(&.{
            std.ArrayList(nuts.Proof),
            std.ArrayList(?nuts.nut07.State),
        })).init(allocator);
        errdefer res.deinit();

        var proofs_for_id = std.ArrayList(nuts.Proof).init(res.arena.allocator());
        var states = std.ArrayList(?nuts.nut07.State).init(res.arena.allocator());

        while (rows.next()) |r| {
            const proof, const state = try sqliteRowToProofWithState(res.arena.allocator(), r);
            try proofs_for_id.append(proof);
            try states.append(state);
        }

        res.value[0] = proofs_for_id;
        res.value[1] = states;

        return res;
    }

    pub fn addBlindSignatures(
        self: *Self,
        blinded_messages: []const secp256k1.PublicKey,
        blind_signatures: []const nuts.BlindSignature,
        quote_id: ?[]const u8,
    ) !void {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        try conn.transaction();
        errdefer conn.rollback();

        // zip to arrays
        const max_len = @min(blinded_messages.len, blind_signatures.len);

        for (blinded_messages[0..max_len], blind_signatures[0..max_len]) |msg, signature| {
            const sql =
                \\ INSERT INTO blind_signature
                \\ (y, amount, keyset_id, c, quote_id)
                \\ VALUES (?1, ?2, ?3, ?4, ?5);
            ;

            try conn.exec(sql, .{
                sqlite.blob(&msg.serialize()),
                @as(i64, @intCast(signature.amount)),
                signature.keyset_id.toString(),
                sqlite.blob(&signature.c.serialize()),
                quote_id,
            });
        }

        try conn.commit();
    }

    pub fn getBlindSignatures(
        self: *Self,
        allocator: std.mem.Allocator,
        blinded_messages: []const secp256k1.PublicKey,
    ) !std.ArrayList(?nuts.BlindSignature) {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        var res = try std.ArrayList(?nuts.BlindSignature).initCapacity(allocator, blinded_messages.len);
        errdefer res.deinit();

        for (blinded_messages) |msg| {
            const sql =
                "SELECT amount, keyset_id, c FROM blind_signature WHERE y=?1;";

            if (try conn.row(sql, .{sqlite.blob(&msg.serialize())})) |row| {
                defer row.deinit();
                const blinded = try sqliteRowToBlindSignature(row);

                res.appendAssumeCapacity(blinded);
            } else res.appendAssumeCapacity(null);
        }

        return res;
    }

    /// caller response to free resources
    pub fn getBlindSignaturesForKeyset(
        self: *Self,
        allocator: std.mem.Allocator,
        keyset_id: nuts.Id,
    ) !std.ArrayList(nuts.BlindSignature) {
        var conn = self.pool.acquire();
        defer self.pool.release(conn);

        var res = std.ArrayList(nuts.BlindSignature).init(allocator);
        errdefer res.deinit();

        const sql =
            "SELECT amount, keyset_id, c FROM blind_signature WHERE keyset_id=?1;";

        var rows = try conn.rows(sql, .{keyset_id.toString()});
        defer rows.deinit();

        while (rows.next()) |row| {
            const blinded = try sqliteRowToBlindSignature(row);

            try res.append(blinded);
        }

        return res;
    }
};

fn sqliteRowToBlindSignature(row: sqlite.Row) !nuts.BlindSignature {
    const row_amount: i64 = row.int(0);
    const keyset_id: []const u8 = row.text(1);

    const row_c = row.blob(2);

    return .{
        .amount = @abs(row_amount),
        .keyset_id = try nuts.Id.fromStr(keyset_id),
        .c = try secp256k1.PublicKey.fromSlice(row_c),
        .dleq = null,
    };
}

// amount, keyset_id, secret, c, witness
fn sqliteRowToProof(arena: std.mem.Allocator, row: sqlite.Row) !nuts.Proof {
    const amount = row.int(0);
    const keyset_id = row.text(1);
    const row_secret = row.text(2);
    const row_c = row.blob(3);
    const wintess = row.nullableText(4);

    return .{
        .amount = @intCast(amount),
        .keyset_id = try nuts.Id.fromStr(keyset_id),
        .secret = .{ .inner = row_secret },
        .c = try secp256k1.PublicKey.fromSlice(row_c),
        .witness = if (wintess) |w| try std.json.parseFromSliceLeaky(nuts.Witness, arena, w, .{}) else null,
        .dleq = null,
    };
}

// amount, keyset_id, secret, c, witness, state
fn sqliteRowToProofWithState(arena: std.mem.Allocator, row: sqlite.Row) !struct { nuts.Proof, ?nuts.State } {
    const amount = row.int(0);
    const keyset_id = row.text(1);
    const row_secret = row.text(2);
    const row_c = row.blob(3);
    const wintess = row.nullableText(4);

    const row_state = row.nullableText(5);

    const state: ?nuts.nut07.State = if (row_state) |rs| try nuts.nut07.State.fromString(rs) else null;

    return .{
        .{
            .amount = @intCast(amount),
            .keyset_id = try nuts.Id.fromStr(keyset_id),
            .secret = .{ .inner = row_secret },
            .c = try secp256k1.PublicKey.fromSlice(row_c),
            .witness = if (wintess) |w| try std.json.parseFromSliceLeaky(nuts.Witness, arena, w, .{}) else null,
            .dleq = null,
        },
        state,
    };
}
