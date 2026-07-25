//! Apple Silicon die temperatures via the SMC key endpoint.
//!
//! IOKit FFI adapted from macmon (MIT), which in turn derives from
//! freedomtan/sensors. Deliberately does not touch IOReport: subscribing to
//! IOReport channels costs ~2.4s per process, while the SMC path costs ~8ms.

use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::mem::size_of;
use std::os::raw::c_void;
use std::path::PathBuf;

type Res<T> = Result<T, Box<dyn std::error::Error>>;

// Die sensors: Tp/Te/Ts are CPU clusters, Tg is GPU. Everything else on the
// bus is a board, battery, or power-rail probe we do not want in a max().
const DIE_PREFIXES: [&str; 4] = ["Tp", "Te", "Ts", "Tg"];

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IOServiceMatching(name: *const i8) -> *const c_void;
    fn IOServiceGetMatchingServices(port: u32, m: *const c_void, it: *mut u32) -> i32;
    fn IOIteratorNext(it: u32) -> u32;
    fn IOObjectRelease(obj: u32) -> i32;
    fn IORegistryEntryGetName(entry: u32, name: *mut i8) -> i32;
    fn mach_task_self() -> u32;
    fn IOServiceOpen(device: u32, a: u32, b: u32, conn: *mut u32) -> i32;
    fn IOServiceClose(conn: u32) -> i32;
    fn IOConnectCallStructMethod(
        conn: u32,
        selector: u32,
        ival: *const c_void,
        isize: usize,
        oval: *mut c_void,
        osize: *mut usize,
    ) -> i32;
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
    info: HashMap<u32, KeyInfo>,
}

impl Smc {
    fn new() -> Res<Self> {
        let name = CString::new("AppleSMC").unwrap();
        let mut iter = 0u32;
        let mut conn = 0u32;

        unsafe {
            let matching = IOServiceMatching(name.as_ptr());
            if IOServiceGetMatchingServices(0, matching, &mut iter) != 0 {
                return Err("AppleSMC not found".into());
            }

            loop {
                let device = IOIteratorNext(iter);
                if device == 0 {
                    break;
                }
                let mut buf = [0i8; 128];
                if IORegistryEntryGetName(device, buf.as_mut_ptr()) == 0
                    && CStr::from_ptr(buf.as_ptr()).to_bytes() == b"AppleSMCKeysEndpoint"
                {
                    let rs = IOServiceOpen(device, mach_task_self(), 0, &mut conn);
                    if rs != 0 {
                        IOObjectRelease(iter);
                        return Err(format!("IOServiceOpen: {rs}").into());
                    }
                }
            }
            IOObjectRelease(iter);
        }

        if conn == 0 {
            return Err("AppleSMCKeysEndpoint not found".into());
        }
        Ok(Self {
            conn,
            info: HashMap::new(),
        })
    }

    fn call(&self, input: &KeyData) -> Res<KeyData> {
        let mut oval = KeyData::default();
        let mut olen = size_of::<KeyData>();

        let rs = unsafe {
            IOConnectCallStructMethod(
                self.conn,
                2,
                input as *const _ as _,
                size_of::<KeyData>(),
                &mut oval as *mut _ as _,
                &mut olen,
            )
        };

        if rs != 0 {
            return Err(format!("IOConnectCallStructMethod: {rs}").into());
        }
        if oval.result != 0 {
            return Err(format!("SMC result {}", oval.result).into());
        }
        Ok(oval)
    }

    fn parse_key(key: &str) -> Res<u32> {
        if key.len() != 4 {
            return Err("SMC keys are 4 bytes".into());
        }
        Ok(key.bytes().fold(0u32, |acc, b| (acc << 8) + b as u32))
    }

    fn key_info(&mut self, key: u32) -> Res<KeyInfo> {
        if let Some(hit) = self.info.get(&key) {
            return Ok(*hit);
        }
        let out = self.call(&KeyData {
            data8: 9,
            key,
            ..Default::default()
        })?;
        self.info.insert(key, out.key_info);
        Ok(out.key_info)
    }

    /// Read a `flt ` SMC key. Errors on absent or non-float keys, which is how
    /// a stale cached key list gets detected.
    fn read_float(&mut self, key: &str) -> Res<f32> {
        const FLT: u32 = u32::from_be_bytes(*b"flt ");

        let id = Self::parse_key(key)?;
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
        Ok(f32::from_le_bytes(out.bytes[0..4].try_into().unwrap()))
    }

    fn key_count(&mut self) -> Res<u32> {
        let id = Self::parse_key("#KEY")?;
        let info = self.key_info(id)?;
        let out = self.call(&KeyData {
            data8: 5,
            key: id,
            key_info: info,
            ..Default::default()
        })?;
        Ok(u32::from_be_bytes(out.bytes[0..4].try_into().unwrap()))
    }

    fn key_by_index(&self, index: u32) -> Res<String> {
        let out = self.call(&KeyData {
            data8: 8,
            data32: index,
            ..Default::default()
        })?;
        Ok(String::from_utf8_lossy(&out.key.to_be_bytes()).into_owned())
    }

    /// Walk the whole key space looking for readable die sensors. Costs ~310ms
    /// because every one of ~2300 keys is a separate IOKit round trip, so the
    /// result is cached and this runs once per machine.
    fn discover(&mut self) -> Res<Vec<String>> {
        let count = self.key_count()?;
        let mut found = Vec::new();

        for i in 0..count {
            let Ok(key) = self.key_by_index(i) else {
                continue;
            };
            if !DIE_PREFIXES.iter().any(|p| key.starts_with(p)) {
                continue;
            }
            match self.read_float(&key) {
                Ok(v) if plausible(v) => found.push(key),
                _ => continue,
            }
        }
        Ok(found)
    }
}

impl Drop for Smc {
    fn drop(&mut self) {
        unsafe { IOServiceClose(self.conn) };
    }
}

fn plausible(v: f32) -> bool {
    v > 0.0 && v < 130.0
}

fn cache_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))?;
    Some(base.join("system-temp").join("smc-die-keys"))
}

fn read_cache() -> Vec<String> {
    let Some(path) = cache_path() else {
        return Vec::new();
    };
    std::fs::read_to_string(path)
        .map(|s| {
            s.lines()
                .map(str::to_string)
                .filter(|l| l.len() == 4)
                .collect()
        })
        .unwrap_or_default()
}

fn write_cache(keys: &[String]) {
    let Some(path) = cache_path() else { return };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(path, keys.join("\n"));
}

/// Hottest die sensor on the package, in celsius.
pub fn hottest() -> Res<f32> {
    let mut smc = Smc::new()?;

    let cached = read_cache();
    if !cached.is_empty() {
        let peak = max_of(&mut smc, &cached);
        if let Some(peak) = peak {
            return Ok(peak);
        }
        // Cache did not resolve to a single readable sensor: different machine,
        // or the key set moved under a macOS update. Fall through and rebuild.
    }

    let keys = smc.discover()?;
    if keys.is_empty() {
        return Err("no readable die sensors".into());
    }
    write_cache(&keys);
    max_of(&mut smc, &keys).ok_or_else(|| "no readable die sensors".into())
}

fn max_of(smc: &mut Smc, keys: &[String]) -> Option<f32> {
    keys.iter()
        .filter_map(|k| smc.read_float(k).ok())
        .filter(|v| plausible(*v))
        .fold(None, |acc: Option<f32>, v| {
            Some(acc.map_or(v, |a| a.max(v)))
        })
}
