// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:meta/meta.dart';

import '../../artifacts.dart';
import '../../base/common.dart';
import '../../base/file_system.dart';
import '../../build_info.dart';
import '../../flutter_plugins.dart';
import '../../globals.dart' as globals;
import '../../plugins.dart';
import '../../project.dart';
import '../build_system.dart';
import '../exceptions.dart';

/// A target that checks that dev dependencies are enabled on debug/profile
/// builds and disabled on release builds.
///
/// The Flutter tool enables/disables dev dependencies using the build mode.
/// These can get out of sync if the user switches the build mode in Xcode.
///
/// Implementers should override [CheckDevDependencies.inputs] to add a [Source]
/// that changes when dev dependencies status changes.
abstract class CheckDevDependencies extends Target {
  const CheckDevDependencies();

  @override
  List<Target> get dependencies => <Target>[];

  @override
  List<Source> get inputs => <Source>[
    const Source.pattern(
      '{FLUTTER_ROOT}/packages/flutter_tools/lib/src/build_system/targets/darwin.dart',
    ),
    Source.fromProject((FlutterProject project) => project.flutterPluginsDependenciesFile),
  ];

  @override
  List<Source> get outputs => const <Source>[];

  // The command that turns on dev dependencies.
  // Displayed in the error message if dev dependencies are off in a debug build.
  @visibleForOverriding
  String get debugBuildCommand;

  // The command that turns on dev dependencies.
  // Displayed in the error message if dev dependencies are off in a profile build.
  @visibleForOverriding
  String get profileBuildCommand;

  // The command that turns off dev dependencies.
  // Displayed in the error message if dev dependencies are off in a release build.
  @visibleForOverriding
  String get releaseBuildCommand;

  // Check that dev dependencies are enabled on debug or profile builds and
  // disabled on release builds.
  //
  // The Flutter tool enables/disables dev dependencies using the build mode.
  // These can get out of sync if the user switches the build mode in Xcode.
  @override
  Future<void> build(Environment environment) async {
    final String? buildModeEnvironment = environment.defines[kBuildMode];
    if (buildModeEnvironment == null) {
      throw MissingDefineException(kBuildMode, name);
    }
    final BuildMode buildMode = BuildMode.fromCliName(buildModeEnvironment);
    final String? devDependenciesEnabledString = environment.defines[kDevDependenciesEnabled];
    if (devDependenciesEnabledString == null) {
      throw MissingDefineException(kDevDependenciesEnabled, name);
    }

    final bool? devDependenciesEnabled = bool.tryParse(
      environment.defines[kDevDependenciesEnabled] ?? '',
    );
    if (devDependenciesEnabled == null) {
      throw Exception(
        'Unexpected $kDevDependenciesEnabled define value: "$devDependenciesEnabledString"',
      );
    }

    if (devDependenciesEnabled && buildMode.isRelease) {
      // Supress this error if the project has no dev dependencies.
      if (!_hasDevDependencies(environment)) {
        environment.logger.printTrace(
          'Ignoring dev dependencies error as the project has no dev dependencies',
        );
        return;
      }

      _printXcodeError(
        'Release builds should not have Dart dev dependencies enabled\n'
        '\n'
        'This error happens if:\n'
        '\n'
        '1. Your pubspec.yaml has dev dependencies\n'
        '2. Your last Flutter CLI action turned on dev dependencies\n'
        '3. You do a release build in Xcode\n'
        '\n'
        'You can turn off Dart dev dependencies by running this in your Flutter project:\n'
        '\n'
        '  $releaseBuildCommand\n'
        '\n',
      );
      throwToolExit('Dev dependencies enabled in release build');
    } else if (!devDependenciesEnabled && !buildMode.isRelease) {
      // Supress this error if the project has no dev dependencies.
      if (!_hasDevDependencies(environment)) {
        environment.logger.printTrace(
          'Ignoring dev dependencies error as the project has no dev dependencies',
        );
        return;
      }

      final bool profile = buildMode == BuildMode.profile;
      _printXcodeError(
        '${profile ? 'Profile' : 'Debug'} builds require Dart dev dependencies\n'
        '\n'
        'This error happens if:\n'
        '\n'
        '1. Your pubspec.yaml has dev dependencies\n'
        '2. Your last Flutter CLI action turned off dev dependencies\n'
        '3. You do a debug or profile build in Xcode\n'
        '\n'
        'You can turn on Dart dev dependencies by running this in your Flutter project:\n'
        '\n'
        '  ${profile ? profileBuildCommand : debugBuildCommand}\n'
        '\n',
      );
      throwToolExit('Dev dependencies disabled in ${profile ? 'profile' : 'debug'} build');
    }
  }

  // Check if the iOS project has Dart dev dependencies. On error, assumes true.
  bool _hasDevDependencies(Environment environment) {
    // If the app has no plugins, the .flutter-plugins-dependencies file isn't generated.
    final FlutterProject project = FlutterProject.fromDirectory(environment.projectDir);
    final File pluginsFile = project.flutterPluginsDependenciesFile;
    if (!pluginsFile.existsSync()) {
      return false;
    }

    try {
      return flutterPluginsListHasDevDependencies(pluginsFile);
    } on Exception catch (e) {
      environment.logger.printWarning('Unable to parse .flutter-plugins-dependencies file:\n$e');
      return true;
    }
  }

  void _printXcodeError(String message) {
    globals.stdio.stderrWrite('error: $message');
  }
}

abstract class UnpackDarwin extends Target {
  const UnpackDarwin();

