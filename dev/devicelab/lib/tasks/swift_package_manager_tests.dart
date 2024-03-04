// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../framework/devices.dart';
import '../framework/framework.dart';
import '../framework/host_agent.dart';
import '../framework/ios.dart';
import '../framework/task_result.dart';
import '../framework/utils.dart';

/// This test ensure Cocoapods and Swift Package Manager work independently and together.
TaskFunction createSwiftPackageManagerTest({
  required String platform,
  String? deviceIdOverride,
}) {
  return () async {
    if (platform != 'ios' && platform != 'macos') {
      return TaskResult.failure('Invalid platform: $platform. Swift Package Manager is only compatible with ios and macos.');
    }
    if (deviceIdOverride == null) {
      final Device device = await devices.workingDevice;
      await device.unlock();
      deviceIdOverride = device.deviceId;
    }

    // final Directory tempDir = Directory.systemTemp.createTempSync('swift_package_manager_projects.');
    final Directory tempDir = Directory('/Users/vashworth/Development/experiment/flutter/spm_tests')..createSync();
    try {
      await inDirectory(tempDir, () async {
        final List<String> iosLanguages = <String>[
          if (platform == 'ios') 'objc',
          'swift',
        ];
        for (final String iosLanguage in iosLanguages) {
          // Swift Package Manager must be disabled before proceeding because we create a plugin and app using default templates.
          await disableSwiftPackageManager(canFail: false);

          final List<_TimingMeasurements> times = <_TimingMeasurements>[];

          // Create a plugin with CocoaPods template
          final _CreatedPlugin createdCocoaPodsPlugin = await _createPlugin(
            platform: platform,
            iosLanguage: iosLanguage,
            tempDir: tempDir,
            times: times,
          );
          // Build CocoaPods plugin example app
          await _buildApp(
            appTitle: '${createdCocoaPodsPlugin.pluginName}_example',
            options: <String>[platform, '--debug', '-v'],
            workingDirectory: createdCocoaPodsPlugin.exampleAppPath,
            expectedLines: _expectedLines(platform: platform, appDirectoryPath: createdCocoaPodsPlugin.exampleAppPath, cococapodsPlugin: createdCocoaPodsPlugin),
            unexpectedLines: _unexpectedLines(platform: platform, appDirectoryPath: createdCocoaPodsPlugin.exampleAppPath, cococapodsPlugin: createdCocoaPodsPlugin),
            times: times,
          );
          // Test CocoaPods plugin example app
          await _testApp(
            plugin: createdCocoaPodsPlugin,
            deviceId: deviceIdOverride!,
            times: times,
          );

          // Create a flutter app with default template (aka no CocoaPods or SPM integration yet).
          final String defaultAppName = await _createApp(
            iosLanguage: iosLanguage,
            platform: platform,
            times: times,
          );
          final String defaultAppPath = path.join(tempDir.path, defaultAppName);
          // Add CocoaPods plugin as a dependency and build app
          _addDependency(appDirectoryPath: defaultAppPath, plugin: createdCocoaPodsPlugin);
          await _buildApp(
            appTitle: defaultAppName,
            options: <String>[platform, '--debug', '-v'],
            workingDirectory: defaultAppPath,
            expectedLines: _expectedLines(platform: platform, appDirectoryPath: defaultAppPath, cococapodsPlugin: createdCocoaPodsPlugin),
            unexpectedLines: _unexpectedLines(platform: platform, appDirectoryPath: defaultAppPath, cococapodsPlugin: createdCocoaPodsPlugin),
            times: times,
          );

          await enableSwiftPackageManager(canFail: false);

          // Create a plugin with Swift Package Manager template
          final _CreatedPlugin createdSwiftPackagePlugin = await _createPlugin(
            platform: platform,
            iosLanguage: iosLanguage,
            usingSwiftPackageManager: true,
            tempDir: tempDir,
            times: times,
          );
          // Build Swift Package Manager plugin example app
          await _buildApp(
            appTitle: '${createdSwiftPackagePlugin.pluginName}_example',
            options: <String>[platform, '--debug', '-v'],
            workingDirectory: createdSwiftPackagePlugin.exampleAppPath,
            expectedLines: _expectedLines(platform: platform, appDirectoryPath: createdSwiftPackagePlugin.exampleAppPath, swiftPackagePlugin: createdSwiftPackagePlugin, swiftPackageMangerEnabled: true),
            unexpectedLines: _unexpectedLines(platform: platform, appDirectoryPath: createdSwiftPackagePlugin.exampleAppPath, swiftPackagePlugin: createdSwiftPackagePlugin, swiftPackageMangerEnabled: true),
            times: times,
          );
          // Test Swift Package Manager plugin example app
          await _testApp(
            plugin: createdSwiftPackagePlugin,
            deviceId: deviceIdOverride!,
            times: times,
          );

          // Create a flutter app with Swift Package Manager template
          final String swiftPackageManagerAppName = await _createApp(
            iosLanguage: iosLanguage,
            platform: platform,
            times: times,
            usingSwiftPackageManager: true,
          );
          final String swiftPackageManagerAppPath = path.join(tempDir.path, swiftPackageManagerAppName);
          // Add Swift Package Manager plugin as a dependency and build app
          _addDependency(appDirectoryPath: swiftPackageManagerAppPath, plugin: createdSwiftPackagePlugin);
          await _buildApp(
            appTitle: swiftPackageManagerAppName,
            options: <String>[platform, '--debug', '-v'],
            workingDirectory: swiftPackageManagerAppPath,
            expectedLines: _expectedLines(platform: platform, appDirectoryPath: swiftPackageManagerAppPath, swiftPackagePlugin: createdSwiftPackagePlugin, swiftPackageMangerEnabled: true),
            unexpectedLines: _unexpectedLines(platform: platform, appDirectoryPath: swiftPackageManagerAppPath, swiftPackagePlugin: createdSwiftPackagePlugin, swiftPackageMangerEnabled: true),
            times: times,
          );

          // Migrate an app built with default template to use Swift Package Manager
          section('Clean project');
          await flutter('clean', workingDirectory: defaultAppPath);
          _addDependency(appDirectoryPath: defaultAppPath, plugin: createdSwiftPackagePlugin);
          await _buildApp(
            appTitle: 'default_app_with_mixed_dependencies_and_spm_enabled',
            options: <String>[platform, '--debug', '-v'],
            workingDirectory: defaultAppPath,
            expectedLines: _expectedLines(platform: platform, appDirectoryPath: defaultAppPath, cococapodsPlugin: createdCocoaPodsPlugin, swiftPackagePlugin: createdSwiftPackagePlugin, swiftPackageMangerEnabled: true),
            unexpectedLines: _unexpectedLines(platform: platform, appDirectoryPath: defaultAppPath, cococapodsPlugin: createdCocoaPodsPlugin, swiftPackagePlugin: createdSwiftPackagePlugin, swiftPackageMangerEnabled: true),
            times: times,
          );

          // Build app again but with Swift Package Manager disabled by config
          await disableSwiftPackageManager(canFail: false);

          section('Clean project');
          await flutter('clean', workingDirectory: defaultAppPath);
          await _buildApp(
            appTitle: 'default_app_with_mixed_dependencies_and_spm_disabled_by_config',
            options: <String>[platform, '--debug', '-v'],
            workingDirectory: defaultAppPath,
            expectedLines: _expectedLines(platform: platform, appDirectoryPath: defaultAppPath, cococapodsPlugin: createdCocoaPodsPlugin, swiftPackagePlugin: createdSwiftPackagePlugin),
            unexpectedLines: _unexpectedLines(platform: platform, appDirectoryPath: defaultAppPath, cococapodsPlugin: createdCocoaPodsPlugin, swiftPackagePlugin: createdSwiftPackagePlugin),
            times: times,
          );

          // Build app again but with Swift Package Manager enabled
          await enableSwiftPackageManager(canFail: false);

          section('Clean project');
          await flutter('clean', workingDirectory: defaultAppPath);
          await _buildApp(
            appTitle: 'default_app_with_mixed_dependencies_and_spm_enabled_2',
            options: <String>[platform, '--debug', '-v'],
            workingDirectory: defaultAppPath,
            expectedLines: _expectedLines(platform: platform, appDirectoryPath: defaultAppPath, cococapodsPlugin: createdCocoaPodsPlugin, swiftPackagePlugin: createdSwiftPackagePlugin, swiftPackageMangerEnabled: true),
            unexpectedLines: _unexpectedLines(platform: platform, appDirectoryPath: defaultAppPath, cococapodsPlugin: createdCocoaPodsPlugin, swiftPackagePlugin: createdSwiftPackagePlugin, swiftPackageMangerEnabled: true),
            times: times,
          );

          // Build app again but with Swift Package Manager disabled by pubspec
          _disableSwiftPackageManagerByPubspec(appDirectoryPath: defaultAppPath);
          section('Clean project');
          await flutter('clean', workingDirectory: defaultAppPath);
          await _buildApp(
            appTitle: 'default_app_with_mixed_dependencies_and_spm_disabled_by_pubspec',
            options: <String>[platform, '--debug', '-v'],
            workingDirectory: defaultAppPath,
            expectedLines: _expectedLines(platform: platform, appDirectoryPath: defaultAppPath, cococapodsPlugin: createdCocoaPodsPlugin, swiftPackagePlugin: createdSwiftPackagePlugin),
            unexpectedLines: _unexpectedLines(platform: platform, appDirectoryPath: defaultAppPath, cococapodsPlugin: createdCocoaPodsPlugin, swiftPackagePlugin: createdSwiftPackagePlugin),
            times: times,
          );

          section('Display time measurements');
          int total = 0;
          for (final _TimingMeasurements measurement in times) {
            total = total + measurement.timeElapsed;
            print('${platform}_${measurement.key}: ${measurement.timeElapsed}');
          }
          print('Total for $platform $iosLanguage: $total');
          /*

ios_create_ios_swift_cocoapods_plugin: 1031
ios_build_ios_swift_cocoapods_plugin_example: 17888
ios_test_ios_swift_cocoapods_plugin: 24348
ios_create_ios_swift_default_app: 915
ios_build_ios_swift_default_app: 14301
ios_create_ios_swift_spm_plugin: 1186
ios_build_ios_swift_spm_plugin_example: 18490
ios_test_ios_swift_spm_plugin: 24988
ios_create_ios_swift_spm_app: 1964
ios_build_ios_swift_spm_app: 14705
ios_build_default_app_with_mixed_dependencies_and_spm_enabled: 17107
ios_build_default_app_with_mixed_dependencies_and_spm_disabled_by_config: 15278
ios_build_default_app_with_mixed_dependencies_and_spm_enabled_2: 15329
ios_build_default_app_with_mixed_dependencies_and_spm_disabled_by_pubspec: 15517
Total for ios swift: 183047

macos_create_macos_swift_cocoapods_plugin: 978
macos_build_macos_swift_cocoapods_plugin_example: 19622
macos_test_macos_swift_cocoapods_plugin: 40244
macos_create_macos_swift_default_app: 800
macos_build_macos_swift_default_app: 19480
macos_create_macos_swift_spm_plugin: 1892
macos_build_macos_swift_spm_plugin_example: 11560
macos_test_macos_swift_spm_plugin: 40290
macos_create_macos_swift_spm_app: 1228
macos_build_macos_swift_spm_app: 13018
macos_build_default_app_with_mixed_dependencies_and_spm_enabled: 19887
macos_build_default_app_with_mixed_dependencies_and_spm_disabled_by_config: 19900
macos_build_default_app_with_mixed_dependencies_and_spm_enabled_2: 19077
macos_build_default_app_with_mixed_dependencies_and_spm_disabled_by_pubspec: 19464
Total for macos swift: 227440
          */


        }
      });

      // final Map<String, dynamic> metrics = <String, dynamic>{
      //   ...compileInitialRelease,
      //   ...compileFullRelease,
      //   ...compileInitialDebug,
      //   ...compileFullDebug,
      //   ...compileSecondDebug,
      // };
      // return TaskResult.success(metrics, benchmarkScoreKeys: metrics.keys.toList());

      print('success');
      return TaskResult.success(null);

    } on TaskResult catch (taskResult) {
      print(taskResult);
      return taskResult;
    } catch (e) {
      print(e);
      return TaskResult.failure(e.toString());
    } finally {
      await disableSwiftPackageManager();
      // rmTree(tempDir);
    }
  };
}

