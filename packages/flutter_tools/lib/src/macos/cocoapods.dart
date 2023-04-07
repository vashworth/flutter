// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/file.dart';
import 'package:process/process.dart';

import '../base/common.dart';
import '../base/error_handling_io.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/os.dart';
import '../base/platform.dart';
import '../base/process.dart';
import '../base/version.dart';
import '../build_info.dart';
import '../cache.dart';
import '../ios/xcodeproj.dart';
import '../reporting/reporting.dart';
import '../xcode_project.dart';

const String noCocoaPodsConsequence = '''
  CocoaPods is used to retrieve the iOS and macOS platform side's plugin code that responds to your plugin usage on the Dart side.
  Without CocoaPods, plugins will not work on iOS or macOS.
  For more info, see https://flutter.dev/platform-plugins''';

const String unknownCocoaPodsConsequence = '''
  Flutter is unable to determine the installed CocoaPods's version.
  Ensure that the output of 'pod --version' contains only digits and . to be recognized by Flutter.''';

const String brokenCocoaPodsConsequence = '''
  You appear to have CocoaPods installed but it is not working.
  This can happen if the version of Ruby that CocoaPods was installed with is different from the one being used to invoke it.
  This can usually be fixed by re-installing CocoaPods.''';

const String outOfDateFrameworksPodfileConsequence = '''
  This can cause a mismatched version of Flutter to be embedded in your app, which may result in App Store submission rejection or crashes.
  If you have local Podfile edits you would like to keep, see https://github.com/flutter/flutter/issues/24641 for instructions.''';

const String outOfDatePluginsPodfileConsequence = '''
  This can cause issues if your application depends on plugins that do not support iOS or macOS.
  See https://flutter.dev/docs/development/packages-and-plugins/developing-packages#plugin-platforms for details.
  If you have local Podfile edits you would like to keep, see https://github.com/flutter/flutter/issues/45197 for instructions.''';

const String cocoaPodsInstallInstructions = 'see https://guides.cocoapods.org/using/getting-started.html#installation for instructions.';

const String podfileIosMigrationInstructions = '''
  rm ios/Podfile''';

const String podfileMacOSMigrationInstructions = '''
  rm macos/Podfile''';

/// Result of evaluating the CocoaPods installation.
enum CocoaPodsStatus {
  /// iOS plugins will not work, installation required.
  notInstalled,
  /// iOS plugins might not work, upgrade recommended.
  unknownVersion,
  /// iOS plugins will not work, upgrade required.
  belowMinimumVersion,
  /// iOS plugins may not work in certain situations (Swift, static libraries),
  /// upgrade recommended.
  belowRecommendedVersion,
  /// Everything should be fine.
  recommended,
  /// iOS plugins will not work, re-install required.
  brokenInstall,
}

const Version cocoaPodsMinimumVersion = Version.withText(1, 10, 0, '1.10.0');
const Version cocoaPodsRecommendedVersion = Version.withText(1, 11, 0, '1.11.0');

/// Cocoapods is a dependency management solution for iOS and macOS applications.
///
/// Cocoapods is generally installed via ruby gems and interacted with via
/// the `pod` CLI command.
///
/// See also:
///   * https://cocoapods.org/ - the cocoapods website.
///   * https://flutter.dev/docs/get-started/install/macos#deploy-to-ios-devices - instructions for
///     installing iOS/macOS dependencies.
class CocoaPods {
  CocoaPods({
    required FileSystem fileSystem,
    required ProcessManager processManager,
    required XcodeProjectInterpreter xcodeProjectInterpreter,
    required Logger logger,
    required Platform platform,
    required Usage usage,
  }) : _fileSystem = fileSystem,
      _processManager = processManager,
      _xcodeProjectInterpreter = xcodeProjectInterpreter,
      _logger = logger,
      _usage = usage,
      _processUtils = ProcessUtils(processManager: processManager, logger: logger),
      _operatingSystemUtils = OperatingSystemUtils(
        fileSystem: fileSystem,
        logger: logger,
        platform: platform,
        processManager: processManager,
      );

