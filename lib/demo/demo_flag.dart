/// Whether this process reads and writes the demo data store. Checked at
/// the few places that reach outside the app's own files — the photo
/// library, iCloud Drive, the keychain — so demo mode can never touch the
/// real ones. See `demo_mode.dart`.
class DemoFlag {
  static bool active = false;
}
