/// Default dock order. Entries not installed are skipped and remaining slots
/// are filled from the application index. Keeping desktop-file ids here—not
/// display names—makes the setting stable across localization and renames.
pub const pinned_apps = [_][]const u8{
    "com.system76.CosmicFiles.desktop",
    "com.system76.CosmicTerm.desktop",
    "com.system76.CosmicEdit.desktop",
    "firefox.desktop",
    "org.prismlauncher.PrismLauncher.desktop",
    "mpv.desktop",
    "com.system76.CosmicSettings.desktop",
};
