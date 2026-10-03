/// Errors from key import, export and generation.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum KeyError {
    /// The key is encrypted and no passphrase was supplied.
    #[error("key is encrypted and needs a passphrase")]
    NeedsPassphrase,
    /// A passphrase was supplied but it did not decrypt the key.
    #[error("wrong passphrase")]
    WrongPassphrase,
    /// A valid-looking key using a feature we do not support (algorithm, cipher, format).
    #[error("unsupported: {0}")]
    Unsupported(String),
    /// The input is not a parseable key.
    #[error("malformed key")]
    Malformed,
}
