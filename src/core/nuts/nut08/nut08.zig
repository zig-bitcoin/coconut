//! NUT-08: Lightning fee return
//!
//! <https://github.com/cashubtc/nuts/blob/main/08.md>
const MeltBolt11Request = @import("../nut05/nut05.zig").MeltBolt11Request;
const MeltQuoteBolt11Response = @import("../nut05/nut05.zig").MeltQuoteBolt11Response;

/// Total output [`Amount`] for [`MeltBolt11Request`]
pub fn outputAmount(self: MeltBolt11Request) ?u64 {
    var sum: u64 = 0;
    for (self.outputs orelse return null) |proof| {
        sum += proof.amount;
    }
    return sum;
}

/// Total change [`Amount`] for [`MeltQuoteBolt11Response`]
pub fn changeAmount(self: MeltQuoteBolt11Response) ?u64 {
    var sum: u64 = 0;
    for (self.change orelse return null) |b| {
        sum += b.amount;
    }

    return sum;
}
