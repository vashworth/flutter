// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:meta/meta.dart';

import '../artifacts.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/utils.dart';
import '../build_info.dart';
import '../build_system/build_system.dart';
import '../build_system/targets/ios.dart';
import '../cache.dart';
import '../features.dart';
import '../flutter_plugins.dart';
import '../globals.dart' as globals;
import '../macos/cocoapod_utils.dart';
import '../macos/swift_package_manager.dart';
import '../macos/swift_packages.dart';
import '../plugins.dart';
import '../runner/flutter_command.dart' show DevelopmentArtifact, FlutterCommandResult;
import '../version.dart';
import 'build_darwin_framework.dart';

/// Produces a .framework for integration into a host iOS app. The .framework
/// contains the Flutter engine and framework code as well as plugins. It can
/// be integrated into plain Xcode projects without using or other package
/// managers.
class BuildIOSFrameworkCommand extends BuildFrameworkCommand {
  BuildIOSFrameworkCommand({
    required super.logger,
    super.flutterVersion,
    required super.buildSystem,
    required bool verboseHelp,
    super.cache,
    super.platform,
  }) : super(verboseHelp: verboseHelp) {
    usesFlavorOption();

    argParser
      ..addFlag(
        'universal',
        help: '(deprecated) Produce universal frameworks that include all valid architectures.',
        hide: !verboseHelp,
      )
      ..addFlag(
        'xcframework',
        help: '(deprecated) Produce xcframeworks that include all valid architectures.',
        negatable: false,
        defaultsTo: true,
        hide: !verboseHelp,
      );
  }

  @override
  final String name = 'ios-framework';

  @override
  final String description =
      'Produces .xcframeworks for a Flutter project '
      'and its plugins for integration into existing, plain iOS Xcode projects.\n'
      'This can only be run on macOS hosts.';

  @override
  Future<Set<DevelopmentArtifact>> get requiredArtifacts async => const <DevelopmentArtifact>{
    DevelopmentArtifact.iOS,
  };

  @override
  List<DarwinPlatform> get targetPlatforms => <DarwinPlatform>[DarwinPlatform.ios];


  @override
  Future<void> validateCommand() async {
    await super.validateCommand();

    if (boolArg('universal')) {
      throwToolExit('--universal has been deprecated, only XCFrameworks are supported.');
    }
  }

  @override
  bool get regeneratePlatformSpecificToolingDuringVerify => false;

  @override
  Future<FlutterCommandResult> runCommand() async {
    final String outputArgument =
        stringArg('output') ??
        globals.fs.path.join(globals.fs.currentDirectory.path, 'build', 'ios', 'framework');

    if (outputArgument.isEmpty) {
      throwToolExit('--output is required.');
    }

    if (!project.ios.existsSync()) {
      throwToolExit('Project does not support iOS');
    }

    final Directory outputDirectory = globals.fs.directory(
      globals.fs.path.absolute(globals.fs.path.normalize(outputArgument)),
    );
    final List<BuildInfo> buildInfos = await getBuildInfos();

    if (project.ios.usesSwiftPackageManager) {
      return buildWithSwiftPM(buildInfos: buildInfos, outputDirectory: outputDirectory);
    } else {
      return _buildWithCocoaPods(buildInfos: buildInfos, outputDirectory: outputDirectory);
    }
  }

