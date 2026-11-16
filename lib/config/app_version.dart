/// The app's version as built ("1.2.0+34"), from the defines the Flutter
/// tool adds for `--build-name` and `--build-number` (FLUTTER_BUILD_NAME,
/// FLUTTER_BUILD_NUMBER). Empty in a plain `flutter run`: the server then
/// records "unknown". Sent with sign-in (Law 175/2018 sign-in log, R2) and
/// with the sensitive-data consents (R3); never personal.
String appVersionLabel() {
  const String name = String.fromEnvironment('FLUTTER_BUILD_NAME');
  const String number = String.fromEnvironment('FLUTTER_BUILD_NUMBER');
  if (name.isEmpty) {
    return 'unknown';
  }
  return number.isEmpty ? name : '$name+$number';
}
