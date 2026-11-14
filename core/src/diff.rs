//! Diff-Engine: Erkennt Änderungen gegenüber dem letzten gemeinsamen Stand
//! („Basis“) und erzeugt daraus Vorschläge für das andere Gerät.
//!
//! Siehe `docs/sync-konzept.md`, Abschnitte 4 und 5.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// Eine Datei, wie sie im Manifest oder in der Basis steht.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub path: String,
    pub audio_hash: String,
    pub tag_hash: String,
}

/// Eine Änderung auf *einem* Gerät gegenüber der Basis.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Change {
    Add { new: Entry },
    Delete { old: Entry },
    /// Umbenannt/verschoben; `tags_changed` wenn zusätzlich Tags geändert wurden.
    Rename { old: Entry, new: Entry, tags_changed: bool },
    Tags { old: Entry, new: Entry },
    /// Gleicher Pfad, andere Audiodaten (z. B. bessere Qualität).
    Replace { old: Entry, new: Entry },
}

impl Change {
    /// Pfad in der Basis, auf den sich die Änderung bezieht (None bei Add).
    pub fn base_path(&self) -> Option<&str> {
        match self {
            Change::Add { .. } => None,
            Change::Delete { old }
            | Change::Rename { old, .. }
            | Change::Tags { old, .. }
            | Change::Replace { old, .. } => Some(&old.path),
        }
    }

    /// Zielpfad nach der Änderung (None bei Delete).
    pub fn target_path(&self) -> Option<&str> {
        match self {
            Change::Delete { .. } => None,
            Change::Add { new }
            | Change::Rename { new, .. }
            | Change::Tags { new, .. }
            | Change::Replace { new, .. } => Some(&new.path),
        }
    }
}

/// Vergleicht den aktuellen Stand eines Geräts mit der Basis.
///
/// Zuordnung: gleicher Pfad → dieselbe Datei; danach werden übrig gebliebene
/// Einträge über den `audio_hash` gepaart (→ Umbenennung).
pub fn changes(base: &[Entry], current: &[Entry]) -> Vec<Change> {
    let cur_by_path: HashMap<&str, &Entry> = current.iter().map(|e| (e.path.as_str(), e)).collect();
    let mut matched_cur: HashSet<&str> = HashSet::new();
    let mut unmatched_base: Vec<&Entry> = Vec::new();
    let mut out = Vec::new();

    for b in base {
        match cur_by_path.get(b.path.as_str()) {
            Some(c) => {
                matched_cur.insert(c.path.as_str());
                if c.audio_hash != b.audio_hash {
                    out.push(Change::Replace { old: b.clone(), new: (*c).clone() });
                } else if c.tag_hash != b.tag_hash {
                    out.push(Change::Tags { old: b.clone(), new: (*c).clone() });
                }
            }
            None => unmatched_base.push(b),
        }
    }

    // Übrige aktuelle Einträge nach audio_hash gruppieren.
    let mut cur_by_hash: HashMap<&str, Vec<&Entry>> = HashMap::new();
    for c in current.iter().filter(|c| !matched_cur.contains(c.path.as_str())) {
        cur_by_hash.entry(c.audio_hash.as_str()).or_default().push(c);
    }
    for v in cur_by_hash.values_mut() {
        v.sort_by(|a, b| b.path.cmp(&a.path)); // pop() liefert den kleinsten Pfad
    }

    for b in unmatched_base {
        match cur_by_hash.get_mut(b.audio_hash.as_str()).and_then(|v| v.pop()) {
            Some(c) => out.push(Change::Rename {
                old: b.clone(),
                new: c.clone(),
                tags_changed: c.tag_hash != b.tag_hash,
            }),
            None => out.push(Change::Delete { old: b.clone() }),
        }
    }
    let mut adds: Vec<&Entry> = cur_by_hash.into_values().flatten().collect();
    adds.sort_by(|a, b| a.path.cmp(&b.path));
    out.extend(adds.into_iter().map(|n| Change::Add { new: n.clone() }));
    out
}

/// Ein Eintrag in der Inbox des Empfängers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Proposal {
    /// Änderung der Gegenseite, die lokal angewendet werden kann.
    Apply { change: Change },
    /// Beide Seiten haben dieselbe Datei bzw. denselben Zielpfad verändert.
    Conflict { local: Option<Change>, remote: Change },
}

