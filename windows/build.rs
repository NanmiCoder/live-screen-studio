fn main() {
    println!("cargo:rerun-if-changed=assets/LiveZoom.ico");
    println!("cargo:rerun-if-changed=assets/app.manifest");

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        #[cfg(target_os = "windows")]
        {
            let mut res = winresource::WindowsResource::new();
            res.set_icon("assets/LiveZoom.ico");
            res.set_manifest_file("assets/app.manifest");
            res.set("ProductName", "LiveZoom");
            res.set("FileDescription", "LiveZoom — 实时屏幕放大与标注工具");
            res.set("LegalCopyright", "Copyright (c) LiveZoom Contributors");
            if let Err(err) = res.compile_for("LiveZoom") {
                panic!("failed to compile Windows resources: {err}");
            }
        }
    }
}
