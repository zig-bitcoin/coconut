pub const Bolt11ParseError = error{
    // Bech32Error(bech32::Error),
    ParseAmountError,
    MalformedSignature,
    BadPrefix,
    UnknownCurrency,
    UnknownSiPrefix,
    MalformedHRP,
    TooShortDataPart,
    UnexpectedEndOfTaggedFields,
    DescriptionDecodeError,
    PaddingError,
    IntegerOverflowError,
    InvalidSegWitProgramLength,
    InvalidPubKeyHashLength,
    InvalidScriptHashLength,
    InvalidRecoveryId,
    InvalidSliceLength,

    /// Not an error, but used internally to signal that a part of the invoice should be ignored
    /// according to BOLT11
    Skip,
};
