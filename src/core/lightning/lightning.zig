//! Mint Lightning


/// Create invoice response
pub const CreateInvoiceResponse = struct {
    /// Id that is used to look up the invoice from the ln backend
    request_lookup_id: []const u8,
    /// Bolt11 payment request
    request: Bolt11Invoice,
    /// Unix Expiry of Invoice
    expiry: Option<u64>,
};

/// Pay invoice response
#[derive(Debug, Clone, Hash, PartialEq, Eq, Serialize, Deserialize)]
pub struct PayInvoiceResponse {
    /// Payment hash
    pub payment_hash: String,
    /// Payment Preimage
    pub payment_preimage: Option<String>,
    /// Status
    pub status: MeltQuoteState,
    /// Totoal Amount Spent
    pub total_spent: Amount,
}

/// Payment quote response
#[derive(Debug, Clone, Hash, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaymentQuoteResponse {
    /// Request look up id
    pub request_lookup_id: String,
    /// Amount
    pub amount: Amount,
    /// Fee required for melt
    pub fee: u64,
}

/// Ln backend settings
#[derive(Debug, Clone, Copy, Hash, PartialEq, Eq, Serialize, Deserialize)]
pub struct Settings {
    /// MPP supported
    pub mpp: bool,
    /// Min amount to mint
    pub mint_settings: MintMeltSettings,
    /// Max amount to mint
    pub melt_settings: MintMeltSettings,
    /// Base unit of backend
    pub unit: CurrencyUnit,
}

/// Mint or melt settings
#[derive(Debug, Clone, Copy, Hash, PartialEq, Eq, Serialize, Deserialize)]
pub struct MintMeltSettings {
    /// Min Amount
    pub min_amount: Amount,
    /// Max Amount
    pub max_amount: Amount,
    /// Enabled
    pub enabled: bool,
}

impl Default for MintMeltSettings {
    fn default() -> Self {
        Self {
            min_amount: Amount::from(1),
            max_amount: Amount::from(500000),
            enabled: true,
        }
    }
}

const MSAT_IN_SAT: u64 = 1000;

/// Helper function to convert units
pub fn to_unit<T>(
    amount: T,
    current_unit: &CurrencyUnit,
    target_unit: &CurrencyUnit,
) -> Result<Amount, Error>
where
    T: Into<u64>,
{
    let amount = amount.into();
    match (current_unit, target_unit) {
        (CurrencyUnit::Sat, CurrencyUnit::Sat) => Ok(amount.into()),
        (CurrencyUnit::Msat, CurrencyUnit::Msat) => Ok(amount.into()),
        (CurrencyUnit::Sat, CurrencyUnit::Msat) => Ok((amount * MSAT_IN_SAT).into()),
        (CurrencyUnit::Msat, CurrencyUnit::Sat) => Ok((amount / MSAT_IN_SAT).into()),
        (CurrencyUnit::Usd, CurrencyUnit::Usd) => Ok(amount.into()),
        (CurrencyUnit::Eur, CurrencyUnit::Eur) => Ok(amount.into()),
        _ => Err(Error::CannotConvertUnits),
    }
}

