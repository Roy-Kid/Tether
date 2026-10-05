//! File archive handles configured before any shell output is consumed.
use crate::TetherError;
use std::sync::Arc;

#[derive(Debug, uniffi::Object)]
pub struct SessionHistory {
    pub(crate) inner: tether_core::history::HistoryArchive,
}

#[uniffi::export]
impl SessionHistory {
    #[uniffi::constructor]
    pub fn open(
        directory: String,
        line_limit: Option<u64>,
        restoring: bool,
    ) -> Result<Arc<Self>, TetherError> {
        let result = if restoring {
            tether_core::history::HistoryArchive::reopen(directory, line_limit)
        } else {
            tether_core::history::HistoryArchive::create(directory, line_limit)
        };
        result
            .map(|inner| Arc::new(Self { inner }))
            .map_err(|error| TetherError::Protocol { cause: error.to_string() })
    }

    pub fn error(&self) -> Option<String> {
        self.inner.error()
    }
}
