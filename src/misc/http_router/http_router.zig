const httpz = @import("httpz");
const std = @import("std");

pub const Router = struct {
    const Self = @This();

    ptr: *anyopaque,
    allocator: std.mem.Allocator,

    handleFn: *const fn (ptr: *anyopaque, req: *httpz.Request, res: *httpz.Response) anyerror!?void,
    deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,

    pub fn initFrom(comptime T: type, _allocator: std.mem.Allocator, router: httpz.Router(T, httpz.Action(T))) !Self {
        // implement gen structure
        const gen = struct {
            pub fn handle(pointer: *anyopaque, req: *httpz.Request, res: *httpz.Response) anyerror!?void {
                const self: *httpz.Router(T, httpz.Action(T)) = @ptrCast(@alignCast(pointer));

                const act = self.route(req.method, req.url.raw, req.params) orelse return null;

                return try act.action(self.handler, req, res);
            }

            pub fn deinit(pointer: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *httpz.Router(T, httpz.Action(T)) = @ptrCast(@alignCast(pointer));

                if (std.meta.hasFn(T, "deinit")) {
                    self.deinit();
                }

                allocator.destroy(self);
            }
        };

        const ptr: *httpz.Router(T, httpz.Action(T)) align(1) = try _allocator.create(httpz.Router(T, httpz.Action(T)));
        ptr.* = router;

        return .{
            .ptr = ptr,
            .allocator = _allocator,
            // .size = @sizeOf(T),
            // .align_of = @alignOf(T),
            .handleFn = gen.handle,
            .deinitFn = gen.deinit,
        };
    }

    /// free resources of database
    pub fn deinit(self: Self) void {
        self.deinitFn(self.ptr, self.allocator);
        // clearing pointer
    }

    pub fn handle(self: Self, req: *httpz.Request, res: *httpz.Response) anyerror!?void {
        return self.handleFn(self.ptr, req, res);
    }
};

pub const GlobalRouter = struct {
    router: std.ArrayList(Router),

    pub fn notFound(self: *GlobalRouter, req: *httpz.Request, res: *httpz.Response) !void {
        std.log.debug("trying to found {} {s} ", .{
            req.method,
            req.url.path,
        });

        for (self.router.items) |*r| {
            if (try r.handle(req, res)) |_| break;
        } else {
            return error.NotFound;
        }
    }
};

pub fn DefaultDispatcher(comptime T: type) type {
    return struct {
        pub fn dispatcher(h: T, action: httpz.Action(T), req: *httpz.Request, res: *httpz.Response) !void {
            _ = h; // autofix
            _ = action; // autofix
            _ = req; // autofix
            _ = res; // autofix
        }
    };
}

test "ttt" {
    const SomeHandler = struct {
        s: []const u8,

        pub usingnamespace DefaultDispatcher(@This());

        pub fn test_func(self: @This(), req: *httpz.Request, res: *httpz.Response) !void {
            _ = req; // autofix
            res.body = self.s;
        }
    };

    const sh = SomeHandler{
        .s = "some_custom_response",
    };

    const SomeHandlerRouter = httpz.Router(SomeHandler, httpz.Action(SomeHandler));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var some_router = try SomeHandlerRouter.init(arena.allocator(), SomeHandler.dispatcher, sh);
    some_router.get("/test14", SomeHandler.test_func, .{});

    const ht = @import("httpz").testing;
    var router = GlobalRouter{
        .router = std.ArrayList(Router).init(std.testing.allocator),
    };
    defer router.router.deinit();

    const c_handler = try Router.initFrom(SomeHandler, std.testing.allocator, some_router);
    defer c_handler.deinit();

    try router.router.append(c_handler);

    var srv = try httpz.Server(*GlobalRouter).init(std.testing.allocator, .{}, &router);

    defer srv.deinit();

    // httpz.Router(*Router, httpz.Action(*Router)).init(std.testing.allocator, , )

    var _router = srv.router(.{});
    _router.get("/test1234", GlobalRouter.notFound, .{});

    var web_test = ht.init(.{});
    defer web_test.deinit();

    web_test.url("/test14");

    try router.notFound(web_test.req, web_test.res);

    try web_test.expectBody(sh.s);
}
