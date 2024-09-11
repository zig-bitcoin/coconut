//! Feature flag definitions for the Lightning protocol according to [BOLT #9].
//!
//! Lightning nodes advertise a supported set of operation through feature flags. Features are
//! applicable for a specific context. [`Features`] encapsulates behavior for specifying and
//! checking feature flags for a particular context. Each feature is defined internally by a trait
//! specifying the corresponding flags (i.e., even and odd bits).
//!
//! Whether a feature is considered "known" or "unknown" is relative to the implementation, whereas
//! the term "supports" is used in reference to a particular set of [`Features`]. That is, a node
//! supports a feature if it advertises the feature (as either required or optional) to its peers.
//! And the implementation can interpret a feature if the feature is known to it.
//!
//! The following features are currently required in the LDK:
//! - `VariableLengthOnion` - requires/supports variable-length routing onion payloads
//!     (see [BOLT-4](https://github.com/lightning/bolts/blob/master/04-onion-routing.md) for more information).
//! - `StaticRemoteKey` - requires/supports static key for remote output
//!     (see [BOLT-3](https://github.com/lightning/bolts/blob/master/03-transactions.md) for more information).
//!
//! The following features are currently supported in the LDK:
//! - `DataLossProtect` - requires/supports that a node which has somehow fallen behind, e.g., has been restored from an old backup,
//!     can detect that it has fallen behind
//!     (see [BOLT-2](https://github.com/lightning/bolts/blob/master/02-peer-protocol.md) for more information).
//! - `InitialRoutingSync` - requires/supports that the sending node needs a complete routing information dump
//!     (see [BOLT-7](https://github.com/lightning/bolts/blob/master/07-routing-gossip.md#initial-sync) for more information).
//! - `UpfrontShutdownScript` - commits to a shutdown scriptpubkey when opening a channel
//!     (see [BOLT-2](https://github.com/lightning/bolts/blob/master/02-peer-protocol.md#the-open_channel-message) for more information).
//! - `GossipQueries` - requires/supports more sophisticated gossip control
//!     (see [BOLT-7](https://github.com/lightning/bolts/blob/master/07-routing-gossip.md) for more information).
//! - `PaymentSecret` - requires/supports that a node supports payment_secret field
//!     (see [BOLT-4](https://github.com/lightning/bolts/blob/master/04-onion-routing.md) for more information).
//! - `BasicMPP` - requires/supports that a node can receive basic multi-part payments
//!     (see [BOLT-4](https://github.com/lightning/bolts/blob/master/04-onion-routing.md#basic-multi-part-payments) for more information).
//! - `Wumbo` - requires/supports that a node create large channels. Called `option_support_large_channel` in the spec.
//!     (see [BOLT-2](https://github.com/lightning/bolts/blob/master/02-peer-protocol.md#the-open_channel-message) for more information).
//! - `AnchorsZeroFeeHtlcTx` - requires/supports that commitment transactions include anchor outputs
//!     and HTLC transactions are pre-signed with zero fee (see
//!     [BOLT-3](https://github.com/lightning/bolts/blob/master/03-transactions.md) for more
//!     information).
//! - `RouteBlinding` - requires/supports that a node can relay payments over blinded paths
//!     (see [BOLT-4](https://github.com/lightning/bolts/blob/master/04-onion-routing.md#route-blinding) for more information).
//! - `ShutdownAnySegwit` - requires/supports that future segwit versions are allowed in `shutdown`
//!     (see [BOLT-2](https://github.com/lightning/bolts/blob/master/02-peer-protocol.md) for more information).
//! - `OnionMessages` - requires/supports forwarding onion messages
//!     (see [BOLT-7](https://github.com/lightning/bolts/pull/759/files) for more information).
//     TODO: update link
//! - `ChannelType` - node supports the channel_type field in open/accept
//!     (see [BOLT-2](https://github.com/lightning/bolts/blob/master/02-peer-protocol.md) for more information).
//! - `SCIDPrivacy` - supply channel aliases for routing
//!     (see [BOLT-2](https://github.com/lightning/bolts/blob/master/02-peer-protocol.md) for more information).
//! - `PaymentMetadata` - include additional data in invoices which is passed to recipients in the
//!      onion.
//!      (see [BOLT-11](https://github.com/lightning/bolts/blob/master/11-payment-encoding.md) for
//!      more).
//! - `ZeroConf` - supports accepting HTLCs and using channels prior to funding confirmation
//!      (see
//!      [BOLT-2](https://github.com/lightning/bolts/blob/master/02-peer-protocol.md#the-channel_ready-message)
//!      for more info).
//! - `Keysend` - send funds to a node without an invoice
//!     (see the [`Keysend` feature assignment proposal](https://github.com/lightning/bolts/issues/605#issuecomment-606679798) for more information).
//! - `Trampoline` - supports receiving and forwarding Trampoline payments
//!     (see the [`Trampoline` feature proposal](https://github.com/lightning/bolts/pull/836) for more information).
//!
//! LDK knows about the following features, but does not support them:
//! - `AnchorsNonzeroFeeHtlcTx` - the initial version of anchor outputs, which was later found to be
//!     vulnerable (see this
//!     [mailing list post](https://lists.linuxfoundation.org/pipermail/lightning-dev/2020-September/002796.html)
//!     for more information).
//!
//! [BOLT #9]: https://github.com/lightning/bolts/blob/master/09-features.md
const std = @import("std");
const bech32 = @import("bitcoin-primitives").bech32;