  final FileSystem _fileSystem;
  final ProcessManager _processManager;
  final ProcessUtils _processUtils;
  final OperatingSystemUtils _operatingSystemUtils;
  final XcodeProjectInterpreter _xcodeProjectInterpreter;
  final Logger _logger;
  final Usage _usage;

  Future<String?>? _versionText;

  Future<bool> get isInstalled =>
    _processUtils.exitsHappy(<String>['which', 'pod']);

  Future<String?> get cocoaPodsVersionText {
    _versionText ??= _processUtils.run(
      <String>['pod', '--version'],
      environment: <String, String>{
        'LANG': 'en_US.UTF-8',
      },
    ).then<String?>((RunResult result) {
      return result.exitCode == 0 ? result.stdout.trim() : null;
    }, onError: (dynamic _) => null);
    return _versionText!;
  }

  Future<CocoaPodsStatus> get evaluateCocoaPodsInstallation async {
    if (!(await isInstalled)) {
      return CocoaPodsStatus.notInstalled;
    }
    final String? versionText = await cocoaPodsVersionText;
    if (versionText == null) {
      return CocoaPodsStatus.brokenInstall;
    }
    try {
      final Version? installedVersion = Version.parse(versionText);
      if (installedVersion == null) {
        return CocoaPodsStatus.unknownVersion;
      }
      if (installedVersion < cocoaPodsMinimumVersion) {
        return CocoaPodsStatus.belowMinimumVersion;
      }
      if (installedVersion < cocoaPodsRecommendedVersion) {
        return CocoaPodsStatus.belowRecommendedVersion;
      }
      return CocoaPodsStatus.recommended;
    } on FormatException {
      return CocoaPodsStatus.notInstalled;
    }
  }

  Future<bool> processPods({
    required XcodeBasedProject xcodeProject,
    required BuildMode buildMode,
    bool dependenciesChanged = true,
  }) async {
    if (!xcodeProject.podfile.existsSync()) {
      // TODO
      return false;
      // throwToolExit('Podfile missing');
    }
    _warnIfPodfileOutOfDate(xcodeProject);
    bool podsProcessed = false;
    if (_shouldRunPodInstall(xcodeProject, dependenciesChanged)) {
      if (!await _checkPodCondition()) {
        throwToolExit('CocoaPods not installed or not in valid state.');
      }
      await _runPodInstall(xcodeProject, buildMode);
      podsProcessed = true;
    }
    return podsProcessed;
  }

  /// Make sure the CocoaPods tools are in the right states.
  Future<bool> _checkPodCondition() async {
    final CocoaPodsStatus installation = await evaluateCocoaPodsInstallation;
    switch (installation) {
      case CocoaPodsStatus.notInstalled:
        _logger.printWarning(
          'Warning: CocoaPods not installed. Skipping pod install.\n'
          '$noCocoaPodsConsequence\n'
          'To install $cocoaPodsInstallInstructions\n',
          emphasis: true,
        );
        return false;
      case CocoaPodsStatus.brokenInstall:
        _logger.printWarning(
          'Warning: CocoaPods is installed but broken. Skipping pod install.\n'
          '$brokenCocoaPodsConsequence\n'
          'To re-install $cocoaPodsInstallInstructions\n',
          emphasis: true,
        );
        return false;
      case CocoaPodsStatus.unknownVersion:
        _logger.printWarning(
          'Warning: Unknown CocoaPods version installed.\n'
          '$unknownCocoaPodsConsequence\n'
          'To upgrade $cocoaPodsInstallInstructions\n',
          emphasis: true,
        );
        break;
      case CocoaPodsStatus.belowMinimumVersion:
        _logger.printWarning(
          'Warning: CocoaPods minimum required version $cocoaPodsMinimumVersion or greater not installed. Skipping pod install.\n'
          '$noCocoaPodsConsequence\n'
          'To upgrade $cocoaPodsInstallInstructions\n',
          emphasis: true,
        );
        return false;
      case CocoaPodsStatus.belowRecommendedVersion:
        _logger.printWarning(
          'Warning: CocoaPods recommended version $cocoaPodsRecommendedVersion or greater not installed.\n'
          'Pods handling may fail on some projects involving plugins.\n'
          'To upgrade $cocoaPodsInstallInstructions\n',
          emphasis: true,
        );
        break;
      case CocoaPodsStatus.recommended:
        break;
    }

    return true;
  }

