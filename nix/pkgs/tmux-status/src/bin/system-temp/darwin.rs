//! Apple Silicon die temperatures via the SMC key endpoint.
//!
//! SMC access adapted from macmon (MIT), which in turn derives from
//! freedomtan/sensors. IOReport is not used: subscribing to its channels
//! costs about 2.4s per process.
//!
//! Finding the die sensors means walking every SMC key, about 2400 IOKit round
//! trips, so the keys found are cached and later runs read only those. On an
//! M5 that is about 15ms a run against 19ms with the walk. Any cached key that
//! is absent, as after a macOS update or with another machine's cache, sends
//! the run back to discovery.

use std::ffi::{c_char, c_void, CStr};
use std::mem::size_of;

use tmux_status::iokit::{
    self, IOConnectCallStructMethod, IORegistryEntryGetName, IOServiceClose, IOServiceOpen,
};
use tmux_status::{cache_file, Res};

unsafe extern "C" {
    fn mach_task_self() -> u32;
}

/// Tp and Te are the CPU clusters, Tg the GPU, and Ts the SoC, except for
/// Ts0P and Ts1P, which sit near ambient (25°C while the dies read 80-100).
/// Everything else on the bus is a board, battery or power-rail probe.
fn is_die(key: &str) -> bool {
    ["Tp", "Te", "Tg"].iter().any(|p| key.starts_with(p))
        || (key.starts_with("Ts") && !key.ends_with('P'))
}

#[repr(C)]
#[derive(Default)]
struct KeyDataVer {
    major: u8,
    minor: u8,
    build: u8,
    reserved: u8,
    release: u16,
}

#[repr(C)]
#[derive(Default)]
struct PLimitData {
    version: u16,
    length: u16,
    cpu_p_limit: u32,
    gpu_p_limit: u32,
    mem_p_limit: u32,
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct KeyInfo {
    data_size: u32,
    data_type: u32,
    data_attributes: u8,
}

/// The SMC user client's 80-byte argument and result struct.
#[repr(C)]
#[derive(Default)]
struct KeyData {
    key: u32,
    vers: KeyDataVer,
    p_limit_data: PLimitData,
    key_info: KeyInfo,
    result: u8,
    status: u8,
    data8: u8,
    data32: u32,
    bytes: [u8; 32],
}

struct Smc {
    conn: u32,
}

impl Smc {
    fn new() -> Res<Self> {
        for device in iokit::services("AppleSMC")? {
            let mut name = [0 as c_char; 128];
            if unsafe { IORegistryEntryGetName(device.0, name.as_mut_ptr()) } != 0
                || unsafe { CStr::from_ptr(name.as_ptr()) }.to_bytes() != b"AppleSMCKeysEndpoint"
            {
                continue;
            }
            let mut conn = 0u32;
            let rs = unsafe { IOServiceOpen(device.0, mach_task_self(), 0, &mut conn) };
            if rs != 0 {
                return Err(format!("IOServiceOpen(AppleSMCKeysEndpoint): {rs:#x}").into());
            }
            return Ok(Self { conn });
        }
        Err("AppleSMCKeysEndpoint not found".into())
    }

    fn call(&self, input: &KeyData) -> Res<KeyData> {
        let mut out = KeyData::default();
        let mut out_len = size_of::<KeyData>();
        let rs = unsafe {
            IOConnectCallStructMethod(
                self.conn,
                2,
                (input as *const KeyData).cast::<c_void>(),
                size_of::<KeyData>(),
                (&raw mut out).cast(),
                &mut out_len,
            )
        };
        if rs != 0 {
            return Err(format!("IOConnectCallStructMethod: {rs:#x}").into());
        }
        if out.result != 0 {
            return Err(format!("SMC result {}", out.result).into());
        }
        Ok(out)
    }

    fn key_info(&self, key: u32) -> Res<KeyInfo> {
        Ok(self
            .call(&KeyData {
                data8: 9,
                key,
                ..Default::default()
            })?
            .key_info)
    }