pub const FeatureBit = u16;

const Features = @This();

/// DataLossProtectRequired is a feature bit that indicates that a peer
/// *requires* the other party know about the data-loss-protect optional
/// feature. If the remote peer does not know of such a feature, then
/// the sending peer SHOULD disconnect them. The data-loss-protect
/// feature allows a peer that's lost partial data to recover their
/// settled funds of the latest commitment state.
pub const data_loss_protect_required: FeatureBit = 0;

/// DataLossProtectOptional is an optional feature bit that indicates
/// that the sending peer knows of this new feature and can activate it
/// it. The data-loss-protect feature allows a peer that's lost partial
/// data to recover their settled funds of the latest commitment state.
pub const data_loss_protect_optional: FeatureBit = 1;

/// InitialRoutingSync is a local feature bit meaning that the receiving
/// node should send a complete dump of routing information when a new
/// connection is established.
pub const initial_routing_sync: FeatureBit = 3;

/// UpfrontShutdownScriptRequired is a feature bit which indicates that a
/// peer *requires* that the remote peer accept an upfront shutdown script to
/// which payout is enforced on cooperative closes.
pub const upfront_shutdown_script_required: FeatureBit = 4;

/// UpfrontShutdownScriptOptional is an optional feature bit which indicates
/// that the peer will accept an upfront shutdown script to which payout is
/// enforced on cooperative closes.
pub const upfront_shutdown_script_optional: FeatureBit = 5;

/// GossipQueriesRequired is a feature bit that indicates that the
/// receiving peer MUST know of the set of features that allows nodes to
/// more efficiently query the network view of peers on the network for
/// reconciliation purposes.
pub const gossip_queries_required: FeatureBit = 6;

/// GossipQueriesOptional is an optional feature bit that signals that
/// the setting peer knows of the set of features that allows more
/// efficient network view reconciliation.
pub const gossip_queries_optional: FeatureBit = 7;

/// TLVOnionPayloadRequired is a feature bit that indicates a node is
/// able to decode the new TLV information included in the onion packet.
pub const tlv_onion_payload_required: FeatureBit = 8;

/// TLVOnionPayloadOptional is an optional feature bit that indicates a
/// node is able to decode the new TLV information included in the onion
/// packet.
pub const tlv_onion_payload_optional: FeatureBit = 9;

/// StaticRemoteKeyRequired is a required feature bit that signals that
/// within one's commitment transaction, the key used for the remote
/// party's non-delay output should not be tweaked.
pub const static_remote_key_required: FeatureBit = 12;

/// StaticRemoteKeyOptional is an optional feature bit that signals that
/// within one's commitment transaction, the key used for the remote
/// party's non-delay output should not be tweaked.
pub const static_remote_key_optional: FeatureBit = 13;

/// PaymentAddrRequired is a required feature bit that signals that a
/// node requires payment addresses, which are used to mitigate probing
/// attacks on the receiver of a payment.
pub const payment_addr_required: FeatureBit = 14;

/// PaymentAddrOptional is an optional feature bit that signals that a
/// node supports payment addresses, which are used to mitigate probing
/// attacks on the receiver of a payment.
pub const payment_addr_optional: FeatureBit = 15;

/// MPPRequired is a required feature bit that signals that the receiver
/// of a payment requires settlement of an invoice with more than one
/// HTLC.
pub const mpp_required: FeatureBit = 16;

/// MPPOptional is an optional feature bit that signals that the receiver
/// of a payment supports settlement of an invoice with more than one
/// HTLC.
pub const mpp_optional: FeatureBit = 17;