  /// Ensures the given Xcode-based sub-project of a parent Flutter project
  /// contains a suitable `Podfile` and that its `Flutter/Xxx.xcconfig` files
  /// include pods configuration.
  Future<void> setupPodfile(XcodeBasedProject xcodeProject) async {
    if (!_xcodeProjectInterpreter.isInstalled) {
      // Don't do anything for iOS when host platform doesn't support it.
      return;
    }
    final Directory runnerProject = xcodeProject.xcodeProject;
    if (!runnerProject.existsSync()) {
      return;
    }
    final File podfile = xcodeProject.podfile;
    if (podfile.existsSync()) {
      addPodsDependencyToFlutterXcconfig(xcodeProject);
      return;
    }
    String podfileTemplateName;
    if (xcodeProject is MacOSProject) {
      podfileTemplateName = 'Podfile-macos';
    } else {
      final bool isSwift = (await _xcodeProjectInterpreter.getBuildSettings(
        runnerProject.path,
        buildContext: const XcodeProjectBuildContext(),
      )).containsKey('SWIFT_VERSION');
      podfileTemplateName = isSwift ? 'Podfile-ios-swift' : 'Podfile-ios-objc';
    }
    final File podfileTemplate = _fileSystem.file(_fileSystem.path.join(
      Cache.flutterRoot!,
      'packages',
      'flutter_tools',
      'templates',
      'cocoapods',
      podfileTemplateName,
    ));
    podfileTemplate.copySync(podfile.path);
    addPodsDependencyToFlutterXcconfig(xcodeProject);
  }

  /// Ensures all `Flutter/Xxx.xcconfig` files for the given Xcode-based
  /// sub-project of a parent Flutter project include pods configuration.
  void addPodsDependencyToFlutterXcconfig(XcodeBasedProject xcodeProject) {
    _addPodsDependencyToFlutterXcconfig(xcodeProject, 'Debug');
    _addPodsDependencyToFlutterXcconfig(xcodeProject, 'Release');
  }

