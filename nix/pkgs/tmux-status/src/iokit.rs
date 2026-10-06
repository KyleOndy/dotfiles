//! IOKit and CoreFoundation as the darwin segments use them. Signatures follow
//! the MacOSX SDK headers IOKitLib.h, CFBase.h, CFNumber.h and CFString.h.

use std::ffi::{c_char, c_void, CString};

use crate::Res;

const KCF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
/// CFNumberType is `CF_ENUM(CFIndex, ...)`, a 64-bit signed long.
const KCF_NUMBER_SINT64_TYPE: isize = 4;

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IOServiceMatching(name: *const c_char) -> *const c_void;
    fn IOServiceGetMatchingServices(main_port: u32, matching: *const c_void, iter: *mut u32)
        -> i32;
    fn IOIteratorNext(iter: u32) -> u32;
    fn IOObjectRelease(object: u32) -> i32;
    fn IORegistryEntryCreateCFProperty(
        entry: u32,
        key: *const c_void,
        allocator: *const c_void,
        options: u32,
    ) -> *const c_void;
    pub fn IORegistryEntryGetName(entry: u32, name: *mut c_char) -> i32;
    pub fn IOServiceOpen(service: u32, owning_task: u32, kind: u32, connect: *mut u32) -> i32;
    pub fn IOServiceClose(connect: u32) -> i32;
    pub fn IOConnectCallStructMethod(
        connect: u32,
        selector: u32,
        input: *const c_void,
        input_size: usize,
        output: *mut c_void,
        output_size: *mut usize,
    ) -> i32;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringCreateWithCString(
        alloc: *const c_void,
        cstr: *const c_char,
        encoding: u32,
    ) -> *const c_void;
    fn CFDictionaryGetValue(dict: *const c_void, key: *const c_void) -> *const c_void;
    fn CFNumberGetValue(number: *const c_void, kind: isize, out: *mut c_void) -> u8;
    fn CFGetTypeID(cf: *const c_void) -> usize;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFNumberGetTypeID() -> usize;
    fn CFRelease(cf: *const c_void);
}

/// A CoreFoundation object from a Create or Copy call, which the holder owns.
struct Cf(*const c_void);

impl Drop for Cf {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) };
    }
}

fn cf_string(s: &str) -> Option<Cf> {
    let c = CString::new(s).ok()?;
    let raw = unsafe {
        CFStringCreateWithCString(std::ptr::null(), c.as_ptr(), KCF_STRING_ENCODING_UTF8)
    };
    (!raw.is_null()).then_some(Cf(raw))
}

/// `cf` is borrowed. Its type is checked first because handing anything but a
/// CFNumber to CFNumberGetValue is undefined behaviour rather than a miss.
fn number(cf: *const c_void) -> Option<i64> {
    if cf.is_null() || unsafe { CFGetTypeID(cf) != CFNumberGetTypeID() } {
        return None;
    }
    let mut out = 0i64;
    let ok = unsafe { CFNumberGetValue(cf, KCF_NUMBER_SINT64_TYPE, (&raw mut out).cast()) };
    (ok != 0).then_some(out)
}

/// An IOKit object handle, released on drop.
pub struct Object(pub u32);

impl Drop for Object {
    fn drop(&mut self) {
        unsafe { IOObjectRelease(self.0) };
    }
}

impl Object {
    fn property(&self, key: &str) -> Option<Cf> {
        let key = cf_string(key)?;
        let raw = unsafe { IORegistryEntryCreateCFProperty(self.0, key.0, std::ptr::null(), 0) };
        (!raw.is_null()).then_some(Cf(raw))
    }

    pub fn int(&self, key: &str) -> Option<i64> {
        number(self.property(key)?.0)
    }

    /// An integer inside a dictionary-valued property.
    pub fn int_in(&self, dict: &str, key: &str) -> Option<i64> {
        let dict = self.property(dict)?;
        if unsafe { CFGetTypeID(dict.0) != CFDictionaryGetTypeID() } {
            return None;
        }
        let key = cf_string(key)?;
        // Get rule: the value is borrowed from `dict`, not released here.
        number(unsafe { CFDictionaryGetValue(dict.0, key.0) })
    }
}

pub struct Services(Object);

impl Iterator for Services {
    type Item = Object;

    fn next(&mut self) -> Option<Object> {
        let entry = unsafe { IOIteratorNext(self.0 .0) };
        (entry != 0).then_some(Object(entry))
    }
}

/// Registry entries of IOKit class `class`.
pub fn services(class: &str) -> Res<Services> {
    let name = CString::new(class)?;
    let mut iter = 0;
    let rs = unsafe {
        let matching = IOServiceMatching(name.as_ptr());
        if matching.is_null() {
            return Err(format!("IOServiceMatching({class}) failed").into());
        }
        // Consumes `matching`, so there is nothing to release.
        IOServiceGetMatchingServices(0, matching, &mut iter)
    };
    if rs != 0 {
        return Err(format!("IOServiceGetMatchingServices({class}): {rs:#x}").into());
    }
    Ok(Services(Object(iter)))
}