Future<_CreatedPlugin> _createPlugin({
  required Directory tempDir,
  required String platform,
  required String iosLanguage,
  bool usingSwiftPackageManager = false,
  required List<_TimingMeasurements> times,
}) async {
  final String dependencyManager = usingSwiftPackageManager ? 'spm' : 'cocoapods';

  // Create plugin
  final String pluginName = '${platform}_${iosLanguage}_${dependencyManager}_plugin';
  section('Create an $platform $iosLanguage $dependencyManager plugin');

  final _TimingMeasurements createTime = await _TimingMeasurements.measure('create_$pluginName', () async {
    await flutter(
      'create',
      options: <String>['--org', 'io.flutter.devicelab', '--template=plugin', '--platforms=$platform', '-i', iosLanguage, pluginName],
    );
  });
  times.add(createTime);

  final Directory pluginDirectory = Directory(path.join(tempDir.path, pluginName));

  return _CreatedPlugin(pluginName: pluginName, pluginPath: pluginDirectory.path, platform: platform);
}

Future<void> _testApp({
  required _CreatedPlugin plugin,
  required String deviceId,
  required List<_TimingMeasurements> times,
}) async {
  section('Test ${plugin.pluginName} example app');
  final String resultBundleTemp = Directory.systemTemp.createTempSync('flutter_module_test_ios_xcresult.').path;
  final String resultBundlePath = path.join(resultBundleTemp, 'result');
  int? testResultExit;
  final _TimingMeasurements testTime = await _TimingMeasurements.measure('test_${plugin.pluginName}', () async {
    testResultExit = await exec(
      'xcodebuild',
      <String>[
        '-workspace',
        'Runner.xcworkspace',
        '-scheme',
        'Runner',
        '-configuration',
        'Debug',
        '-destination',
        'id=$deviceId',
        '-resultBundlePath',
        resultBundlePath,
        'test',
        'COMPILER_INDEX_STORE_ENABLE=NO',
      ],
      workingDirectory: plugin.exampleAppPlatformPath,
      canFail: true,
    );
  });
  times.add(testTime);

  if (testResultExit != 0) {
    final Directory? dumpDirectory = hostAgent.dumpDirectory;
    if (dumpDirectory != null) {
      // Zip the test results to the artifacts directory for upload.
      await inDirectory(resultBundleTemp, () {
        final String zipPath = path.join(dumpDirectory.path,
            'swift_package_manager_test_${plugin.pluginName}-${DateTime.now().toLocal().toIso8601String()}.zip');
        return exec(
          'zip',
          <String>[
            '-r',
            '-9',
            '-q',
            zipPath,
            'result.xcresult',
          ],
          canFail: true, // Best effort to get the logs.
        );
      });
    }
    throw TaskResult.failure('Platform unit tests failed');
  }
}

