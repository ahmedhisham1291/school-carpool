import 'package:school_carpool/bootstrap.dart';
import 'package:school_carpool/config/flavor.dart';

/// Entry point for the dev flavor: flutter run -t lib/main_dev.dart
Future<void> main() => bootstrap(Flavor.dev);
