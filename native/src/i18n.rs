//! UI strings with Russian fallback. Port of i18n._().

#[path = "i18n_data.rs"]
mod i18n_data;

use std::collections::HashMap;
use std::sync::OnceLock;

fn ru() -> &'static HashMap<&'static str, &'static str> {
    static MAP: OnceLock<HashMap<&'static str, &'static str>> = OnceLock::new();
    MAP.get_or_init(i18n_data::ru)
}

/// Translate for the given language ("ru" or anything else = English).
pub fn tr(lang: &str, text: &str) -> String {
    if lang == "ru" {
        if let Some(hit) = ru().get(text) {
            return hit.to_string();
        }
    }
    text.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn russian_known_key() {
        assert_eq!(tr("ru", "Play"), ru()["Play"].to_string());
    }

    #[test]
    fn fallback_is_english() {
        assert_eq!(tr("ru", "no such string xyz"), "no such string xyz");
        assert_eq!(tr("en", "Play"), "Play");
    }
}