  void _addPodsDependencyToFlutterXcconfig(XcodeBasedProject xcodeProject, String mode) {
    final File file = xcodeProject.xcodeConfigFor(mode);
    if (file.existsSync()) {
      final String content = file.readAsStringSync();
      final String includeFile = 'Pods/Target Support Files/Pods-Runner/Pods-Runner.${mode
          .toLowerCase()}.xcconfig';
      final String include = '#include? "$includeFile"';
      if (!content.contains('Pods/Target Support Files/Pods-')) {
        file.writeAsStringSync('$include\n$content', flush: true);
      }
    }
  }

  /// Ensures that pod install is deemed needed on next check.
  void invalidatePodInstallOutput(XcodeBasedProject xcodeProject) {
    final File manifestLock = xcodeProject.podManifestLock;
    ErrorHandlingFileSystem.deleteIfExists(manifestLock);
  }

  // Check if you need to run pod install.
  // The pod install will run if any of below is true.
  // 1. Flutter dependencies have changed
  // 2. Podfile.lock doesn't exist or is older than Podfile
  // 3. Pods/Manifest.lock doesn't exist (It is deleted when plugins change)
  // 4. Podfile.lock doesn't match Pods/Manifest.lock.
  bool _shouldRunPodInstall(XcodeBasedProject xcodeProject, bool dependenciesChanged) {
    if (dependenciesChanged) {
      return true;
    }

    final File podfileFile = xcodeProject.podfile;
    final File podfileLockFile = xcodeProject.podfileLock;
    final File manifestLockFile = xcodeProject.podManifestLock;

    return !podfileLockFile.existsSync()
        || !manifestLockFile.existsSync()
        || podfileLockFile.statSync().modified.isBefore(podfileFile.statSync().modified)
        || podfileLockFile.readAsStringSync() != manifestLockFile.readAsStringSync();
  }

  Future<void> _runPodInstall(XcodeBasedProject xcodeProject, BuildMode buildMode) async {
    final Status status = _logger.startProgress('Running pod install...');
    final ProcessResult result = await _processManager.run(
      <String>['pod', 'install', '--verbose'],
      workingDirectory: _fileSystem.path.dirname(xcodeProject.podfile.path),
      environment: <String, String>{
        // See https://github.com/flutter/flutter/issues/10873.
        // CocoaPods analytics adds a lot of latency.
        'COCOAPODS_DISABLE_STATS': 'true',
        'LANG': 'en_US.UTF-8',
      },
    );
    status.stop();
    if (_logger.isVerbose || result.exitCode != 0) {
      final String stdout = result.stdout as String;
      if (stdout.isNotEmpty) {
        _logger.printStatus("CocoaPods' output:\n↳");
        _logger.printStatus(stdout, indent: 4);
      }
      final String stderr = result.stderr as String;
      if (stderr.isNotEmpty) {
        _logger.printStatus('Error output from CocoaPods:\n↳');
        _logger.printStatus(stderr, indent: 4);
      }
    }

    if (result.exitCode != 0) {
      invalidatePodInstallOutput(xcodeProject);
      _diagnosePodInstallFailure(result);
      throwToolExit('Error running pod install');
    } else if (xcodeProject.podfileLock.existsSync()) {
      // Even if the Podfile.lock didn't change, update its modified date to now
      // so Podfile.lock is newer than Podfile.
      _processManager.runSync(
        <String>['touch', xcodeProject.podfileLock.path],
        workingDirectory: _fileSystem.path.dirname(xcodeProject.podfile.path),
      );
    }
  }

  void _diagnosePodInstallFailure(ProcessResult result) {
    final Object? stdout = result.stdout;
    final Object? stderr = result.stderr;
    if (stdout is! String || stderr is! String) {
      return;
    }
    if (stdout.contains('out-of-date source repos')) {
      _logger.printError(
        "Error: CocoaPods's specs repository is too out-of-date to satisfy dependencies.\n"
        'To update the CocoaPods specs, run:\n'
        '  pod repo update\n',
        emphasis: true,
      );
    } else if ((_isFfiX86Error(stdout) || _isFfiX86Error(stderr)) &&
        _operatingSystemUtils.hostPlatform == HostPlatform.darwin_arm64) {
      // https://github.com/flutter/flutter/issues/70796
      UsageEvent(
        'pod-install-failure',
        'arm-ffi',
        flutterUsage: _usage,
      ).send();
      _logger.printError(
        'Error: To set up CocoaPods for ARM macOS, run:\n'
        '  sudo gem uninstall ffi && sudo gem install ffi -- --enable-libffi-alloc\n',
        emphasis: true,
      );
    }
  }

  bool _isFfiX86Error(String error) {
    return error.contains('ffi_c.bundle') || error.contains('/ffi/');
  }

  void _warnIfPodfileOutOfDate(XcodeBasedProject xcodeProject) {
    final bool isIos = xcodeProject is IosProject;
    if (isIos) {
      // Previously, the Podfile created a symlink to the cached artifacts engine framework
      // and installed the Flutter pod from that path. This could get out of sync with the copy
      // of the Flutter engine that was copied to ios/Flutter by the xcode_backend script.
      // It was possible for the symlink to point to a Debug version of the engine when the
      // Xcode build configuration was Release, which caused App Store submission rejections.
      //
      // Warn the user if they are still symlinking to the framework.
      final Link flutterSymlink = _fileSystem.link(_fileSystem.path.join(
        xcodeProject.symlinks.path,
        'flutter',
      ));
      if (flutterSymlink.existsSync()) {
        throwToolExit(
          'Warning: Podfile is out of date\n'
              '$outOfDateFrameworksPodfileConsequence\n'
              'To regenerate the Podfile, run:\n'
              '$podfileIosMigrationInstructions\n',
        );
      }
    }
    // Most of the pod and plugin parsing logic was moved from the Podfile
    // into the tool's podhelper.rb script. If the Podfile still references
    // the old parsed .flutter-plugins file, prompt the regeneration. Old line was:
    // plugin_pods = parse_KV_file('../.flutter-plugins')
    if (xcodeProject.podfile.existsSync() &&
      xcodeProject.podfile.readAsStringSync().contains(".flutter-plugins'")) {
      const String warning = 'Warning: Podfile is out of date\n'
          '$outOfDatePluginsPodfileConsequence\n'
          'To regenerate the Podfile, run:\n';
      if (isIos) {
        throwToolExit('$warning\n$podfileIosMigrationInstructions\n');
      } else {
        // The old macOS Podfile will work until `.flutter-plugins` is removed.
        // Warn instead of exit.
        _logger.printWarning('$warning\n$podfileMacOSMigrationInstructions\n', emphasis: true);
      }
    }
  }
}


