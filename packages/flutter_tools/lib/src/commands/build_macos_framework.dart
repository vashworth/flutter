// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:meta/meta.dart';

import '../artifacts.dart';
import '../base/common.dart';
import '../base/error_handling_io.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/process.dart';
import '../base/utils.dart';
import '../build_info.dart';
import '../build_system/build_system.dart';
import '../build_system/targets/macos.dart';
import '../cache.dart';
import '../flutter_plugins.dart';
import '../globals.dart' as globals;
import '../macos/cocoapod_utils.dart';
import '../macos/swift_packages.dart';
import '../plugins.dart';
import '../project.dart';
import '../runner/flutter_command.dart' show DevelopmentArtifact, FlutterCommandResult;
import '../version.dart';
import 'build_darwin_framework.dart';

/// Produces a .framework for integration into a host macOS app. The .framework
/// contains the Flutter engine and framework code as well as plugins. It can
/// be integrated into plain Xcode projects without using or other package
/// managers.
class BuildMacOSFrameworkCommand extends BuildFrameworkCommand {
  BuildMacOSFrameworkCommand({
    super.flutterVersion,
    required super.buildSystem,
    required super.verboseHelp,
    required super.logger,
    super.cache,
    super.platform,
  });

  @override
  final String name = 'macos-framework';

  @override
  final String description = 'Produces .xcframeworks for a Flutter project '
      'and its plugins for integration into existing, plain macOS Xcode projects.\n'
      'This can only be run on macOS hosts.';

  @override
  Future<Set<DevelopmentArtifact>> get requiredArtifacts async => const <DevelopmentArtifact>{
    DevelopmentArtifact.macOS,
  };

  @override
  Future<FlutterCommandResult> runCommand() async {
    final String outputArgument = stringArg('output') ??
        globals.fs.path.join(
          globals.fs.currentDirectory.path,
          'build',
          'macos',
          'framework',
        );

    if (outputArgument.isEmpty) {
      throwToolExit('--output is required.');
    }

    if (!project.macos.existsSync()) {
      throwToolExit('Project does not support macOS');
    }

    final Directory outputDirectory =
        globals.fs.directory(globals.fs.path.absolute(globals.fs.path.normalize(outputArgument)));

    final List<BuildInfo> buildInfos = await getBuildInfos();
    displayNullSafetyMode(buildInfos.first);

    ErrorHandlingFileSystem.deleteIfExists(
      outputDirectory.childDirectory('FlutterPluginRegistrant'),
      recursive: true,
    );

    for (final BuildInfo buildInfo in buildInfos) {
      globals.printStatus('Building macOS frameworks in ${buildInfo.mode.cliName} mode...');
      final String xcodeBuildConfiguration = sentenceCase(buildInfo.mode.cliName);
      final Directory modeDirectory = outputDirectory.childDirectory(xcodeBuildConfiguration);

      ErrorHandlingFileSystem.deleteIfExists(modeDirectory, recursive: true);

      final Directory flutterFrameworksDir;
      final Directory cocoaPodFrameworksDir;
      if (project.usesSwiftPackageManager) {
        flutterFrameworksDir = modeDirectory.childDirectory('FlutterFrameworks');
        cocoaPodFrameworksDir = modeDirectory.childDirectory('CocoaPodFrameworks');
      } else {
        flutterFrameworksDir = modeDirectory;
        cocoaPodFrameworksDir = modeDirectory;
      }

      if (!remoteFlutterFramework) {
        // Copy FlutterMacOS.xcframework.
        await _produceFlutterFramework(buildInfo, flutterFrameworksDir);
      } else if (!project.usesSwiftPackageManager) {
        produceFlutterPodspec(buildInfo.mode, modeDirectory, force: boolArg('force'));
      }

      final Directory buildOutput = modeDirectory.childDirectory('macos');

      // Build aot, create App.framework. Make XCFrameworks.
      await _produceAppFramework(buildInfo, flutterFrameworksDir, buildOutput);

      // Build and copy plugins.
      await processPodsIfNeeded(
        project.macos,
        getMacOSBuildDirectory(),
        buildInfo.mode,
        forceCocoaPodsOnly: true,
      );
      if (boolArg('plugins') && hasPlugins(project)) {
        await _producePlugins(xcodeBuildConfiguration, buildOutput, cocoaPodFrameworksDir);
        await produceSwiftPackages(
          platform: SupportedPlatform.macos,
          project: project,
          cocoaPodFrameworksDir: cocoaPodFrameworksDir,
          flutterFrameworksDir: flutterFrameworksDir,
          modeDirectory: modeDirectory,
          mode: buildInfo.mode,
          modeName: xcodeBuildConfiguration,
          useRemoteFlutterFramework: remoteFlutterFramework,
          fileSystem: globals.fs,
        );
      }

      globals.logger.printStatus(' └─Moving to ${globals.fs.path.relative(modeDirectory.path)}');

      // Copy the native assets.
      final Directory nativeAssetsDirectory = globals.fs
          .directory(getBuildDirectory())
          .childDirectory('native_assets/macos/');
      if (await nativeAssetsDirectory.exists()) {
        final ProcessResult rsyncResult = await globals.processManager.run(<Object>[
          'rsync',
          '-av',
          '--filter',
          '- .DS_Store',
          '--filter',
          '- native_assets.yaml',
          nativeAssetsDirectory.path,
          modeDirectory.path,
        ]);
        if (rsyncResult.exitCode != 0) {
          throwToolExit('Failed to copy native assets:\n${rsyncResult.stderr}');
        }
      }

      // Delete the intermediaries since they would have been copied into our
      // output frameworks.
      if (buildOutput.existsSync()) {
        buildOutput.deleteSync(recursive: true);
      }
    }

    // TODO(vashworth): If using SPM, change this message to guide them to add Swift Package to project
    globals.printStatus('Frameworks written to ${outputDirectory.path}.');

    final File pluginRegistrantImplementation = project.macos.pluginRegistrantImplementation;
    if (hasPlugins(project) && !project.usesSwiftPackageManager) {
      // Apps do not generate a FlutterPluginRegistrant.framework. Users will need
      // to copy GeneratedPluginRegistrant.swift to their project manually.
      pluginRegistrantImplementation.copySync(outputDirectory.childFile(pluginRegistrantImplementation.basename).path);
      globals.printStatus('\nCopy ${globals.fs.path.basename(pluginRegistrantImplementation.path)} into your project.');
    } else {
      ErrorHandlingFileSystem.deleteIfExists(
        outputDirectory.childFile(pluginRegistrantImplementation.basename),
      );
    }

    return FlutterCommandResult.success();
  }

