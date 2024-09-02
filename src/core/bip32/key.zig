const secp256k1 = @import("secp256k1");
const Network = @import("bip32.zig").Network;

/// A Bitcoin ECDSA private key
pub const PrivateKey = struct {
    /// Whether this private key should be serialized as compressed
    compressed: bool,
    /// The network on which this key should be used
    network: Network,
    /// The actual ECDSA key
    inner: secp256k1.SecretKey,
};
