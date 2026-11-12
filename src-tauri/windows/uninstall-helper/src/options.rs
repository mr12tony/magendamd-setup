use std::ffi::OsString;

pub struct Options {
    pub product_name: String,
    pub manufacturer: String,
    pub bundle_id: String,
    pub delete_app_data: bool,
}

impl Options {
    pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<Self, i32> {
        let mut args = args.into_iter();
        let mut product_name = None;
        let mut manufacturer = None;
        let mut bundle_id = None;
        let mut delete_app_data = false;
        while let Some(arg) = args.next() {
            let slot = match arg.to_str() {
                Some("--product-name") => &mut product_name,
                Some("--manufacturer") => &mut manufacturer,
                Some("--bundle-id") => &mut bundle_id,
                Some("--delete-app-data") if !delete_app_data => {
                    delete_app_data = true;
                    continue;
                }
                _ => return Err(44),
            };
            if slot.is_some() {
                return Err(44);
            }
            let value = args
                .next()
                .and_then(|value| value.into_string().ok())
                .ok_or(44)?;
            // Each value is a single directory/registry component, never a path.
            if value.is_empty()
                || value == "."
                || value == ".."
                || value.ends_with(['.', ' '])
                || value
                    .chars()
                    .any(|c| c.is_control() || "\\/:*?\"<>|".contains(c))
            {
                return Err(44);
            }
            *slot = Some(value);
        }
        Ok(Self {
            product_name: product_name.ok_or(44)?,
            manufacturer: manufacturer.ok_or(44)?,
            bundle_id: bundle_id.ok_or(44)?,
            delete_app_data,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arguments() -> Vec<OsString> {
        [
            "--product-name",
            "MagendaSupport",
            "--manufacturer",
            "Magenda",
            "--bundle-id",
            "com.magendamd.support",
        ]
        .map(OsString::from)
        .to_vec()
    }

    #[test]
    fn app_data_requires_explicit_opt_in() {
        let mut args = arguments();
        let options = Options::parse(args.clone()).unwrap();
        assert!(!options.delete_app_data);
        assert_eq!(options.product_name, "MagendaSupport");
        assert_eq!(options.manufacturer, "Magenda");
        assert_eq!(options.bundle_id, "com.magendamd.support");
        args.push("--delete-app-data".into());
        assert!(Options::parse(args).unwrap().delete_app_data);
    }

    #[test]
    fn invalid_or_incomplete_arguments_fail_before_cleanup() {
        assert!(Options::parse(Vec::<OsString>::new()).is_err());
        for invalid in [
            "..",
            "../other",
            "C:\\Users",
            "other\\profile",
            "",
            "profile.",
        ] {
            let mut args = arguments();
            args[5] = invalid.into();
            assert!(Options::parse(args).is_err());
        }
        let mut args = arguments();
        args.extend(["--bundle-id".into(), "other".into()]);
        assert!(Options::parse(args).is_err());
    }
}