List<String> _expectedLines({
  required String platform,
  required String appDirectoryPath,
  _CreatedPlugin? cococapodsPlugin,
  _CreatedPlugin? swiftPackagePlugin,
  bool swiftPackageMangerEnabled = false,
}) {
  final String frameworkName = platform == 'ios' ? 'Flutter' : 'FlutterMacOS';
  final String appPlatformDirectoryPath = path.join(appDirectoryPath, platform);

  final List<String> expectedLines = <String>[];
  if (swiftPackageMangerEnabled) {
    expectedLines.addAll(<String>[
      'FlutterPackage: $appPlatformDirectoryPath/Flutter/Packages/FlutterPackage',
      "➜ Explicit dependency on target 'FlutterPackage' in project 'FlutterPackage'",
    ]);
  }
  if (swiftPackagePlugin != null) {
    // If using a Swift Package plugin, but Swift Package Manager is not enabled, it falls back to being used as a Cocoapods plugin.
    if (swiftPackageMangerEnabled) {
      expectedLines.addAll(<String>[
        '${swiftPackagePlugin.pluginName}: ${swiftPackagePlugin.pluginPath}/$platform/${swiftPackagePlugin.pluginName} @ local',
        "➜ Explicit dependency on target '${swiftPackagePlugin.pluginName}' in project '${swiftPackagePlugin.pluginName}'",
        if (platform == 'macos')
          'ProcessXCFramework $appPlatformDirectoryPath/Flutter/Packages/FlutterPackage/FlutterMacOS.xcframework $appDirectoryPath/build/macos/Build/Products/Debug/FlutterMacOS.framework macos',
        if (platform == 'ios')
          'ProcessXCFramework $appPlatformDirectoryPath/Flutter/Packages/FlutterPackage/Flutter.xcframework $appDirectoryPath/build/ios/Debug-iphoneos/Flutter.framework ios',
      ]);
    } else {
      expectedLines.addAll(<String>[
        '-> Installing ${swiftPackagePlugin.pluginName} (0.0.1)',
        "➜ Explicit dependency on target '${swiftPackagePlugin.pluginName}' in project 'Pods'",
      ]);
    }
  }
  if (cococapodsPlugin != null) {
    expectedLines.addAll(<String>[
      'Running pod install...',
      '-> Installing $frameworkName (1.0.0)',
      '-> Installing ${cococapodsPlugin.pluginName} (0.0.1)',
      "Target 'Pods-Runner' in project 'Pods'",
      "➜ Explicit dependency on target '$frameworkName' in project 'Pods'",
      "➜ Explicit dependency on target '${cococapodsPlugin.pluginName}' in project 'Pods'",
    ]);
  }
  return expectedLines;
}