  Future<FlutterCommandResult> _buildWithCocoaPods({
    required List<BuildInfo> buildInfos,
    required Directory outputDirectory,
  }) async {
    for (final BuildInfo buildInfo in buildInfos) {
      // Create the build-mode specific metadata.
      //
      // This normally would be done in the verifyAndRun step of FlutterCommand, but special "meta"
      // build commands (like flutter build ios-framework) make multiple builds, and do not have a
      // single "buildInfo", so the step has to be done manually for each build.
      //
      // See regeneratePlatformSpecificToolingDurifyVerify.
      await regeneratePlatformSpecificToolingIfApplicable(
        project,
        releaseMode: buildInfo.mode.isRelease,
      );

      final String? productBundleIdentifier = await project.ios.productBundleIdentifier(buildInfo);
      globals.printStatus(
        'Building frameworks for $productBundleIdentifier in ${buildInfo.mode.cliName} mode...',
      );

      final String xcodeBuildConfiguration = sentenceCase(buildInfo.mode.cliName);
      final Directory modeDirectory = outputDirectory.childDirectory(xcodeBuildConfiguration);

      if (modeDirectory.existsSync()) {
        modeDirectory.deleteSync(recursive: true);
      }

      if (boolArg('cocoapods')) {
        produceFlutterPodspec(buildInfo.mode, modeDirectory, force: boolArg('force'));
      } else {
        // Copy Flutter.xcframework.
        await _produceFlutterFramework(buildInfo, modeDirectory);
      }

      // Build aot, create module.framework and copy.
      final Directory iPhoneBuildOutput = modeDirectory.childDirectory('iphoneos');
      final Directory simulatorBuildOutput = modeDirectory.childDirectory('iphonesimulator');
      await _produceAppFramework(
        buildInfo,
        modeDirectory,
        iPhoneBuildOutput,
        simulatorBuildOutput,
        xcodeBuildConfiguration,
      );

      // Build and copy plugins.
      await processPodsIfNeeded(
        project.ios,
        getIosBuildDirectory(),
        buildInfo.mode,
        forceCocoaPodsOnly: true,
      );
      if (boolArg('plugins') && hasPlugins(project)) {
        await _producePlugins(
          xcodeBuildConfiguration,
          iPhoneBuildOutput,
          simulatorBuildOutput,
          modeDirectory,
        );
      }

      final Status status = globals.logger.startProgress(
        ' └─Moving to ${globals.fs.path.relative(modeDirectory.path)}',
      );

      // Copy the native assets. The native assets have already been signed in
      // buildNativeAssetsMacOS.
      final Directory nativeAssetsDirectory = globals.fs
          .directory(getBuildDirectory())
          .childDirectory('native_assets/ios/');
      if (await nativeAssetsDirectory.exists()) {
        final ProcessResult rsyncResult = await globals.processManager.run(<Object>[
          'rsync',
          '-av',
          '--filter',
          '- .DS_Store',
          '--filter',
          '- native_assets.yaml',
          '--filter',
          '- native_assets.json',
          nativeAssetsDirectory.path,
          modeDirectory.path,
        ]);
        if (rsyncResult.exitCode != 0) {
          throwToolExit('Failed to copy native assets:\n${rsyncResult.stderr}');
        }
      }

      try {
        // Delete the intermediaries since they would have been copied into our
        // output frameworks.
        if (iPhoneBuildOutput.existsSync()) {
          iPhoneBuildOutput.deleteSync(recursive: true);
        }
        if (simulatorBuildOutput.existsSync()) {
          simulatorBuildOutput.deleteSync(recursive: true);
        }
      } finally {
        status.stop();
      }
    }

    globals.printStatus('Frameworks written to ${outputDirectory.path}.');

    if (!project.isModule && hasPlugins(project)) {
      // Apps do not generate a FlutterPluginRegistrant.framework. Users will need
      // to copy the GeneratedPluginRegistrant class to their project manually.
      final File pluginRegistrantHeader = project.ios.pluginRegistrantHeader;
      final File pluginRegistrantImplementation = project.ios.pluginRegistrantImplementation;
      pluginRegistrantHeader.copySync(
        outputDirectory.childFile(pluginRegistrantHeader.basename).path,
      );
      pluginRegistrantImplementation.copySync(
        outputDirectory.childFile(pluginRegistrantImplementation.basename).path,
      );
      globals.printStatus(
        '\nCopy the ${globals.fs.path.basenameWithoutExtension(pluginRegistrantHeader.path)} class into your project.\n'
        'See https://flutter.dev/to/ios-create-flutter-engine for more information.',
      );
    }

    if (!project.isModule && buildInfos.any((BuildInfo info) => info.isDebug)) {
      // Add-to-App must manually add the LLDB Init File to their native Xcode
      // project, so provide the files and instructions.
      final File lldbInitSourceFile = project.ios.lldbInitFile;
      final File lldbInitTargetFile = outputDirectory.childFile(lldbInitSourceFile.basename);
      final File lldbHelperPythonFile = project.ios.lldbHelperPythonFile;
      lldbInitSourceFile.copySync(lldbInitTargetFile.path);
      lldbHelperPythonFile.copySync(outputDirectory.childFile(lldbHelperPythonFile.basename).path);
      globals.printStatus(
        '\nDebugging Flutter on new iOS versions requires an LLDB Init File. To '
        'ensure debug mode works, please complete one of the following in your '
        'native Xcode project:\n'
        '  * Open Xcode > Product > Scheme > Edit Scheme. For both the Run and '
        'Test actions, set LLDB Init File to: \n\n'
        '    ${lldbInitTargetFile.path}\n\n'
        '  * If you are already using an LLDB Init File, please append the '
        'following to your LLDB Init File:\n\n'
        '    command source ${lldbInitTargetFile.path}\n',
      );
    }

    return FlutterCommandResult.success();
  }

