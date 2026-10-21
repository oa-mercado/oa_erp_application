import '../config/env_config.dart';

/// API Constants defining the endpoints on the OrangeApps ERP backend.
/// Automatically adapts based on build mode:
/// - Debug mode (`--debug`): uses `DEBUG_BASE_URL` from `.env` (`http://localhost/qr`)
/// - Release mode (`--release`): uses `RELEASE_BASE_URL` from `.env` (`https://schooltesterp.orangeapps.ph/qr`)
class ApiConstants {
  /// Base URL dynamically determined from .env and build mode
  static String get defaultBaseUrl => EnvConfig.baseUrl;

  /// Debug mode URL
  static String get localBaseUrl => EnvConfig.debugBaseUrl;

  /// Release mode URL
  static String get testBaseUrl => EnvConfig.releaseBaseUrl;

  /// Endpoint for fetching school logo & initializing session/CSRF cookies (AdminController@getSchImg)
  static const String schoolImageEndpoint = '/schImg';

  /// Endpoint for fetching branches from creds.json (StudentTrackingController@getBranches)
  static const String branchesEndpoint = '/branches';

  /// Endpoint for fetching gates from places_tbl (StudentTrackingController@places)
  static const String placesEndpoint = '/places';

  /// Configurable endpoint for logging RFID tap & parent SMS (`/student_entry` or `/save_rfid_entry`)
  static String get saveRfidEntryEndpoint => EnvConfig.tapEndpoint;

  /// Session-free endpoint for bulk syncing K-12, College, and Employee roster to SQLite Local DB
  static const String syncRosterEndpoint = '/kiosk_sync_roster';
}