List<String> _unexpectedLines({
  required String platform,
  required String appDirectoryPath,
  _CreatedPlugin? cococapodsPlugin,
  _CreatedPlugin? swiftPackagePlugin,
  bool swiftPackageMangerEnabled = false,
}) {
  final String frameworkName = platform == 'ios' ? 'Flutter' : 'FlutterMacOS';
  final String appPlatformDirectoryPath = path.join(appDirectoryPath, platform);
  final List<String> unexpectedLines = <String>[];
  if (cococapodsPlugin == null) {
    unexpectedLines.addAll(<String>[
      'Running pod install...',
      '-> Installing $frameworkName (1.0.0)',
      "Target 'Pods-Runner' in project 'Pods'",
    ]);
  }
  if (swiftPackagePlugin != null) {
    if (swiftPackageMangerEnabled) {
      unexpectedLines.addAll(<String>[
        '-> Installing ${swiftPackagePlugin.pluginName} (0.0.1)',
        "➜ Explicit dependency on target '${swiftPackagePlugin.pluginName}' in project 'Pods'",
      ]);
    } else {
      unexpectedLines.addAll(<String>[
        '${swiftPackagePlugin.pluginName}: ${swiftPackagePlugin.pluginPath}/$platform/${swiftPackagePlugin.pluginName} @ local',
        "➜ Explicit dependency on target '${swiftPackagePlugin.pluginName}' in project '${swiftPackagePlugin.pluginName}'",
        if (platform == 'macos')
          'ProcessXCFramework $appPlatformDirectoryPath/Flutter/Packages/FlutterPackage/FlutterMacOS.xcframework $appDirectoryPath/build/macos/Build/Products/Debug/FlutterMacOS.framework macos',
        if (platform == 'ios')
          'ProcessXCFramework $appPlatformDirectoryPath/Flutter/Packages/FlutterPackage/Flutter.xcframework $appDirectoryPath/build/ios/Debug-iphoneos/Flutter.framework ios',
      ]);
    }
  }
  return unexpectedLines;
}

