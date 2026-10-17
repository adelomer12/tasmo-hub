/// Shown on the About screen. Keep [appVersion] equal to the version in
/// pubspec.yaml (a test checks it).
const appVersion = '1.1.2';

/// Commit the APK was built from; CI passes it with --dart-define.
const gitSha = String.fromEnvironment('GIT_SHA');

const repoUrl = 'https://github.com/adelomer12/tasmo-hub';