  /// Create podspec that will download and unzip remote engine assets so host apps can leverage CocoaPods
  /// vendored framework caching.
  @visibleForTesting
  void produceFlutterPodspec(BuildMode mode, Directory modeDirectory, {bool force = false}) {
    final Status status = globals.logger.startProgress(' ├─Creating FlutterMacOS.podspec...');
    try {
      final GitTagVersion gitTagVersion = flutterVersion.gitTagVersion;
      if (!force &&
          (gitTagVersion.x == null ||
              gitTagVersion.y == null ||
              gitTagVersion.z == null ||
              gitTagVersion.commits != 0)) {
        throwToolExit(
            '--cocoapods is only supported on the beta or stable channel. Detected version is ${flutterVersion.frameworkVersion}');
      }

      // Podspecs use semantic versioning, which don't support hotfixes.
      // Fake out a semantic version with major.minor.(patch * 100) + hotfix.
      // A real increasing version is required to prompt CocoaPods to fetch
      // new artifacts when the source URL changes.
      final int minorHotfixVersion = (gitTagVersion.z ?? 0) * 100 + (gitTagVersion.hotfix ?? 0);

      final File license = cache.getLicenseFile();
      if (!license.existsSync()) {
        throwToolExit('Could not find license at ${license.path}');
      }
      final String licenseSource = license.readAsStringSync();
      final String artifactsMode = mode == BuildMode.debug ? 'darwin-x64' : 'darwin-x64-${mode.cliName}';

      final String podspecContents = '''
Pod::Spec.new do |s|
  s.name                  = 'FlutterMacOS'
  s.version               = '${gitTagVersion.x}.${gitTagVersion.y}.$minorHotfixVersion' # ${flutterVersion.frameworkVersion}
  s.summary               = 'A UI toolkit for beautiful and fast apps.'
  s.description           = <<-DESC
Flutter is Google's UI toolkit for building beautiful, fast apps for mobile, web, desktop, and embedded devices from a single codebase.
This pod vends the macOS Flutter engine framework. It is compatible with application frameworks created with this version of the engine and tools.
The pod version matches Flutter version major.minor.(patch * 100) + hotfix.
DESC
  s.homepage              = 'https://flutter.dev'
  s.license               = { :type => 'BSD', :text => <<-LICENSE
$licenseSource
LICENSE
  }
  s.author                = { 'Flutter Dev Team' => 'flutter-dev@googlegroups.com' }
  s.source                = { :http => '${cache.storageBaseUrl}/flutter_infra_release/flutter/${cache.engineRevision}/$artifactsMode/framework.zip' }
  s.documentation_url     = 'https://flutter.dev/docs'
  s.osx.deployment_target = '10.14'
  s.vendored_frameworks   = 'FlutterMacOS.xcframework'
end
''';

      final File podspec = modeDirectory.childFile('FlutterMacOS.podspec')..createSync(recursive: true);
      podspec.writeAsStringSync(podspecContents);
    } finally {
      status.stop();
    }
  }