Future<String> _createApp({
  required String platform,
  required String iosLanguage,
  bool usingSwiftPackageManager = false,
  required List<_TimingMeasurements> times,
}) async {
  final String appTemplateType = usingSwiftPackageManager ? 'spm' : 'default';

  section('Create an $platform $iosLanguage app with $appTemplateType template');

  final String appName = '${platform}_${iosLanguage}_${appTemplateType}_app';
  final _TimingMeasurements createTime = await _TimingMeasurements.measure('create_$appName', () async {
    await flutter(
      'create',
      options: <String>['--org', 'io.flutter.devicelab', '--platforms=$platform', '-i', iosLanguage, appName],
    );
  });
  times.add(createTime);

  return appName;
}

void _addDependency({
  required _CreatedPlugin plugin,
  required String appDirectoryPath,
}) {
  section('Add ${plugin.pluginName} as a plugin dependency');
  final File pubspec = File(path.join(appDirectoryPath, 'pubspec.yaml'));
  final String pubspecContent = pubspec.readAsStringSync();
  pubspec.writeAsStringSync(
    pubspecContent.replaceFirst(
      '\ndependencies:\n',
      '\ndependencies:\n  ${plugin.pluginName}:\n    path: ${plugin.pluginPath}\n',
    ),
  );
}

