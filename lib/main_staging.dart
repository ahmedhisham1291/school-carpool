import 'package:school_carpool/bootstrap.dart';
import 'package:school_carpool/config/flavor.dart';

/// Entry point for the staging flavor: flutter run -t lib/main_staging.dart
Future<void> main() => bootstrap(Flavor.staging);