  Future<void> _produceAppFramework(
    BuildInfo buildInfo,
    Directory outputBuildDirectory,
    Directory macosBuildOutput,
  ) async {
    final Status status = globals.logger.startProgress(
      ' ├─Building App.xcframework...',
    );
    try {
      final Environment environment = Environment(
        projectDir: globals.fs.currentDirectory,
        outputDir: macosBuildOutput,
        buildDir: project.dartTool.childDirectory('flutter_build'),
        cacheDir: globals.cache.getRoot(),
        flutterRootDir: globals.fs.directory(Cache.flutterRoot),
        defines: <String, String>{
          kTargetFile: targetFile,
          kTargetPlatform: getNameForTargetPlatform(TargetPlatform.darwin),
          kDarwinArchs: defaultMacOSArchsForEnvironment(globals.artifacts!)
              .map((DarwinArch e) => e.name)
              .join(' '),
          ...buildInfo.toBuildSystemEnvironment(),
        },
        artifacts: globals.artifacts!,
        fileSystem: globals.fs,
        logger: globals.logger,
        processManager: globals.processManager,
        platform: globals.platform,
        usage: globals.flutterUsage,
        analytics: globals.analytics,
        engineVersion: globals.artifacts!.isLocalEngine ? null : globals.flutterVersion.engineRevision,
        generateDartPluginRegistry: true,
      );
      Target target;
      // Always build debug for simulator.
      if (buildInfo.isDebug) {
        target = const DebugMacOSBundleFlutterAssets();
      } else if (buildInfo.isProfile) {
        target = const ProfileMacOSBundleFlutterAssets();
      } else {
        target = const ReleaseMacOSBundleFlutterAssets();
      }

      final BuildResult result = await buildSystem.build(target, environment);
      if (!result.success) {
        for (final ExceptionMeasurement measurement in result.exceptions.values) {
          globals.printError(measurement.exception.toString());
        }
        throwToolExit('The App.xcframework build failed.');
      }
    } finally {
      status.stop();
    }

    final Directory appFramework = macosBuildOutput.childDirectory('App.framework');
    await BuildFrameworkCommand.produceXCFramework(
      <Directory>[appFramework],
      'App',
      outputBuildDirectory,
      globals.processManager,
    );
    appFramework.deleteSync(recursive: true);
  }

  Future<void> _produceFlutterFramework(
    BuildInfo buildInfo,
    Directory modeDirectory,
  ) async {
    final Status status = globals.logger.startProgress(
      ' ├─Copying FlutterMacOS.xcframework...',
    );
    final String engineCacheFlutterFrameworkDirectory = globals.artifacts!.getArtifactPath(
      Artifact.flutterMacOSXcframework,
      platform: TargetPlatform.darwin,
      mode: buildInfo.mode,
    );
    final String flutterFrameworkFileName = globals.fs.path.basename(
      engineCacheFlutterFrameworkDirectory,
    );
    final Directory flutterFrameworkCopy = modeDirectory.childDirectory(
      flutterFrameworkFileName,
    );

    try {
      // Copy xcframework engine cache framework to mode directory.
      copyDirectory(
        globals.fs.directory(engineCacheFlutterFrameworkDirectory),
        flutterFrameworkCopy,
        followLinks: false,
      );
    } finally {
      status.stop();
    }
  }