    /// Errors when the key is absent or not a 4-byte float, which is how a
    /// stale cache shows itself.
    fn read_float(&self, key: &str) -> Res<f32> {
        const FLT: u32 = u32::from_be_bytes(*b"flt ");
        let id = parse_key(key)?;
        let info = self.key_info(id)?;
        if info.data_size != 4 || info.data_type != FLT {
            return Err(format!("{key} is not a 4-byte float").into());
        }
        let out = self.call(&KeyData {
            data8: 5,
            key: id,
            key_info: info,
            ..Default::default()
        })?;
        Ok(f32::from_le_bytes([
            out.bytes[0],
            out.bytes[1],
            out.bytes[2],
            out.bytes[3],
        ]))
    }

    fn key_count(&self) -> Res<u32> {
        let id = parse_key("#KEY")?;
        let out = self.call(&KeyData {
            data8: 5,
            key: id,
            key_info: self.key_info(id)?,
            ..Default::default()
        })?;
        Ok(u32::from_be_bytes([
            out.bytes[0],
            out.bytes[1],
            out.bytes[2],
            out.bytes[3],
        ]))
    }

    fn key_by_index(&self, index: u32) -> Res<String> {
        let out = self.call(&KeyData {
            data8: 8,
            data32: index,
            ..Default::default()
        })?;
        Ok(String::from_utf8_lossy(&out.key.to_be_bytes()).into_owned())
    }

    /// Every die key that reads plausibly, and the hottest of those readings.
    fn discover(&self) -> Res<(Vec<String>, Option<f32>)> {
        let mut keys = Vec::new();
        let mut peak: Option<f32> = None;
        for i in 0..self.key_count()? {
            let Ok(key) = self.key_by_index(i) else {
                continue;
            };
            if !is_die(&key) {
                continue;
            }
            if let Ok(v) = self.read_float(&key) {
                if plausible(v) {
                    peak = Some(peak.map_or(v, |p| p.max(v)));
                    keys.push(key);
                }
            }
        }
        Ok((keys, peak))
    }

    /// The hottest plausible reading, or Err when any key is absent.
    fn max_of(&self, keys: &[String]) -> Res<Option<f32>> {
        let mut peak: Option<f32> = None;
        for key in keys {
            let v = self.read_float(key)?;
            if plausible(v) {
                peak = Some(peak.map_or(v, |p| p.max(v)));
            }
        }
        Ok(peak)
    }
}

impl Drop for Smc {
    fn drop(&mut self) {
        unsafe { IOServiceClose(self.conn) };
    }
}

fn parse_key(key: &str) -> Res<u32> {
    let bytes: [u8; 4] = key
        .as_bytes()
        .try_into()
        .map_err(|_| format!("SMC key {key:?} is not 4 bytes"))?;
    Ok(u32::from_be_bytes(bytes))
}

fn plausible(v: f32) -> bool {
    v > 0.0 && v < 130.0
}

/// Hottest die sensor, in celsius.
pub fn hottest() -> Res<f32> {
    let smc = Smc::new()?;
    let cache = cache_file("smc-die-keys");

    let cached: Vec<String> = cache
        .as_ref()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .map(|text| {
            text.lines()
                .filter(|k| k.len() == 4)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    if !cached.is_empty() {
        if let Ok(Some(peak)) = smc.max_of(&cached) {
            return Ok(peak);
        }
    }

    let (keys, peak) = smc.discover()?;
    if let Some(path) = cache {
        // Best effort: without it the next run discovers again.
        let _ = std::fs::write(path, keys.join("\n"));
    }
    peak.ok_or_else(|| "no readable die sensors".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_data_matches_the_smc_struct() {
        assert_eq!(size_of::<KeyData>(), 80);
    }

    #[test]
    fn keys_are_four_bytes_big_endian() {
        assert_eq!(parse_key("#KEY").unwrap(), 0x234B_4559);
        assert!(parse_key("Tp0").is_err());
        assert!(parse_key("Tp0é").is_err());
    }

    #[test]
    fn die_keys_exclude_the_ambient_soc_probes() {
        for key in ["Tp01", "Te04", "Tg0C", "Ts00", "Ts0R"] {
            assert!(is_die(key), "{key}");
        }
        for key in ["Ts0P", "Ts1P", "TB0T", "TW0P"] {
            assert!(!is_die(key), "{key}");
        }
    }
}