  /// Create podspec that will download and unzip remote engine assets so host apps can leverage CocoaPods
  /// vendored framework caching.
  @visibleForTesting
  void produceFlutterPodspec(BuildMode mode, Directory modeDirectory, {bool force = false}) {
    final Status status = globals.logger.startProgress(' ├─Creating Flutter.podspec...');
    try {
      final GitTagVersion gitTagVersion = getGitTagVersion(force);

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
      final String artifactsMode = mode == BuildMode.debug ? 'ios' : 'ios-${mode.cliName}';

      final String podspecContents = '''
Pod::Spec.new do |s|
  s.name                  = 'Flutter'
  s.version               = '${gitTagVersion.x}.${gitTagVersion.y}.$minorHotfixVersion' # ${flutterVersion.frameworkVersion}
  s.summary               = 'A UI toolkit for beautiful and fast apps.'
  s.description           = <<-DESC
Flutter is Google's UI toolkit for building beautiful, fast apps for mobile, web, desktop, and embedded devices from a single codebase.
This pod vends the iOS Flutter engine framework. It is compatible with application frameworks created with this version of the engine and tools.
The pod version matches Flutter version major.minor.(patch * 100) + hotfix.
DESC
  s.homepage              = 'https://flutter.dev'
  s.license               = { :type => 'BSD', :text => <<-LICENSE
$licenseSource
LICENSE
  }
  s.author                = { 'Flutter Dev Team' => 'flutter-dev@googlegroups.com' }
  s.source                = { :http => '${cache.storageBaseUrl}/flutter_infra_release/flutter/${cache.engineRevision}/$artifactsMode/artifacts.zip' }
  s.documentation_url     = 'https://docs.flutter.dev'
  s.platform              = :ios, '13.0'
  s.vendored_frameworks   = 'Flutter.xcframework'
end
''';

      final File podspec = modeDirectory.childFile('Flutter.podspec')..createSync(recursive: true);
      podspec.writeAsStringSync(podspecContents);
    } finally {
      status.stop();
    }
  }

  Future<void> _produceFlutterFramework(BuildInfo buildInfo, Directory modeDirectory) async {
    final Status status = globals.logger.startProgress(' ├─Copying Flutter.xcframework...');
    final String engineCacheFlutterFrameworkDirectory = globals.artifacts!.getArtifactPath(
      Artifact.flutterXcframework,
      platform: TargetPlatform.ios,
      mode: buildInfo.mode,
    );
    final String flutterFrameworkFileName = globals.fs.path.basename(
      engineCacheFlutterFrameworkDirectory,
    );
    final Directory flutterFrameworkCopy = modeDirectory.childDirectory(flutterFrameworkFileName);

    try {
      // Copy xcframework engine cache framework to mode directory.
      copyDirectory(
        globals.fs.directory(engineCacheFlutterFrameworkDirectory),
        flutterFrameworkCopy,
      );
    } finally {
      status.stop();
    }
  }