  // TODO: SPM - does macOS need too?
  @override
  bool canSkip(Environment environment) =>
      environment.defines[kXcodeBuildScript] == kNativePrepareXcodeBuildScript;

  Future<bool> shouldSkip(Environment environment, XcodeBasedProject xcodeProject) async {
    // buildPhase may be null if this target is not called from a Xcode Build Script.
    // For example, this target is called directly in `flutter build ios-framework`.
    final String? buildPhase = environment.defines[kXcodeBuildScript];
    if (buildPhase == kPrepareXcodeBuildScript) {
      final bool valid = await _validateSwiftPackagePlugins(environment, xcodeProject);
      // If all plugins are valid, they do not rely on the prepare action, so it can be skipped.
      if (valid) {
        return true;
      }
    } else if (xcodeProject.usesSwiftPackageManager) {
      // Skip copying the Flutter framework during the build Run Script if Swift Package Manager is being used.
      // Swift Package Manager now handles the Flutter framework.
      return true;
    }
    return false;
  }

  /// Validates that all Swift Package plugins have a dependency on the Flutter framework.
  /// If they don't, give a warning.
  Future<bool> _validateSwiftPackagePlugins(
    Environment environment,
    XcodeBasedProject xcodeProject,
  ) async {
    bool valid = true;
    bool hasFlutterFrameworkRemoteDependency = false;
    final List<Plugin> plugins = await findPlugins(xcodeProject.parent);
    for (final Plugin plugin in plugins) {
      final String? pluginSwiftPackageManifestPath = plugin.pluginSwiftPackageManifestPath(
        environment.fileSystem,
        'ios',
      );
      if (pluginSwiftPackageManifestPath == null) {
        continue;
      }
      final File swiftManifest = environment.fileSystem.file(pluginSwiftPackageManifestPath);
      if (plugin.platforms['ios'] == null || !swiftManifest.existsSync()) {
        continue;
      }

      // If the plugin has a Package.swift, ensure that it has a dependency on Flutter
      // This check is not perfect and may not catch all cases.
      if (!swiftManifest.readAsStringSync().contains('https://github.com/flutter/flutter')) {
        _printXcodeWarning(
          '${plugin.name} does not have an explicit dependency on Flutter. This will not be supported in a future version of Flutter. Please file an issue with the plugin author to upgrade their plugin Package.swift.',
        );
        valid = false;
      } else {
        hasFlutterFrameworkRemoteDependency = true;
      }
    }

    // TODO: SPM - macos
    // TODO: error?
    if (xcodeProject.flutterFrameworkSwiftPackageInProjectSettings &&
        hasFlutterFrameworkRemoteDependency) {
      _printXcodeWarning(
        'You project is missing settings. Please run "flutter build ios --config-only".',
      );
    }
    return valid;
  }

  Future<void> copyFramework(
    Environment environment, {
    EnvironmentType? environmentType,
    required TargetPlatform targetPlatform,
    required BuildMode buildMode,
  }) async {
    // Copy Flutter framework.
    final String basePath = environment.artifacts.getArtifactPath(
      targetPlatform == TargetPlatform.ios
          ? Artifact.flutterFramework
          : Artifact.flutterMacOSFramework,
      platform: targetPlatform,
      mode: buildMode,
      environmentType: environmentType,
    );

    final ProcessResult result = await environment.processManager.run(<String>[
      'rsync',
      '-av',
      '--delete',
      '--filter',
      '- .DS_Store/',
      '--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r',
      basePath,
      environment.outputDir.path,
    ]);
    if (result.exitCode != 0) {
      throw Exception(
        'Failed to copy framework (exit ${result.exitCode}:\n'
        '${result.stdout}\n---\n${result.stderr}',
      );
    }
  }

  /// Destructively thin Flutter.framework to include only the specified architectures.
  Future<void> thinFramework(
    Environment environment,
    String frameworkBinaryPath,
    String archs,
  ) async {
    final List<String> archList = archs.split(' ').toList();
    final ProcessResult infoResult = await environment.processManager.run(<String>[
      'lipo',
      '-info',
      frameworkBinaryPath,
    ]);
    final String lipoInfo = infoResult.stdout as String;

    final ProcessResult verifyResult = await environment.processManager.run(<String>[
      'lipo',
      frameworkBinaryPath,
      '-verify_arch',
      ...archList,
    ]);

    if (verifyResult.exitCode != 0) {
      throw Exception(
        'Binary $frameworkBinaryPath does not contain architectures "$archs".\n'
        '\n'
        'lipo -info:\n'
        '$lipoInfo',
      );
    }

    // Skip thinning for non-fat executables.
    if (lipoInfo.startsWith('Non-fat file:')) {
      environment.logger.printTrace('Skipping lipo for non-fat file $frameworkBinaryPath');
      return;
    }

    // Thin in-place.
    final ProcessResult extractResult = await environment.processManager.run(<String>[
      'lipo',
      '-output',
      frameworkBinaryPath,
      for (final String arch in archList) ...<String>['-extract', arch],
      ...<String>[frameworkBinaryPath],
    ]);

    if (extractResult.exitCode != 0) {
      throw Exception(
        'Failed to extract architectures "$archs" for $frameworkBinaryPath.\n'
        '\n'
        'stderr:\n'
        '${extractResult.stderr}\n\n'
        'lipo -info:\n'
        '$lipoInfo',
      );
    }
  }

  void _printXcodeWarning(String message) {
    globals.stdio.stderrWrite('warning: $message');
  }
}
