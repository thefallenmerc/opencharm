import Foundation

/// Bundled royalty-free background-music tracks, shipped under `App/Resources/Music` (see
/// `LICENSES.md` there). `id` is the `.mp3` filename (no extension) — matches the
/// `"preset:<id>"` source `StylingModel.resolveMusicURL` looks up in the app bundle.
enum MusicLibrary {
    static let presets: [(id: String, label: String)] = [
        (id: "calm", label: "Calm"),
        (id: "upbeat", label: "Upbeat"),
        (id: "corporate", label: "Corporate"),
        (id: "chill", label: "Chill"),
        (id: "piano", label: "Piano"),
    ]
}