  Future<void> _produceAppFramework(
    BuildInfo buildInfo,
    Directory outputDirectory,
    Directory iPhoneBuildOutput,
    Directory simulatorBuildOutput,
    String buildMode,
  ) async {
    const String appFrameworkName = 'App.framework';
    final Status status = globals.logger.startProgress(' ├─Building App.xcframework...');
    final List<Directory> frameworks = <Directory>[];

    // Dev dependencies are removed from release builds if the explicit package
    // dependencies flag is on.
    final bool devDependenciesEnabled =
        !featureFlags.isExplicitPackageDependenciesEnabled || !buildInfo.mode.isRelease;

    try {
      for (final EnvironmentType sdkType in EnvironmentType.values) {
        final Directory outputBuildDirectory = switch (sdkType) {
          EnvironmentType.physical => iPhoneBuildOutput,
          EnvironmentType.simulator => simulatorBuildOutput,
        };
        frameworks.add(outputBuildDirectory.childDirectory(appFrameworkName));
        final Environment environment = Environment(
          projectDir: globals.fs.currentDirectory,
          packageConfigPath: packageConfigPath(),
          outputDir: outputBuildDirectory,
          buildDir: project.dartTool.childDirectory('flutter_build'),
          cacheDir: globals.cache.getRoot(),
          flutterRootDir: globals.fs.directory(Cache.flutterRoot),
          defines: <String, String>{
            kTargetFile: targetFile,
            kTargetPlatform: getNameForTargetPlatform(TargetPlatform.ios),
            kIosArchs: defaultIOSArchsForEnvironment(
              sdkType,
              globals.artifacts!,
            ).map((DarwinArch e) => e.name).join(' '),
            kSdkRoot: await globals.xcode!.sdkLocation(sdkType),
            kDevDependenciesEnabled: devDependenciesEnabled.toString(),
            ...buildInfo.toBuildSystemEnvironment(),
            // TODO: SPM - only pass if incremental build
            kXcodeBuildScript: kNativePrepareXcodeBuildScript,
          },
          artifacts: globals.artifacts!,
          fileSystem: globals.fs,
          logger: globals.logger,
          processManager: globals.processManager,
          platform: globals.platform,
          analytics: globals.analytics,
          engineVersion:
              globals.artifacts!.usesLocalArtifacts ? null : globals.flutterVersion.engineRevision,
          generateDartPluginRegistry: true,
        );
        Target target;
        // Always build debug for simulator.
        if (buildInfo.isDebug || sdkType == EnvironmentType.simulator) {
          target = const DebugIosApplicationBundle();
        } else if (buildInfo.isProfile) {
          target = const ProfileIosApplicationBundle();
        } else {
          target = const ReleaseIosApplicationBundle();
        }
        final BuildResult result = await buildSystem.build(target, environment);
        if (!result.success) {
          for (final ExceptionMeasurement measurement in result.exceptions.values) {
            globals.printError(measurement.exception.toString());
          }
          throwToolExit('The App.xcframework build failed.');
        }
      }
    } finally {
      status.stop();
    }

    await BuildFrameworkCommand.produceXCFramework(
      frameworks,
      'App',
      outputDirectory,
      globals.fs.directory(getIosBuildDirectory()),
      globals.processManager,
      buildMode,
    );
  }