class PodspecMigration {
  PodspecMigration({
    required this.podspecPath,
    required FileSystem fileSystem,
    required Logger logger,
  }) : _fileSystem = fileSystem,
      _logger = logger;

  final String podspecPath;

  final FileSystem _fileSystem;
  final Logger _logger;

  String preSpec = '';
  String postSpec = '';

  // List<String> swiftVersion = <String>[];

  // Root specifications
  Map<PodspecSpecification, dynamic?> rootSpecifications = <PodspecSpecification, dynamic?>{
  };

  List<String> swiftVersions = <String>[];


  Future<void> parsePodspec() async {
    final File podspec =_fileSystem.file(podspecPath);
    if (!await podspec.exists()) {
      _logger.printTrace('Unable to find podspec');
      // walk directory to search for it?
      // pluginIOSDirectory.list()
      return;
    }

    bool prePod = true;
    bool endPod = false;
    String specName = '';
    final List<String> lines = await podspec.readAsLines();
    for (String line in lines) {
      line = line.trim();
      if (line.startsWith('#') || line == '') {
        continue;
      }
      if (line.startsWith('Pod::Spec')) {
        // Pod::Spec.new do |s|
        final List<String> parts = line.split('|');
        if (parts.length != 3) {
          _logger.printTrace('Unable to get spec for podspec');
          return;
        }
        specName = parts[1].trim();
        prePod = false;
      } else if (prePod == true) {
        preSpec += line;
      } else if (endPod == true) {
        postSpec += line;
      } else if (prePod == false) {
        if (line == 'end') {
          endPod = true;
        } else {
          // Split key from value
          final List<String> parts = _splitKeyFromValue(line, specName);
          if (parts.length != 2) {
            _logger.printTrace('Unable to get key for: $line');
            continue;
          }
          final String fullKeyString = parts[0].trim();
          final String fullValueString = parts[1].trim();

          // Determine key
          // s.ios.deployment_target
          final String keyString = fullKeyString.replaceFirst('$specName.', '');
          final List<String> keyNameParts = keyString.split('.');
          final PodspecSpecification? key = PodspecSpecification.fromKeyString(keyNameParts.last);

          if (key == null) {
            final UnsupportedPodspecSpecification? unsupportedKey = UnsupportedPodspecSpecification.fromKeyString(keyNameParts.last);
            if (unsupportedKey != null) {
              _logger.printTrace('This key is unsupported: $keyString');
            } else {
              _logger.printTrace('Skipping key: $keyString');
            }
            continue;
          }

          // Parse value
          if (key.type == String) {
            final String value = removeQuotes(fullValueString);
            rootSpecifications[key] = value;

          } else if (key.type == List<String>) {
            final List<String> values = <String>[];
            final String trimmed = fullValueString;
            final List<String> valueParts = <String>[];
            bool inQuotes = false;
            int lastIndex = 0;
            for (int index = 0; index < trimmed.length; index++) {
              final String letter = trimmed[index];
              if (letter == '"' || letter == "'") {
                if (inQuotes == false) {
                  inQuotes = true;
                } else {
                  inQuotes = false;
                }
              }
              if (letter == ',' && inQuotes == false) {
                valueParts.add(trimmed.substring(lastIndex, index));
                lastIndex = index + 1;
              }
              if (index == trimmed.length - 1) {
                valueParts.add(trimmed.substring(lastIndex, index));
              }
            }

            for (String value in valueParts) {
              value = removeQuotes(value.trim());
              if (value != '') {
                values.add(value);
              }
            }
            rootSpecifications[key] = values;
          } else if (key.type == bool) {
            final String value = removeQuotes(fullValueString);
            if (value == 'true') {
              rootSpecifications[key] = true;
            } else {
              rootSpecifications[key] = false;
            }
          } else if (key.type == Map<String, SupportedPlatform>) {
            // TODO: figure out how to priotize `deployment_target` over `platform`
            if (rootSpecifications[key] == null) {
              rootSpecifications[key] = <String, SupportedPlatform>{};
            }
            final SupportedPlatform platform = SupportedPlatform.fromString(keyString, fullValueString);
            rootSpecifications[key][platform.platformName] = platform;
          } else if (key.type == PodspecSpecification.dependency.type) {
            final PodDependency dependency = PodDependency.fromString(_logger, keyString, fullValueString);
            if (rootSpecifications[key] == null) {
              rootSpecifications[key] = <PodDependency>[];
            }
            rootSpecifications[key].add(dependency);
          }

        }
      }
    }

    if (preSpec.isNotEmpty || postSpec.isNotEmpty) {
      _logger.printStatus('There appears to be custom logic in the plugin podspec. Make sure you convert it to Swift manually.');
    }
  }


