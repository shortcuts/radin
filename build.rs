fn main() {
    for d in ["skills", "lib", "hosts"] {
        println!("cargo:rerun-if-changed={d}");
    }
}