  Future<void> _producePlugins(
    String xcodeBuildConfiguration,
    Directory iPhoneBuildOutput,
    Directory simulatorBuildOutput,
    Directory modeDirectory,
  ) async {
    final Status status = globals.logger.startProgress(' ├─Building CocoaPod plugins...');
    try {
      List<String> pluginsBuildCommand = <String>[
        ...globals.xcode!.xcrunCommand(),
        'xcodebuild',
        '-alltargets',
        '-sdk',
        'iphoneos',
        '-configuration',
        xcodeBuildConfiguration,
        'SYMROOT=${iPhoneBuildOutput.path}',
        'ONLY_ACTIVE_ARCH=NO', // No device targeted, so build all valid architectures.
        'BUILD_LIBRARY_FOR_DISTRIBUTION=YES',
        if (boolArg('static')) 'MACH_O_TYPE=staticlib',
      ];

      ProcessResult buildPluginsResult = await globals.processManager.run(
        pluginsBuildCommand,
        workingDirectory: project.ios.hostAppRoot.childDirectory('Pods').path,
        includeParentEnvironment: false,
      );

      if (buildPluginsResult.exitCode != 0) {
        throwToolExit('Unable to build plugin frameworks: ${buildPluginsResult.stderr}');
      }

      // Always build debug for simulator.
      final String simulatorConfiguration = sentenceCase(BuildMode.debug.cliName);
      pluginsBuildCommand = <String>[
        ...globals.xcode!.xcrunCommand(),
        'xcodebuild',
        '-alltargets',
        '-sdk',
        'iphonesimulator',
        '-configuration',
        simulatorConfiguration,
        'SYMROOT=${simulatorBuildOutput.path}',
        'ONLY_ACTIVE_ARCH=NO', // No device targeted, so build all valid architectures.
        'BUILD_LIBRARY_FOR_DISTRIBUTION=YES',
        if (boolArg('static')) 'MACH_O_TYPE=staticlib',
      ];

      buildPluginsResult = await globals.processManager.run(
        pluginsBuildCommand,
        workingDirectory: project.ios.hostAppRoot.childDirectory('Pods').path,
        includeParentEnvironment: false,
      );

      if (buildPluginsResult.exitCode != 0) {
        throwToolExit(
          'Unable to build plugin frameworks for simulator: ${buildPluginsResult.stderr}',
        );
      }

      final Directory iPhoneBuildConfiguration = iPhoneBuildOutput.childDirectory(
        '$xcodeBuildConfiguration-iphoneos',
      );
      final Directory simulatorBuildConfiguration = simulatorBuildOutput.childDirectory(
        '$simulatorConfiguration-iphonesimulator',
      );

      final Iterable<Directory> products =
          iPhoneBuildConfiguration.listSync(followLinks: false).whereType<Directory>();
      for (final Directory builtProduct in products) {
        for (final FileSystemEntity podProduct in builtProduct.listSync(followLinks: false)) {
          final String podFrameworkName = podProduct.basename;
          if (globals.fs.path.extension(podFrameworkName) != '.framework') {
            continue;
          }
          final String binaryName = globals.fs.path.basenameWithoutExtension(podFrameworkName);

          final List<Directory> frameworks = <Directory>[
            podProduct as Directory,
            simulatorBuildConfiguration
                .childDirectory(builtProduct.basename)
                .childDirectory(podFrameworkName),
          ];

          await BuildFrameworkCommand.produceXCFramework(
            frameworks,
            binaryName,
            modeDirectory,
            globals.fs.directory(getIosBuildDirectory()),
            globals.processManager,
            xcodeBuildConfiguration,
          );
        }
      }
    } finally {
      status.stop();
    }
  }

  @override
  Future<(List<SwiftPackageTargetDependency>, List<SwiftPackageTarget>)>
  produceRegistrantSourceFiles({
    required List<BuildInfo> buildInfos,
    required Directory pluginRegistrantSwiftPackage,
    required List<Plugin> regularPlugins,
    required List<Plugin> devPlugins,
    required List<SwiftPackageTargetDependency> targetDependencies,
  }) async {
    // final File registrantHeader = swiftPackageDirectory
    //     .childDirectory('Sources')
    //     .childDirectory(swiftPackageName)
    //     .childDirectory('include')
    //     .childFile('GeneratedPluginRegistrant.h');
    // final File registrantImplementation = swiftPackageDirectory
    //     .childDirectory('Sources')
    //     .childDirectory(swiftPackageName)
    //     .childFile('GeneratedPluginRegistrant.m');
    // return writeIOSPluginRegistrant(
    //   project,
    //   plugins,
    //   pluginRegistrantHeader: registrantHeader,
    //   pluginRegistrantImplementation: registrantImplementation,
    // );
    throw UnimplementedError();
  }
}