/// WumboChannelsRequired is a required feature bit that signals that a
/// node is willing to accept channels larger than 2^24 satoshis.
pub const wumbo_channels_required: FeatureBit = 18;

/// WumboChannelsOptional is an optional feature bit that signals that a
/// node is willing to accept channels larger than 2^24 satoshis.
pub const wumbo_channels_optional: FeatureBit = 19;

/// AnchorsRequired is a required feature bit that signals that the node
/// requires channels to be made using commitments having anchor
/// outputs.
pub const anchors_required: FeatureBit = 20;

/// AnchorsOptional is an optional feature bit that signals that the
/// node supports channels to be made using commitments having anchor
/// outputs.
pub const anchors_optional: FeatureBit = 21;

/// AnchorsZeroFeeHtlcTxRequired is a required feature bit that signals
/// that the node requires channels having zero-fee second-level HTLC
/// transactions, which also imply anchor commitments.
pub const anchors_zero_fee_htlc_tx_required: FeatureBit = 22;

/// AnchorsZeroFeeHtlcTxOptional is an optional feature bit that signals
/// that the node supports channels having zero-fee second-level HTLC
/// transactions, which also imply anchor commitments.
pub const anchors_zero_fee_htlc_tx_optional: FeatureBit = 23;

/// RouteBlindingRequired is a required feature bit that signals that
/// the node supports blinded payments.
pub const route_blinding_required: FeatureBit = 24;

/// RouteBlindingOptional is an optional feature bit that signals that
/// the node supports blinded payments.
pub const route_blinding_optional: FeatureBit = 25;

/// ShutdownAnySegwitRequired is an required feature bit that signals
/// that the sender is able to properly handle/parse segwit witness
/// programs up to version 16. This enables utilization of Taproot
/// addresses for cooperative closure addresses.
pub const shutdown_any_segwit_required: FeatureBit = 26;

/// ShutdownAnySegwitOptional is an optional feature bit that signals
/// that the sender is able to properly handle/parse segwit witness
/// programs up to version 16. This enables utilization of Taproot
/// addresses for cooperative closure addresses.
pub const shutdown_any_segwit_optional: FeatureBit = 27;

/// AMPRequired is a required feature bit that signals that the receiver
/// of a payment supports accepts spontaneous payments, i.e.
/// sender-generated preimages according to BOLT XX.
pub const amp_required: FeatureBit = 30;

/// AMPOptional is an optional feature bit that signals that the receiver
/// of a payment supports accepts spontaneous payments, i.e.
/// sender-generated preimages according to BOLT XX.
pub const amp_optional: FeatureBit = 31;

/// ExplicitChannelTypeRequired is a required bit that denotes that a
/// connection established with this node is to use explicit channel
/// commitment types for negotiation instead of the existing implicit
/// negotiation methods. With this bit, there is no longer a "default"
/// implicit channel commitment type, allowing a connection to
/// open/maintain types of several channels over its lifetime.
pub const explicit_channel_type_required: FeatureBit = 44;

/// ExplicitChannelTypeOptional is an optional bit that denotes that a
/// connection established with this node is to use explicit channel
/// commitment types for negotiation instead of the existing implicit
/// negotiation methods. With this bit, there is no longer a "default"
/// implicit channel commitment type, allowing a connection to
/// TODO: Decide on actual feature bit value.
pub const explicit_channel_type_optional: FeatureBit = 45;

/// ScidAliasRequired is a required feature bit that signals that the
/// node requires understanding of ShortChannelID aliases in the TLV
/// segment of the channel_ready message.
pub const scid_alias_required: FeatureBit = 46;

/// ScidAliasOptional is an optional feature bit that signals that the
/// node understands ShortChannelID aliases in the TLV segment of the
/// channel_ready message.
pub const scid_alias_optional: FeatureBit = 47;

/// PaymentMetadataRequired is a required bit that denotes that if an
/// invoice contains metadata, it must be passed along with the payment
/// htlc(s).
pub const payment_metadata_required: FeatureBit = 48;

/// PaymentMetadataOptional is an optional bit that denotes that if an
/// invoice contains metadata, it may be passed along with the payment
/// htlc(s).
pub const payment_metadata_optional: FeatureBit = 49;

/// ZeroConfRequired is a required feature bit that signals that the
/// node requires understanding of the zero-conf channel_type.
pub const zero_conf_required: FeatureBit = 50;

/// ZeroConfOptional is an optional feature bit that signals that the
/// node understands the zero-conf channel type.
pub const zero_conf_optional: FeatureBit = 51;