void _disableSwiftPackageManagerByPubspec({
  required String appDirectoryPath,
}) {
  section('Disable Swift Package Manager via pubspec');
  final File pubspec = File(path.join(appDirectoryPath, 'pubspec.yaml'));
  final String pubspecContent = pubspec.readAsStringSync();
  pubspec.writeAsStringSync(
    pubspecContent.replaceFirst(
      '\n# The following section is specific to Flutter packages.\nflutter:\n',
      '\n# The following section is specific to Flutter packages.\nflutter:\n  disable-swift-package-manager: true',
    ),
  );
}

final String _flutterBin = path.join(flutterDirectory.path, 'bin', 'flutter');

Future<void> enableSwiftPackageManager({bool canFail = true}) async {
  section('Enable Swift Package Manager');
  final int configResult = await exec(
    _flutterBin,
    <String>[
      'config',
      '-v',
      '--enable-swift-package-manager',
    ],
    canFail: canFail,
  );
  if (configResult != 0) {
    print('Failed to enable configuration, tasks may not run.');
  }
}

Future<void> disableSwiftPackageManager({bool canFail = true}) async {
  section('Disable Swift Package Manager');
  final int configResult = await exec(
    _flutterBin,
    <String>[
      'config',
      '-v',
      '--no-enable-swift-package-manager',
    ],
    canFail: canFail,
  );
  if (configResult != 0) {
    print('Failed to disable configuration.');
  }
}

Future<void> _buildApp({
  required String appTitle,
  required List<String> options,
  required String workingDirectory,
  List<String>? expectedLines,
  List<String>? unexpectedLines,
  required List<_TimingMeasurements> times,
}) async {
  section('Build $appTitle');

  final List<String> remainingExpectedLines = expectedLines ?? <String>[];
  final List<String> unexpectedLinesFound = <String>[];

  final Process run = await startFlutter(
    'build',
    options: options,
    workingDirectory: workingDirectory,
  );
  run.stdout
    .transform<String>(utf8.decoder)
    .transform<String>(const LineSplitter())
    .listen((String line) {
      print('run:stdout: $line');

      // Remove "[   +3 ms] " prefix
      String trimmedLine = line.trim();
      if (trimmedLine.startsWith('[')) {
        final int prefixEndIndex = trimmedLine.indexOf(']');
        if (prefixEndIndex > 0) {
          trimmedLine = trimmedLine.substring(prefixEndIndex + 1, trimmedLine.length).trim();
        }
      }
      remainingExpectedLines.remove(trimmedLine);
      if (unexpectedLines != null && unexpectedLines.contains(trimmedLine)) {
        unexpectedLinesFound.add(trimmedLine);
      }
  });
  run.stderr
    .transform<String>(utf8.decoder)
    .transform<String>(const LineSplitter())
    .listen((String line) => print('run:stderr: $line'));

  int? result;
  final _TimingMeasurements createTime = await _TimingMeasurements.measure('build_$appTitle', () async {
    result = await run.exitCode;
  });
  times.add(createTime);

  if (result != 0) {
    throw 'Failed to run test app; runner unexpected exited, with exit code $result.';
  }
  if (remainingExpectedLines.isNotEmpty) {
    throw 'Did not find expected lines: $remainingExpectedLines';
  }
  if (unexpectedLinesFound.isNotEmpty) {
    throw 'Found unexpected lines: $unexpectedLinesFound';
  }
}

class _CreatedPlugin {
  _CreatedPlugin({required this.pluginName, required this.pluginPath, required this.platform});

  final String pluginName;
  final String pluginPath;
  final String platform;
  String get exampleAppPath => path.join(pluginPath, 'example');
  String get exampleAppPlatformPath => path.join(exampleAppPath, platform);
}


class _TimingMeasurements {
  _TimingMeasurements(this.key, this.timeElapsed);

  final String key;
  final int timeElapsed;


  static Future<_TimingMeasurements> measure(String key, Function func) async {
    final Stopwatch watch = Stopwatch();
    watch.start();
    await func();
    watch.stop();
    return _TimingMeasurements(key, watch.elapsedMilliseconds);
  }
}