  List<String> _splitKeyFromValue(String line, String specName) {
    int splitIndex = line.indexOf('=');
    if (splitIndex == -1 && line.startsWith(specName)) {
      splitIndex = line.indexOf(' ');
    }
    if (splitIndex == -1 || splitIndex == line.length -1) {
      return <String> [];
    }
    final String keyString = line.substring(0, splitIndex).trim();
    final String valueString = line.substring(splitIndex + 1).trim();
    return <String> [keyString, valueString];
  }

}

enum UnsupportedPodspecSpecification {
  deprecated,
  infoPlist,
  requiresArc;

  static UnsupportedPodspecSpecification? fromKeyString(String key) {
    switch (key) {
      case 'info_plist':
        return UnsupportedPodspecSpecification.infoPlist;
      case 'requires_arc':
        return UnsupportedPodspecSpecification.requiresArc;
      case 'deprecated':
      case 'deprecated_in_favor_of':
        return UnsupportedPodspecSpecification.deprecated;
    }
    return null;
  }
}

enum PodspecSpecification {
  name(type: String),
  swiftVersions(type: List<String>),
  staticFramework(type: bool),
  platform(type: Map<String, SupportedPlatform>),
  sourceFiles(type: List<String>),
  publicHeaderFiles(type: List<String>),
  moduleMap(type: String),
  dependency(type: List<PodDependency>);

