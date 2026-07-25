//! GPU utilization on darwin, from the accelerator's registry properties.
//!
//! Deliberately not IOReport, which is where macmon reads GPU residency and
//! which costs about 2.4s per process to subscribe to. The accelerator carries
//! the same busy percentage in its `PerformanceStatistics` dictionary, and
//! that is an ordinary registry property read.
//!
//! `Device Utilization %` is undocumented, the same standing as the SMC keys in
//! system-temp, so anything unexpected is treated as "nothing to report"
//! rather than an error worth putting on screen.
//!
//! Constants verified against MacOSX14.4.sdk: `kCFStringEncodingUTF8` in
//! CFString.h and `kCFNumberSInt64Type` in CFNumber.h.

use std::ffi::CString;
use std::os::raw::{c_char, c_int, c_void};

type Res<T> = Result<T, Box<dyn std::error::Error>>;

const KCF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
const KCF_NUMBER_SINT64_TYPE: c_int = 4;

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IOServiceMatching(name: *const c_char) -> *const c_void;
    fn IOServiceGetMatchingServices(port: u32, matching: *const c_void, it: *mut u32) -> i32;
    fn IOIteratorNext(it: u32) -> u32;
    fn IOObjectRelease(obj: u32) -> i32;
    fn IORegistryEntryCreateCFProperty(
        entry: u32,
        key: *const c_void,
        allocator: *const c_void,
        options: u32,
    ) -> *const c_void;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringCreateWithCString(
        alloc: *const c_void,
        cstr: *const c_char,
        encoding: u32,
    ) -> *const c_void;
    fn CFDictionaryGetValue(dict: *const c_void, key: *const c_void) -> *const c_void;
    fn CFNumberGetValue(number: *const c_void, kind: c_int, out: *mut c_void) -> bool;
    fn CFGetTypeID(cf: *const c_void) -> usize;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFNumberGetTypeID() -> usize;
    fn CFRelease(cf: *const c_void);
}

/// Anything obtained from a CoreFoundation Create or Copy call, which the
/// caller owns and must release.
struct Owned(*const c_void);

impl Drop for Owned {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) };
    }
}

fn cf_string(s: &str) -> Res<Owned> {
    let c = CString::new(s)?;
    let raw = unsafe {
        CFStringCreateWithCString(std::ptr::null(), c.as_ptr(), KCF_STRING_ENCODING_UTF8)
    };
    if raw.is_null() {
        return Err(format!("CFStringCreateWithCString failed for {s}").into());
    }
    Ok(Owned(raw))
}

/// Pull one integer out of one accelerator's statistics dictionary.
///
/// Every lookup is type checked first. These are undocumented keys, so a type
/// that is not what we expect is a real possibility, and handing the wrong
/// type to CFDictionaryGetValue or CFNumberGetValue is undefined behaviour
/// rather than a miss.
fn utilization(entry: u32, stats_key: &Owned, util_key: &Owned) -> Option<i64> {
    let raw = unsafe { IORegistryEntryCreateCFProperty(entry, stats_key.0, std::ptr::null(), 0) };
    if raw.is_null() {
        return None;
    }
    let stats = Owned(raw);
    if unsafe { CFGetTypeID(stats.0) } != unsafe { CFDictionaryGetTypeID() } {
        return None;
    }

    // Borrowed under the CoreFoundation Get rule, so it is not released here.
    let value = unsafe { CFDictionaryGetValue(stats.0, util_key.0) };
    if value.is_null() || unsafe { CFGetTypeID(value) } != unsafe { CFNumberGetTypeID() } {
        return None;
    }

    let mut out: i64 = 0;
    let ok = unsafe { CFNumberGetValue(value, KCF_NUMBER_SINT64_TYPE, &mut out as *mut _ as _) };
    ok.then_some(out)
}

/// Busiest accelerator, as a percentage.
pub fn busy_percent() -> Res<u8> {
    let class = CString::new("IOAccelerator")?;
    let stats_key = cf_string("PerformanceStatistics")?;
    let util_key = cf_string("Device Utilization %")?;

    let mut iter = 0u32;
    let rs = unsafe {
        let matching = IOServiceMatching(class.as_ptr());
        if matching.is_null() {
            return Err("IOServiceMatching(IOAccelerator) failed".into());
        }
        // IOServiceGetMatchingServices consumes the matching dictionary, so
        // there is nothing to release on this path.
        IOServiceGetMatchingServices(0, matching, &mut iter)
    };
    if rs != 0 {
        return Err(format!("IOServiceGetMatchingServices: {rs}").into());
    }

    let mut best: Option<i64> = None;
    loop {
        let entry = unsafe { IOIteratorNext(iter) };
        if entry == 0 {
            break;
        }
        if let Some(pct) = utilization(entry, &stats_key, &util_key) {
            best = Some(best.map_or(pct, |b: i64| b.max(pct)));
        }
        unsafe { IOObjectRelease(entry) };
    }
    unsafe { IOObjectRelease(iter) };

    let pct = best.ok_or("no accelerator reported Device Utilization %")?;
    Ok(pct.clamp(0, 100) as u8)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_mac_has_an_accelerator_that_answers() {
        let pct = busy_percent().expect("busy_percent");
        assert!(pct <= 100, "got {pct}");
    }

    /// Reading the registry repeatedly must not leak or fault, since this runs
    /// on every status refresh for the life of the session.
    #[test]
    fn repeated_reads_stay_healthy() {
        for _ in 0..50 {
            assert!(busy_percent().is_ok());
        }
    }
}
