fn main() {
    let mut attributes = tauri_build::Attributes::new();

    #[cfg(target_os = "windows")]
    {
        let manifest = r#"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <!-- Зависимость от современных компонентов UI (Решает ошибку "Точка входа не найдена") -->
  <dependency>
    <dependentAssembly>
      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*" />
    </dependentAssembly>
  </dependency>
  
  <!-- Запрос прав администратора -->
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false" />
      </requestedPrivileges>
    </security>
  </trustInfo>

  <!-- Указание поддержки современных версий Windows -->
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <!-- Windows 10 and 11 -->
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
</assembly>
"#;
        let windows_attrs = tauri_build::WindowsAttributes::new().app_manifest(manifest);
        attributes = attributes.windows_attributes(windows_attrs);
    }

    tauri_build::try_build(attributes).expect("failed to run tauri-build");
}