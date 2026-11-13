import 'package:school_carpool/admin/admin_bootstrap.dart';
import 'package:school_carpool/config/flavor.dart';

/// Admin web panel, dev flavor:
///   flutter run -d chrome -t lib/admin/main_admin_dev.dart
Future<void> main() => adminBootstrap(Flavor.dev);