/// Erzeugt die Inbox für das lokale Gerät aus den Änderungen beider Seiten.
///
/// - Änderungen der Gegenseite, die lokal nichts berühren → `Apply`.
/// - Hat das lokale Gerät dieselbe Basis-Datei verändert → `Conflict`,
///   außer beide Seiten haben exakt dasselbe getan (dann nichts zu tun).
/// - Wollen beide Seiten unterschiedliche Dateien an denselben Pfad legen
///   → `Conflict`.
pub fn proposals(local: &[Change], remote: &[Change]) -> Vec<Proposal> {
    let local_by_base: HashMap<&str, &Change> =
        local.iter().filter_map(|c| c.base_path().map(|p| (p, c))).collect();
    let local_targets: HashMap<&str, &Change> =
        local.iter().filter_map(|c| c.target_path().map(|p| (p, c))).collect();

    let mut out = Vec::new();
    for r in remote {
        let same_base = r.base_path().and_then(|p| local_by_base.get(p)).copied();
        let same_target = r.target_path().and_then(|p| local_targets.get(p)).copied();
        match same_base.or(same_target) {
            None => out.push(Proposal::Apply { change: r.clone() }),
            Some(l) if same_effect(l, r) => {}
            Some(l) => out.push(Proposal::Conflict { local: Some(l.clone()), remote: r.clone() }),
        }
    }
    out
}

fn same_effect(a: &Change, b: &Change) -> bool {
    let end = |c: &Change| match c {
        Change::Delete { .. } => None,
        Change::Add { new }
        | Change::Rename { new, .. }
        | Change::Tags { new, .. }
        | Change::Replace { new, .. } => Some(new.clone()),
    };
    a.base_path() == b.base_path() && end(a) == end(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e(path: &str, a: &str, t: &str) -> Entry {
        Entry { path: path.into(), audio_hash: a.into(), tag_hash: t.into() }
    }

    #[test]
    fn klassifiziert_alle_aenderungsarten() {
        let base = vec![
            e("a.mp3", "A", "1"),
            e("b.mp3", "B", "1"),
            e("c.mp3", "C", "1"),
            e("d.mp3", "D", "1"),
            e("e.mp3", "E", "1"),
            e("f.mp3", "F", "1"),
        ];
        let cur = vec![
            e("a.mp3", "A", "1"),         // unverändert
            e("neu/b.mp3", "B", "1"),     // umbenannt
            e("c.mp3", "C", "2"),         // Tags
            // d gelöscht
            e("e.mp3", "E2", "1"),        // Inhalt ersetzt
            e("f2.mp3", "F", "9"),        // umbenannt + Tags
            e("g.mp3", "G", "1"),         // neu
        ];
        let ch = changes(&base, &cur);
        assert_eq!(ch.len(), 6, "{ch:#?}");
        assert!(ch.contains(&Change::Rename {
            old: e("b.mp3", "B", "1"),
            new: e("neu/b.mp3", "B", "1"),
            tags_changed: false
        }));
        assert!(ch.contains(&Change::Tags { old: e("c.mp3", "C", "1"), new: e("c.mp3", "C", "2") }));
        assert!(ch.contains(&Change::Delete { old: e("d.mp3", "D", "1") }));
        assert!(ch.contains(&Change::Replace { old: e("e.mp3", "E", "1"), new: e("e.mp3", "E2", "1") }));
        assert!(ch.contains(&Change::Rename {
            old: e("f.mp3", "F", "1"),
            new: e("f2.mp3", "F", "9"),
            tags_changed: true
        }));
        assert!(ch.contains(&Change::Add { new: e("g.mp3", "G", "1") }));
    }

    #[test]
    fn duplikate_werden_nicht_doppelt_gepaart() {
        let base = vec![e("x.mp3", "X", "1")];
        let cur = vec![e("y.mp3", "X", "1"), e("z.mp3", "X", "1")];
        let ch = changes(&base, &cur);
        assert_eq!(ch.len(), 2);
        assert!(matches!(&ch[0], Change::Rename { new, .. } if new.path == "y.mp3"));
        assert!(matches!(&ch[1], Change::Add { new } if new.path == "z.mp3"));
    }

    #[test]
    fn konflikte_und_gleiche_aenderungen() {
        let base = vec![e("a.mp3", "A", "1"), e("b.mp3", "B", "1"), e("c.mp3", "C", "1")];
        // lokal: a umbenannt, c Tags geändert
        let local = changes(&base, &[e("a2.mp3", "A", "1"), e("b.mp3", "B", "1"), e("c.mp3", "C", "5")]);
        // remote: a Tags geändert (Konflikt), b gelöscht (anwendbar), c gleiche Tags (nichts zu tun), neu.mp3
        let remote = changes(&base, &[e("a.mp3", "A", "2"), e("c.mp3", "C", "5"), e("neu.mp3", "N", "1")]);
        let p = proposals(&local, &remote);
        assert_eq!(p.len(), 3, "{p:#?}");
        assert!(matches!(&p[0], Proposal::Conflict { remote: Change::Tags { .. }, .. }));
        assert!(matches!(&p[1], Proposal::Apply { change: Change::Delete { .. } }));
        assert!(matches!(&p[2], Proposal::Apply { change: Change::Add { .. } }));
    }

    #[test]
    fn gleicher_zielpfad_ist_konflikt() {
        let local = changes(&[], &[e("x.mp3", "L", "1")]);
        let remote = changes(&[], &[e("x.mp3", "R", "1")]);
        assert!(matches!(&proposals(&local, &remote)[0], Proposal::Conflict { .. }));
    }
}
