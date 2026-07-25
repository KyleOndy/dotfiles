//! Memory headroom on darwin: Mach VM statistics plus the swap sysctl.
//!
//! "Available" is total minus what Activity Monitor calls Memory Used, that is
//! app memory plus wired plus compressed. vm_stat's free/inactive/speculative
//! counts are the obvious alternative and they mislead: the kernel keeps RAM
//! full of reclaimable cache on purpose, so those sit low on a healthy machine.
//! `memory_pressure` reports a third number again, from its own definition.
//!
//! Struct layouts and constants below are transcribed from the SDK headers,
//! `usr/include/mach/vm_statistics.h`, `usr/include/mach/host_info.h`, and
//! `usr/include/sys/sysctl.h`, verified against MacOSX14.4.sdk.

use std::ffi::CString;
use std::mem::size_of;
use std::os::raw::{c_char, c_int, c_void};

use crate::Memory;

type Res<T> = Result<T, Box<dyn std::error::Error>>;

const HOST_VM_INFO64: c_int = 4;

/// `struct vm_statistics64`. Counts are in host pages, not bytes. `natural_t`
/// is a 32-bit unsigned int; the mixed widths below are the real layout.
///
/// Every field is spelled out even though four are read, because the kernel
/// copies out a fixed number of words and any gap would shift the rest.
#[repr(C)]
#[derive(Default)]
#[allow(dead_code)]
struct VmStatistics64 {
    free_count: u32,
    active_count: u32,
    inactive_count: u32,
    wire_count: u32,
    zero_fill_count: u64,
    reactivations: u64,
    pageins: u64,
    pageouts: u64,
    faults: u64,
    cow_faults: u64,
    lookups: u64,
    hits: u64,
    purges: u64,
    purgeable_count: u32,
    speculative_count: u32,
    decompressions: u64,
    compressions: u64,
    swapins: u64,
    swapouts: u64,
    compressor_page_count: u32,
    throttled_count: u32,
    external_page_count: u32,
    internal_page_count: u32,
    total_uncompressed_pages_in_compressor: u64,
}

/// `struct xsw_usage`, the payload behind `vm.swapusage`.
#[repr(C)]
#[derive(Default)]
#[allow(dead_code)]
struct XswUsage {
    total: u64,
    avail: u64,
    used: u64,
    pagesize: u32,
    encrypted: u32,
}

// All of these live in libSystem, which rust links on darwin by default, so
// unlike the IOKit bindings in system-temp there is no #[link] to declare.
unsafe extern "C" {
    fn mach_host_self() -> u32;
    fn host_page_size(host: u32, out: *mut usize) -> c_int;
    fn host_statistics64(host: u32, flavor: c_int, out: *mut c_void, count: *mut u32) -> c_int;
    fn sysctlbyname(
        name: *const c_char,
        oldp: *mut c_void,
        oldlenp: *mut usize,
        newp: *mut c_void,
        newlen: usize,
    ) -> c_int;
}

/// Read a fixed-size sysctl value. A short read means the kernel struct is not
/// the one this was built against, which is worth failing on rather than
/// reporting a number assembled from half a buffer.
fn sysctl<T: Default>(name: &str) -> Res<T> {
    let cname = CString::new(name)?;
    let mut out = T::default();
    let mut len = size_of::<T>();

    let rs = unsafe {
        sysctlbyname(
            cname.as_ptr(),
            &mut out as *mut _ as _,
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };

    if rs != 0 {
        return Err(format!("sysctl {name}: {}", std::io::Error::last_os_error()).into());
    }
    if len != size_of::<T>() {
        return Err(format!("sysctl {name}: read {len} of {} bytes", size_of::<T>()).into());
    }
    Ok(out)
}

/// The page size the VM counters are denominated in, which on Apple Silicon is
/// 16K rather than the 4K a lot of code assumes.
fn page_size() -> Res<u64> {
    let mut size: usize = 0;
    let rs = unsafe { host_page_size(mach_host_self(), &mut size) };
    if rs != 0 {
        return Err(format!("host_page_size: {rs}").into());
    }
    if size == 0 {
        return Err("host_page_size returned 0".into());
    }
    Ok(size as u64)
}

fn vm_stats() -> Res<VmStatistics64> {
    let mut out = VmStatistics64::default();
    // HOST_VM_INFO64_COUNT is the struct measured in natural_t, so derive it
    // rather than hardcoding a number that silently rots.
    let mut count = (size_of::<VmStatistics64>() / size_of::<u32>()) as u32;

    let rs = unsafe {
        host_statistics64(
            mach_host_self(),
            HOST_VM_INFO64,
            &mut out as *mut _ as _,
            &mut count,
        )
    };

    if rs != 0 {
        return Err(format!("host_statistics64: {rs}").into());
    }
    Ok(out)
}

pub fn sample() -> Res<Memory> {
    let total: u64 = sysctl("hw.memsize")?;
    let page = page_size()?;
    let vm = vm_stats()?;

    // internal_page_count is anonymous memory; the purgeable slice of it is
    // cache the kernel drops for free under pressure, so it is not really used.
    let app = (vm.internal_page_count as u64).saturating_sub(vm.purgeable_count as u64);
    let used = (app + vm.wire_count as u64 + vm.compressor_page_count as u64) * page;

    let swap: XswUsage = sysctl("vm.swapusage")?;

    Ok(Memory {
        available: total.saturating_sub(used),
        swap_used: swap.used,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The kernel copies out a fixed number of natural_t words, so a layout
    /// drift here would quietly shift every field past the first mismatch.
    #[test]
    fn vm_statistics64_matches_the_kernel_layout() {
        assert_eq!(size_of::<VmStatistics64>(), 152);
        assert_eq!(size_of::<VmStatistics64>() / size_of::<u32>(), 38);
        assert_eq!(size_of::<XswUsage>(), 32);
    }

    #[test]
    fn the_machine_reports_something_plausible() {
        let total: u64 = sysctl("hw.memsize").expect("hw.memsize");
        let mem = sample().expect("sample");
        assert!(mem.available > 0, "no headroom at all is implausible");
        assert!(
            mem.available < total,
            "headroom cannot exceed installed ram"
        );
    }
}
