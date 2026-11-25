fn main() {
    println!("cargo:rustc-link-arg-cdylib=/DELAYLOAD:r4y-probe-delayed.dll");
    println!("cargo:rustc-link-lib=delayimp");
}