  const PodspecSpecification({
    required this.type,
  });

  final Type type;

  static PodspecSpecification? fromKeyString(String key) {
    switch (key) {
      case 'name':
        return PodspecSpecification.name;
      case 'swift_version':
      case 'swift_versions':
        return PodspecSpecification.swiftVersions;
      case 'static_framework':
        return PodspecSpecification.staticFramework;
      case 'platform':
      case 'deployment_target':
        return PodspecSpecification.platform;
      case 'source_files':
        return PodspecSpecification.sourceFiles;
      case 'public_header_files':
        return PodspecSpecification.publicHeaderFiles;
      case 'dependency':
        return PodspecSpecification.dependency;
      case 'module_map':
        return PodspecSpecification.moduleMap;
    }
    return null;
  }
}

enum PodspecPlatform {
  ios,
  osx,
  tvos,
  watchos;

  static PodspecPlatform? fromString(String key) {
    switch (key) {
      case 'ios':
      case ':ios':
        return PodspecPlatform.ios;
      case 'osx':
      case ':osx':
        return PodspecPlatform.osx;
      case 'tvos':
      case ':tvos':
        return PodspecPlatform.osx;
      case 'watchos':
      case ':watchos':
        return PodspecPlatform.osx;
    }
    return null;
  }
}

class SupportedPlatform {
  SupportedPlatform({
    required this.platformName,
    this.version,
  });

  final String platformName;
  final String? version;

  static SupportedPlatform fromString(String key, String value) {
    if (key == 'platform') {
      final List<String> parts = value.split(',');
      final String name = parts[0].trim().replaceAll(':', '');
      String? version;
      if (parts.length > 1) {
        version = removeQuotes(parts[1].trim());
      }
      return SupportedPlatform(
        platformName: name,
        version: version,
      );
    }
    final List<String> keyParts = key.split('.');
    final String name = keyParts[0].replaceAll(':', '');;
    return SupportedPlatform(
      platformName: name,
      version: removeQuotes(value.trim()),
    );
  }
}

class PodDependency {
  PodDependency({
    required this.name,
    this.platform,
    this.version,
    this.configurations,
  });

  PodDependency.fromString(Logger logger, String key, String value) {
    final List<String> keyParts = key.split('.');
    if (keyParts.length > 2) {
      logger.printTrace('Unable to get configuration');
      name = '';
      return;
    }
    if (keyParts.length == 2) {
      platform = PodspecPlatform.fromString(keyParts[0].trim());
    }


    final String trimmedValue = value.trim();
    // 'AFNetworking', '~> 1.0', :configurations => ['Debug', 'Release']
    int splitIndex = value.indexOf(',');
    if (splitIndex == -1) {
      name = trimmedValue;
      return;
    }
    name = removeQuotes(trimmedValue.substring(0, splitIndex).trim());

    splitIndex = value.indexOf(',', splitIndex + 1);
    if (splitIndex == -1) {
      return;
    }
    final String next = removeQuotes(trimmedValue.substring(splitIndex + 1, splitIndex).trim());
    if (!next.startsWith(':configurations')) {
      version = next;
    }

    splitIndex = value.indexOf(',', splitIndex + 1);
    if (splitIndex == -1) {
      return;
    }
    final String configurationString = removeQuotes(trimmedValue.substring(splitIndex + 1).trim());
    final List<String> parts = configurationString.split('=>');
    if (parts.length != 2) {
      logger.printTrace('Unable to get configuration');
      return;
    }
    final List<String> options = parts[1].trim().replaceAll('[', '').replaceAll(']', '').split(',');
    configurations = <String>[];
    for (final String option in options) {
      configurations!.add(option.trim());
    }
  }



  late final String name;
  PodspecPlatform? platform;
  String? version;
  List<String>? configurations;
}

String removeQuotes(String str) {
  return str.replaceAll("'", '').replaceAll('"', '');
}
