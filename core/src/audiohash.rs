//! `audio_hash`: SHA-256 über die reinen Audiodaten einer Datei – ohne Tags.
//!
//! Damit bleibt der Hash bei Tag-Änderungen (Titel, Cover, Lyrics …) gleich,
//! und eine Umbenennung lässt sich am identischen Hash erkennen.
//!
//! Unterstützte Formate und was gehasht wird:
//! - MP3:  alles außer ID3v2 (Anfang), APEv2 und ID3v1 (Ende)
//! - FLAC: die Audio-Frames nach den Metadaten-Blöcken
//! - Ogg (Vorbis, Opus, FLAC): alle Pakete nach den Header-Paketen
//! - MP4/M4A: der Inhalt aller `mdat`-Atome
//! - WAV:  der Inhalt des `data`-Chunks
//! - sonst: die ganze Datei (z. B. `.lrc`, `.m3u`)

use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// Wie der Hash zustande kam – nützlich für Diagnose und Tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HashKind {
    Mp3,
    Flac,
    Ogg,
    Mp4,
    Wav,
    WholeFile,
}

pub fn audio_hash(path: &Path) -> Result<(String, HashKind)> {
    let mut f = File::open(path).with_context(|| format!("öffnen: {}", path.display()))?;
    let len = f.metadata()?.len();
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let mut h = Sha256::new();
    let kind = match ext.as_str() {
        "mp3" => {
            let (start, end) = mp3_audio_range(&mut f, len)?;
            hash_range(&mut f, start, end, &mut h)?;
            HashKind::Mp3
        }
        "flac" => {
            let start = flac_audio_start(&mut f)?;
            hash_range(&mut f, start, len, &mut h)?;
            HashKind::Flac
        }
        "ogg" | "oga" | "opus" => {
            hash_ogg(&mut f, &mut h)?;
            HashKind::Ogg
        }
        "m4a" | "mp4" | "m4b" | "aac" if is_mp4(&mut f)? => {
            hash_mp4(&mut f, len, &mut h)?;
            HashKind::Mp4
        }
        "wav" => {
            hash_wav(&mut f, len, &mut h)?;
            HashKind::Wav
        }
        _ => {
            hash_range(&mut f, 0, len, &mut h)?;
            HashKind::WholeFile
        }
    };
    Ok((hex::encode(h.finalize()), kind))
}

fn hash_range(f: &mut File, start: u64, end: u64, h: &mut Sha256) -> Result<()> {
    if end < start {
        bail!("ungültiger Bereich {start}..{end}");
    }
    f.seek(SeekFrom::Start(start))?;
    let mut take = f.take(end - start);
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = take.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(())
}

fn read_at(f: &mut File, pos: u64, buf: &mut [u8]) -> Result<bool> {
    f.seek(SeekFrom::Start(pos))?;
    match f.read_exact(buf) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => Ok(false),
        Err(e) => Err(e.into()),
    }
}

/// Länge eines ID3v2-Tags an Position `pos` (inkl. Header/Footer), 0 wenn keiner.
fn id3v2_len(f: &mut File, pos: u64) -> Result<u64> {
    let mut hdr = [0u8; 10];
    if !read_at(f, pos, &mut hdr)? || &hdr[0..3] != b"ID3" {
        return Ok(0);
    }
    let size = syncsafe(&hdr[6..10]);
    let footer = if hdr[5] & 0x10 != 0 { 10 } else { 0 };
    Ok(10 + size + footer)
}

fn syncsafe(b: &[u8]) -> u64 {
    b.iter().fold(0u64, |acc, &x| (acc << 7) | u64::from(x & 0x7f))
}

fn mp3_audio_range(f: &mut File, len: u64) -> Result<(u64, u64)> {
    // Anfang: ein oder mehrere ID3v2-Tags hintereinander.
    let mut start = 0;
    loop {
        let l = id3v2_len(f, start)?;
        if l == 0 {
            break;
        }
        start += l;
    }
    // Ende: ID3v1 ("TAG", 128 Bytes), davor ggf. APEv2.
    let mut end = len;
    let mut tag = [0u8; 3];
    if end >= start + 128 && read_at(f, end - 128, &mut tag)? && &tag == b"TAG" {
        end -= 128;
    }
    let mut footer = [0u8; 32];
    if end >= start + 32 && read_at(f, end - 32, &mut footer)? && &footer[0..8] == b"APETAGEX" {
        let size = u64::from(u32::from_le_bytes(footer[12..16].try_into().unwrap()));
        let flags = u32::from_le_bytes(footer[20..24].try_into().unwrap());
        let header = if flags & (1 << 31) != 0 { 32 } else { 0 };
        end = end.saturating_sub(size + header).max(start);
    }
    Ok((start.min(len), end))
}

