import 'package:school_carpool/bootstrap.dart';
import 'package:school_carpool/config/flavor.dart';

/// Default entry point (`flutter run` without `-t`) is the dev flavor, so the
/// app can never reach production by accident. Use `lib/main_<flavor>.dart`.
Future<void> main() => bootstrap(Flavor.dev);