  Future<void> _producePlugins(
    String xcodeBuildConfiguration,
    Directory buildOutput,
    Directory modeDirectory,
  ) async {
    final Status status = globals.logger.startProgress(' ├─Building plugins...');
    try {
      final List<String> pluginsBuildCommand = <String>[
        ...globals.xcode!.xcrunCommand(),
        'xcodebuild',
        '-alltargets',
        '-sdk',
        'macosx',
        '-configuration',
        xcodeBuildConfiguration,
        'SYMROOT=${buildOutput.path}',
        'ONLY_ACTIVE_ARCH=NO', // No device targeted, so build all valid architectures.
        'BUILD_LIBRARY_FOR_DISTRIBUTION=YES',
        if (boolArg('static')) 'MACH_O_TYPE=staticlib',
      ];

      final RunResult buildPluginsResult = await globals.processUtils.run(
        pluginsBuildCommand,
        workingDirectory: project.macos.hostAppRoot.childDirectory('Pods').path,
      );

      if (buildPluginsResult.exitCode != 0) {
        throwToolExit('Unable to build plugin frameworks: ${buildPluginsResult.stderr}');
      }

      final Directory buildConfiguration = buildOutput.childDirectory(xcodeBuildConfiguration);

      final Iterable<Directory> products = buildConfiguration.listSync(followLinks: false).whereType<Directory>();
      for (final Directory builtProduct in products) {
        for (final FileSystemEntity podProduct in builtProduct.listSync(followLinks: false)) {
          final String podFrameworkName = podProduct.basename;
          if (globals.fs.path.extension(podFrameworkName) != '.framework') {
            continue;
          }
          final String binaryName = globals.fs.path.basenameWithoutExtension(podFrameworkName);

          await BuildFrameworkCommand.produceXCFramework(
            <Directory>[
              podProduct as Directory,
            ],
            binaryName,
            modeDirectory,
            globals.processManager,
          );
        }
      }
    } finally {
      status.stop();
    }
  }

  @override
  Future<SwiftPackageTarget> remoteFlutterFrameworkTarget(
    BuildMode mode,
    Status status,
  ) async {
    // TODO(vashworth): Limit to stable/beta branch
    final String artifactsMode = mode == BuildMode.debug ? 'darwin-x64' : 'darwin-x64-${mode.cliName}';
    final String frameworkArtifactUrl = '${cache.storageBaseUrl}/flutter_infra_release/flutter/${cache.engineRevision}/$artifactsMode/framework.zip';
    final Directory destination = globals.fs.systemTempDirectory.createTempSync('flutter_framework.');
    await cache.downloadArtifact(
      Uri.parse(frameworkArtifactUrl),
      destination.childFile('framework.zip'),
      status,
    );

    final RunResult results = await globals.processUtils.run(
      <String>[
        'swift',
        'package',
        'compute-checksum',
        destination.childFile('framework.zip').path,
      ],
    );
    if (results.exitCode != 0) {
      throwToolExit('Failed to get checksum for Flutter framework: ${results.stderr}');
    }

    return SwiftPackageTarget.remoteBinaryTarget(
      name: 'FlutterMacOS',
      url: frameworkArtifactUrl,
      checksum: results.stdout.trim(),
    );
  }

  @override
  Future<void> produceRegistrantSourceFiles({
    required String swiftPackageName,
    required Directory swiftPackageDirectory,
    required List<Plugin> plugins,
  }) async {
    final File pluginRegistrant = swiftPackageDirectory
        .childDirectory('Sources')
        .childDirectory(swiftPackageName)
        .childFile('GeneratedPluginRegistrant.swift');
    return writeMacOSPluginRegistrant(
      project,
      plugins,
      pluginRegistrant: pluginRegistrant,
    );
  }
}