fn flac_audio_start(f: &mut File) -> Result<u64> {
    let mut pos = id3v2_len(f, 0)?; // manche Programme stellen ID3v2 voran
    let mut magic = [0u8; 4];
    if !read_at(f, pos, &mut magic)? || &magic != b"fLaC" {
        bail!("keine FLAC-Datei");
    }
    pos += 4;
    loop {
        let mut hdr = [0u8; 4];
        if !read_at(f, pos, &mut hdr)? {
            bail!("FLAC-Metadaten abgeschnitten");
        }
        let last = hdr[0] & 0x80 != 0;
        let size = u64::from(u32::from_be_bytes([0, hdr[1], hdr[2], hdr[3]]));
        pos += 4 + size;
        if last {
            return Ok(pos);
        }
    }
}

/// Liest Ogg-Seiten, setzt Pakete zusammen und hasht alle Pakete nach den
/// Header-Paketen (Vorbis: 3, Opus: 2, Ogg-FLAC: 1 + Anzahl Metadaten-Pakete).
fn hash_ogg(f: &mut File, h: &mut Sha256) -> Result<()> {
    f.seek(SeekFrom::Start(0))?;
    let mut data = Vec::new();
    f.read_to_end(&mut data)?;
    let mut pos = 0usize;
    let mut packet: Vec<u8> = Vec::new();
    let mut packets_done = 0u64;
    let mut headers: Option<u64> = None;
    let mut serial: Option<u32> = None;
    while pos + 27 <= data.len() {
        if &data[pos..pos + 4] != b"OggS" {
            bail!("Ogg-Seite erwartet bei Byte {pos}");
        }
        let page_serial = u32::from_le_bytes(data[pos + 14..pos + 18].try_into().unwrap());
        let nseg = data[pos + 26] as usize;
        let lacing = data
            .get(pos + 27..pos + 27 + nseg)
            .context("Ogg-Seite abgeschnitten")?;
        let mut body = pos + 27 + nseg;
        // Nur den ersten logischen Stream betrachten.
        let first = *serial.get_or_insert(page_serial);
        let this_stream = page_serial == first;
        for &l in lacing {
            let seg = data.get(body..body + l as usize).context("Ogg-Segment abgeschnitten")?;
            body += l as usize;
            if !this_stream {
                continue;
            }
            match headers {
                Some(n) if packets_done >= n => h.update(seg),
                _ => packet.extend_from_slice(seg),
            }
            if l < 255 {
                // Paket fertig
                if headers.is_none() {
                    headers = Some(ogg_header_count(&packet)?);
                }
                if headers.is_none_or(|n| packets_done < n) {
                    packet.clear();
                }
                packets_done += 1;
            }
        }
        pos = body;
    }
    Ok(())
}

fn ogg_header_count(first_packet: &[u8]) -> Result<u64> {
    if first_packet.starts_with(b"OpusHead") {
        Ok(2)
    } else if first_packet.starts_with(b"\x01vorbis") {
        Ok(3)
    } else if first_packet.starts_with(b"\x7fFLAC") && first_packet.len() >= 9 {
        // Byte 7–8: Anzahl der folgenden Header-Pakete (0 = unbekannt)
        let n = u64::from(u16::from_be_bytes([first_packet[7], first_packet[8]]));
        Ok(1 + n)
    } else {
        bail!("unbekannter Ogg-Codec")
    }
}

fn is_mp4(f: &mut File) -> Result<bool> {
    let mut b = [0u8; 8];
    Ok(read_at(f, 0, &mut b)? && &b[4..8] == b"ftyp")
}

fn hash_mp4(f: &mut File, len: u64, h: &mut Sha256) -> Result<()> {
    let mut pos = 0;
    let mut found = false;
    while pos + 8 <= len {
        let mut hdr = [0u8; 16];
        read_at(f, pos, &mut hdr[..8])?;
        let mut size = u64::from(u32::from_be_bytes(hdr[0..4].try_into().unwrap()));
        let typ = [hdr[4], hdr[5], hdr[6], hdr[7]];
        let mut header = 8;
        if size == 1 {
            read_at(f, pos + 8, &mut hdr[8..16])?;
            size = u64::from_be_bytes(hdr[8..16].try_into().unwrap());
            header = 16;
        } else if size == 0 {
            size = len - pos;
        }
        if size < header {
            bail!("ungültiges MP4-Atom bei Byte {pos}");
        }
        if &typ == b"mdat" {
            hash_range(f, pos + header, (pos + size).min(len), h)?;
            found = true;
        }
        pos += size;
    }
    if !found {
        bail!("kein mdat-Atom gefunden");
    }
    Ok(())
}

fn hash_wav(f: &mut File, len: u64, h: &mut Sha256) -> Result<()> {
    let mut riff = [0u8; 12];
    if !read_at(f, 0, &mut riff)? || &riff[0..4] != b"RIFF" || &riff[8..12] != b"WAVE" {
        bail!("keine WAV-Datei");
    }
    let mut pos = 12;
    while pos + 8 <= len {
        let mut hdr = [0u8; 8];
        read_at(f, pos, &mut hdr)?;
        let size = u64::from(u32::from_le_bytes(hdr[4..8].try_into().unwrap()));
        if &hdr[0..4] == b"data" {
            return hash_range(f, pos + 8, (pos + 8 + size).min(len), h);
        }
        pos += 8 + size + (size & 1);
    }
    bail!("kein data-Chunk gefunden")
}