/// KeysendRequired is a required bit that indicates that the node is
/// able and willing to accept keysend payments.
pub const keysend_required: FeatureBit = 54;

/// KeysendOptional is an optional bit that indicates that the node is
/// able and willing to accept keysend payments.
pub const keysend_optional: FeatureBit = 55;

/// ScriptEnforcedLeaseRequired is a required feature bit that signals
/// that the node requires channels having zero-fee second-level HTLC
/// transactions, which also imply anchor commitments, along with an
/// additional CLTV constraint of a channel lease's expiration height
/// applied to all outputs that pay directly to the channel initiator.
///
/// TODO: Decide on actual feature bit value.
pub const script_enforced_lease_required: FeatureBit = 2022;

/// ScriptEnforcedLeaseOptional is an optional feature bit that signals
/// that the node requires channels having zero-fee second-level HTLC
/// transactions, which also imply anchor commitments, along with an
/// additional CLTV constraint of a channel lease's expiration height
/// applied to all outputs that pay directly to the channel initiator.
///
/// TODO: Decide on actual feature bit value.
pub const script_enforced_lease_optional: FeatureBit = 2023;

/// SimpleTaprootChannelsRequiredFinal is a required bit that indicates
/// the node is able to create taproot-native channels. This is the
/// final feature bit to be used once the channel type is finalized.
pub const simple_taproot_channels_required_final: FeatureBit = 80;

/// SimpleTaprootChannelsOptionalFinal is an optional bit that indicates
/// the node is able to create taproot-native channels. This is the
/// final feature bit to be used once the channel type is finalized.
pub const simple_taproot_channels_optional_final: FeatureBit = 81;

/// SimpleTaprootChannelsRequiredStaging is a required bit that indicates
/// the node is able to create taproot-native channels. This is a
/// feature bit used in the wild while the channel type is still being
/// finalized.
pub const simple_taproot_channels_required_staging: FeatureBit = 180;

/// SimpleTaprootChannelsOptionalStaging is an optional bit that
/// indicates the node is able to create taproot-native channels. This
/// is a feature bit used in the wild while the channel type is still
/// being finalized.
pub const simple_taproot_channels_optional_staging: FeatureBit = 181;

/// Bolt11BlindedPathsRequired is a required feature bit that indicates
/// that the node is able to understand the blinded path tagged field in
/// a BOLT 11 invoice.
pub const bolt11_blinded_paths_required: FeatureBit = 262;

/// Bolt11BlindedPathsOptional is an optional feature bit that indicates
/// that the node is able to understand the blinded path tagged field in
/// a BOLT 11 invoice.
pub const bolt11_blinded_paths_optional: FeatureBit = 263;

/// MaxBolt11Feature is the maximum feature bit value allowed in bolt 11
/// invoices.
///
/// The base 32 encoded tagged fields in invoices are limited to 10 bits
/// to express the length of the field's data.
///nolint:lll
/// See: https://github.com/lightning/bolts/blob/master/11-payment-encoding.md#tagged-fields
///
/// With a maximum length field of 1023 (2^10 -1) and 5 bit encoding,
/// the highest feature bit that can be expressed is:
/// 1023 * 5 - 1 = 5114.
pub const max_bolt11_feature: FeatureBit = 5114;

/// returns true if the feature bit is even, and false otherwise.
pub inline fn isFeatureRequired(b: FeatureBit) bool {
    return b & 0x01 == 0x00;
}

/// Tracks the set of features which a node implements, templated by the context in which it
/// appears.
///
/// This is not exported to bindings users as we map the concrete feature types below directly instead
/// Note that, for convenience, flags is LITTLE endian (despite being big-endian on the wire)
flags: std.AutoHashMap(FeatureBit, void),

pub fn set(self: *Features, b: FeatureBit) !void {
    try self.flags.put(b, {});
}

pub fn deinit(self: *Features) void {
    self.flags.deinit();
}

pub fn fromBase32(gpa: std.mem.Allocator, data: []const u5) !Features {
    const field_data = try bech32.arrayListFromBase32(gpa, data);
    defer field_data.deinit();

    const width: usize = 5;

    var flags = std.AutoHashMap(FeatureBit, void).init(gpa);
    errdefer flags.deinit();

    // Set feature bits from parsed data.
    const bits_number = data.len * width;
    for (0..bits_number) |i| {
        const byte_index = i / width;
        const bit_index = i % width;

        if ((std.math.shl(u8, data[data.len - byte_index - 1], bit_index)) & 1 == 1) {
            try flags.put(@truncate(i), {});
        }
    }

    return .{
        .flags = flags,
    };
}
