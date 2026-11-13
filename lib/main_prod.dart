import 'package:school_carpool/bootstrap.dart';
import 'package:school_carpool/config/flavor.dart';

/// Entry point for the prod flavor: flutter run -t lib/main_prod.dart
Future<void> main() => bootstrap(Flavor.prod);
