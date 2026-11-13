import 'package:school_carpool/admin/admin_bootstrap.dart';
import 'package:school_carpool/config/flavor.dart';

/// Admin web panel, prod flavor:
///   flutter run -d chrome -t lib/admin/main_admin_prod.dart
Future<void> main() => adminBootstrap(Flavor.prod);
