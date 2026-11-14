//! Normalisierte Tags und `tag_hash`.
//!
//! Die Tags werden formatunabhängig auf feste Feldnamen abgebildet
//! (ID3 `TIT2`, Vorbis `TITLE`, MP4 `©nam` → `title`), Unicode-normalisiert
//! und sortiert. Der `tag_hash` ist SHA-256 über diese Darstellung plus die
//! Hashes der eingebetteten Bilder.

use anyhow::{Context, Result};
use lofty::prelude::*;
use lofty::tag::{ItemKey, Tag};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::Path;

/// Feldname → Werte (mehrere Werte z. B. bei mehreren Künstlern).
pub type TagMap = BTreeMap<String, Vec<String>>;

/// Ein geändertes Feld: (Feldname, alter Wert, neuer Wert).
pub type FieldDiff = (String, Option<Vec<String>>, Option<Vec<String>>);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Tags {
    pub fields: TagMap,
    /// SHA-256 je eingebettetem Bild, in Dateireihenfolge.
    pub pictures: Vec<String>,
}

pub const FIELDS: &[(&str, ItemKey)] = &[
    ("title", ItemKey::TrackTitle),
    ("artist", ItemKey::TrackArtist),
    ("album", ItemKey::AlbumTitle),
    ("albumartist", ItemKey::AlbumArtist),
    ("composer", ItemKey::Composer),
    ("genre", ItemKey::Genre),
    ("date", ItemKey::RecordingDate),
    ("year", ItemKey::Year),
    ("track", ItemKey::TrackNumber),
    ("tracktotal", ItemKey::TrackTotal),
    ("disc", ItemKey::DiscNumber),
    ("disctotal", ItemKey::DiscTotal),
    ("comment", ItemKey::Comment),
    ("lyrics", ItemKey::Lyrics),
];

fn normalize(s: &str) -> String {
    // Steuerzeichen (z. B. abschließende NULs aus ID3) entfernen, trimmen.
    s.chars()
        .filter(|c| !c.is_control() || *c == '\n')
        .collect::<String>()
        .replace("\r\n", "\n")
        .trim()
        .to_string()
}

pub fn from_tag(tag: &Tag) -> Tags {
    let mut fields = TagMap::new();
    for (name, key) in FIELDS {
        let mut vals: Vec<String> = tag
            .get_strings(*key)
            .map(normalize)
            .filter(|v| !v.is_empty())
            .collect();
        if vals.is_empty() {
            continue;
        }
        vals.sort();
        vals.dedup();
        fields.insert((*name).to_string(), vals);
    }
    let pictures = tag
        .pictures()
        .iter()
        .map(|p| hex::encode(Sha256::digest(p.data())))
        .collect();
    Tags { fields, pictures }
}

/// Liest die Tags einer Datei. Dateien ohne Tags oder in Formaten ohne
/// Tag-Unterstützung (z. B. `.lrc`) liefern leere Tags.
pub fn read_tags(path: &Path) -> Result<Tags> {
    let tagged = match lofty::read_from_path(path) {
        Ok(t) => t,
        Err(e) if is_unsupported(&e) => return Ok(Tags::default()),
        Err(e) => return Err(e).with_context(|| format!("Tags lesen: {}", path.display())),
    };
    Ok(tagged
        .primary_tag()
        .or_else(|| tagged.first_tag())
        .map(from_tag)
        .unwrap_or_default())
}

fn is_unsupported(e: &lofty::error::FileParseError) -> bool {
    e.is_unknown_format()
}

impl Tags {
    pub fn hash(&self) -> String {
        let json = serde_json::to_string(self).expect("Tags sind serialisierbar");
        hex::encode(Sha256::digest(json.as_bytes()))
    }

    /// Feldweiser Unterschied: (Feld, alt, neu) für die Inbox-Anzeige.
    pub fn diff(&self, other: &Tags) -> Vec<FieldDiff> {
        let mut keys: Vec<&String> = self.fields.keys().chain(other.fields.keys()).collect();
        keys.sort();
        keys.dedup();
        let mut out: Vec<_> = keys
            .into_iter()
            .filter_map(|k| {
                let a = self.fields.get(k);
                let b = other.fields.get(k);
                (a != b).then(|| (k.clone(), a.cloned(), b.cloned()))
            })
            .collect();
        if self.pictures != other.pictures {
            out.push(("cover".into(), None, None));
        }
        out
    }
}
