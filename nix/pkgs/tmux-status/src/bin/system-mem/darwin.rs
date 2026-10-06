//! Memory headroom on darwin: Mach VM statistics plus the swap sysctl.
//!
//! Available is the memory the VM manages minus what Activity Monitor calls
//! Memory Used (app, wired and compressed), which works out to free pages plus
//! the file-backed and purgeable pages the kernel drops under pressure.
//! hw.memsize is no part of it: it includes firmware carve-outs the VM never
//! manages, about 835 MiB on a 32G M5.
//!
//! Layouts and constants are from the MacOSX SDK headers mach/vm_statistics.h,
//! mach/host_info.h and sys/sysctl.h.

use std::mem::size_of;
use std::os::raw::{c_char, c_int, c_void};

use tmux_status::Res;

use crate::Memory;

const HOST_VM_INFO64: c_int = 4;

/// `struct vm_statistics64` at revision 1. Counts are in kernel pages.
/// host_statistics64 fills as many words as the count asks for, and
/// HOST_VM_INFO64_REV1_COUNT (38) ends at the last field here.
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

// libSystem, which rust links on darwin by default.
unsafe extern "C" {
    static vm_kernel_page_size: usize;
    fn mach_host_self() -> u32;
    fn host_statistics64(host: u32, flavor: c_int, out: *mut c_void, count: *mut u32) -> c_int;
    fn sysctlbyname(
        name: *const c_char,
        oldp: *mut c_void,
        oldlenp: *mut usize,
        newp: *mut c_void,
        newlen: usize,
    ) -> c_int;
}

fn vm_stats() -> Res<VmStatistics64> {
    let mut out = VmStatistics64::default();
    let mut count = (size_of::<VmStatistics64>() / size_of::<u32>()) as u32;
    let rs = unsafe {
        host_statistics64(
            mach_host_self(),
            HOST_VM_INFO64,
            (&raw mut out).cast(),
            &mut count,
        )
    };
    if rs != 0 {
        return Err(format!("host_statistics64: {rs}").into());
    }
    Ok(out)
}

/// A short read means the kernel's struct is not the one this was built
/// against, which is worth failing on rather than reporting half a buffer.
fn swap_used() -> Res<u64> {
    let mut out = XswUsage::default();
    let mut len = size_of::<XswUsage>();
    let rs = unsafe {
        sysctlbyname(
            c"vm.swapusage".as_ptr(),
            (&raw mut out).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rs != 0 {
        return Err(format!("sysctl vm.swapusage: {}", std::io::Error::last_os_error()).into());
    }
    if len != size_of::<XswUsage>() {
        return Err(format!(
            "sysctl vm.swapusage: read {len} of {} bytes",
            size_of::<XswUsage>()
        )
        .into());
    }
    Ok(out.used)
}

/// free_count includes the speculative pages, which external_page_count also
/// counts, so they come off once.
fn available_pages(vm: &VmStatistics64) -> u64 {
    u64::from(vm.free_count).saturating_sub(u64::from(vm.speculative_count))
        + u64::from(vm.external_page_count)
        + u64::from(vm.purgeable_count)
}

pub fn sample() -> Res<Memory> {
    let page = unsafe { vm_kernel_page_size } as u64;
    Ok(Memory {
        available: available_pages(&vm_stats()?) * page,
        swap_used: swap_used()?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn structs_match_the_sdk_layouts() {
        assert_eq!(size_of::<VmStatistics64>() / size_of::<u32>(), 38);
        assert_eq!(size_of::<XswUsage>(), 32);
    }

    /// Headroom can never exceed what the VM manages, and on a running machine
    /// some of it is always in use.
    #[test]
    fn headroom_fits_inside_usable_memory() {
        let mut usable = 0u64;
        let mut len = size_of::<u64>();
        let rs = unsafe {
            sysctlbyname(
                c"hw.memsize_usable".as_ptr(),
                (&raw mut usable).cast(),
                &mut len,
                std::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(rs, 0);
        let mem = sample().expect("sample");
        assert!(
            mem.available > 0 && mem.available < usable,
            "{} of {usable}",
            mem.available
        );
    }
}
