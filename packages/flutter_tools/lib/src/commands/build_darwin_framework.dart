// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:meta/meta.dart';
import 'package:process/process.dart';

import '../base/common.dart';
import '../base/error_handling_io.dart';
import '../base/file_system.dart';
import '../base/fingerprint.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/platform.dart';
import '../base/utils.dart';
import '../build_info.dart';
import '../build_system/build_system.dart';
import '../build_system/targets/ios.dart';
import '../build_system/targets/macos.dart';
import '../cache.dart';
import '../features.dart';
import '../flutter_plugins.dart';
import '../globals.dart' as globals;
import '../macos/cocoapod_utils.dart';
import '../macos/swift_package_manager.dart';
import '../macos/swift_packages.dart';
import '../plugins.dart';
import '../project.dart';
import '../runner/flutter_command.dart';
import '../version.dart';
import 'build.dart';

const String kPluginSwiftPackageName = 'FlutterPluginRegistrant';
const String kFlutterFrameworkSwiftPackageName = 'FlutterFramework';

const String _devDependenciesConditionalTemplate = '''
// Dev Dependencies are only added on non-Release builds
if (mode != "Release") {
    package.dependencies.append(contentsOf: [
        {{packageDependencies}}
    ])
    package.targets[0].dependencies.append(contentsOf: [
        {{targetDependencies}}
    ])
}

''';

abstract class BuildFrameworkCommand extends BuildSubCommand {
  BuildFrameworkCommand({
    // Instantiating FlutterVersion kicks off networking, so delay until it's needed, but allow test injection.
    @visibleForTesting FlutterVersion? flutterVersion,
    required BuildSystem buildSystem,
    required bool verboseHelp,
    Cache? cache,
    Platform? platform,
    required super.logger,
  }) : _injectedFlutterVersion = flutterVersion,
       _buildSystem = buildSystem,
       _injectedCache = cache,
       _injectedPlatform = platform,
       super(verboseHelp: verboseHelp) {
    addTreeShakeIconsFlag();
    usesTargetOption();
    usesPubOption();
    usesDartDefineOption();
    addSplitDebugInfoOption();
    addDartObfuscationOption();
    usesExtraDartFlagOptions(verboseHelp: verboseHelp);
    addEnableExperimentation(hide: !verboseHelp);

    argParser
      ..addFlag(
        'debug',
        defaultsTo: true,
        help:
            'Whether to produce a framework for the debug build configuration. '
            'By default, all build configurations are built.',
      )
      ..addFlag(
        'profile',
        defaultsTo: true,
        help:
            'Whether to produce a framework for the profile build configuration. '
            'By default, all build configurations are built.',
      )
      ..addFlag(
        'release',
        defaultsTo: true,
        help:
            'Whether to produce a framework for the release build configuration. '
            'By default, all build configurations are built.',
      )
      ..addFlag(
        'cocoapods',
        help:
            '(deprecated; use remote-flutter-framework instead) '
            'Produce a Flutter.podspec instead of an engine Flutter.xcframework (recommended if host app uses CocoaPods).',
      )
      ..addFlag(
        'remote-flutter-framework',
        help:
            'For CocoaPods, this will produce a Flutter.podspec instead of an '
            'engine Flutter.xcframework (recommended if host app uses CocoaPods). '
            'For Swift Package Manager, this will use a remote binary of the '
            'Flutter.xcframework instead of a local one.',
      )
      ..addFlag(
        'plugins',
        defaultsTo: true,
        help:
            'Whether to produce frameworks for the plugins. '
            'This is intended for cases where plugins are already being built separately.',
      )
      ..addFlag(
        'static',
        help:
            'Build plugins as static frameworks. Link on, but do not embed these frameworks in the existing Xcode project.',
      )
      ..addOption(
        'output',
        abbr: 'o',
        valueHelp: 'path/to/directory/',
        help: 'Location to write the frameworks.',
      )
      ..addFlag(
        'force',
        abbr: 'f',
        help:
            'Force Flutter.podspec creation on the master channel. This is only intended for testing the tool itself.',
        hide: !verboseHelp,
      )
      ..addFlag(
        'incremental',
        defaultsTo: true,
        help: 'Only rebuilds if changes have been detected',
      );
  }

  final BuildSystem? _buildSystem;
  @protected
  BuildSystem get buildSystem => _buildSystem ?? globals.buildSystem;

  @protected
  Cache get cache => _injectedCache ?? globals.cache;
  final Cache? _injectedCache;

  @protected
  Platform get platform => _injectedPlatform ?? globals.platform;
  final Platform? _injectedPlatform;

  // FlutterVersion.instance kicks off git processing which can sometimes fail, so don't try it until needed.
  @protected
  FlutterVersion get flutterVersion => _injectedFlutterVersion ?? globals.flutterVersion;
  final FlutterVersion? _injectedFlutterVersion;

  @override
  bool get reportNullSafety => false;

  @protected
  List<DarwinPlatform> get targetPlatforms;

  bool get remoteFlutterFramework {
    // TODO(vashworth): Limit to stable/beta branch
    return boolArg('cocoapods') || boolArg('remote-flutter-framework');
  }

  Future<List<BuildInfo>> getBuildInfos() async {
    return <BuildInfo>[
      if (boolArg('debug')) await getBuildInfo(forcedBuildMode: BuildMode.debug),
      if (boolArg('profile')) await getBuildInfo(forcedBuildMode: BuildMode.profile),
      if (boolArg('release')) await getBuildInfo(forcedBuildMode: BuildMode.release),
    ];
  }

  @override
  bool get supported => platform.isMacOS;

  GitTagVersion getGitTagVersion(bool force) {
    final GitTagVersion gitTagVersion = flutterVersion.gitTagVersion;
    if (!force &&
        (gitTagVersion.x == null ||
            gitTagVersion.y == null ||
            gitTagVersion.z == null ||
            gitTagVersion.commits != 0)) {
      throwToolExit(
        '--cocoapods is only supported on the beta or stable channel. Detected version is ${flutterVersion.frameworkVersion}',
      );
    }
    return gitTagVersion;
  }

  @override
  Future<void> validateCommand() async {
    await super.validateCommand();
    if (!supported) {
      throwToolExit('Building frameworks for iOS is only supported on the Mac.');
    }

    if ((await getBuildInfos()).isEmpty) {
      throwToolExit('At least one of "--debug" or "--profile", or "--release" is required.');
    }

    if (!boolArg('plugins') && boolArg('static')) {
      throwToolExit('--static cannot be used with the --no-plugins flag');
    }
  }

  static Future<void> produceXCFramework(
    Iterable<Directory> frameworks,
    String frameworkBinaryName,
    Directory outputDirectory,
    Directory cacheDirectory,
    ProcessManager processManager,
    String buildMode,
  ) async {
    final Directory xcframeworkOutput = outputDirectory.childDirectory(
      '$frameworkBinaryName.xcframework',
    );

    final Fingerprinter fingerprinter = _frameworkFingerprinter(
      cacheDirectory.path,
      buildMode,
      frameworks,
      frameworkBinaryName,
    );
    final bool dependenciesChanged = !fingerprinter.doesFingerprintMatch();

    if (!dependenciesChanged && xcframeworkOutput.existsSync()) {
      globals.logger.printStatus(
        ' ├─  Skipping bundling $frameworkBinaryName. No change detected.',
      );
      return;
    } else {
      ErrorHandlingFileSystem.deleteIfExists(xcframeworkOutput, recursive: true);
    }
    final List<String> xcframeworkCommand = <String>[
      'xcrun',
      'xcodebuild',
      '-create-xcframework',
      for (final Directory framework in frameworks) ...<String>[
        '-framework',
        framework.path,
        ...framework.parent
            .listSync()
            .where(
              (FileSystemEntity entity) =>
                  entity.basename.endsWith('dSYM') && !entity.basename.startsWith('Flutter'),
            )
            .map((FileSystemEntity entity) => <String>['-debug-symbols', entity.path])
            .expand<String>((List<String> parameter) => parameter),
      ],
      '-output',
      xcframeworkOutput.path,
    ];

    final ProcessResult xcframeworkResult = await processManager.run(
      xcframeworkCommand,
      includeParentEnvironment: false,
    );

    if (xcframeworkResult.exitCode != 0) {
      throwToolExit(
        'Unable to create $frameworkBinaryName.xcframework: ${xcframeworkResult.stderr}',
      );
    }
    fingerprinter.writeFingerprint();
  }

  Future<FlutterCommandResult> buildWithSwiftPM({
    required List<BuildInfo> buildInfos,
    required Directory outputDirectory,
  }) async {
    await regeneratePlatformSpecificToolingIfApplicable(project, releaseMode: false);

    // TODO: SPM - If detects legacy files, delete them

    final Directory packagesDirectory = outputDirectory.childDirectory('Packages');
    packagesDirectory.createSync(recursive: true);

    final Directory pluginRegistrantSwiftPackage = outputDirectory.childDirectory(
      kPluginSwiftPackageName,
    );
    pluginRegistrantSwiftPackage.createSync(recursive: true);

    final Directory cacheDirectory = outputDirectory.childDirectory('.cache');
    cacheDirectory.createSync(recursive: true);
    _deletePluginsFromCache(cacheDirectory);

    for (int i = 0; i < buildInfos.length; i++) {
      final BuildInfo buildInfo = buildInfos[i];
      final String xcodeBuildConfiguration = sentenceCase(buildInfo.mode.cliName);
      globals.logger.printStatus('Building for $xcodeBuildConfiguration...');

      Status status = globals.logger.startProgress(
        '   ├─Creating Flutter Framework Swift Package...',
      );
      await _produceFlutterFrameworkSwiftPackage(
        buildInfo: buildInfo,
        cacheDirectory: cacheDirectory.childDirectory(xcodeBuildConfiguration),
        symlinkDirectory: packagesDirectory.childDirectory(xcodeBuildConfiguration),
        pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
      );
      status.stop();

      status = globals.logger.startProgress('   ├─Building App.xcframework...');
      await _produceAppFramework(buildInfo, cacheDirectory, pluginRegistrantSwiftPackage);
      status.stop();

      status = globals.logger.startProgress('   ├─Building CocoaPod plugins...');
      await _produceCocoaPodPlugins(buildInfo, cacheDirectory, pluginRegistrantSwiftPackage);
      status.stop();

      status = globals.logger.startProgress('   ├─Creating Native Assets...');
      _produceNativeAssets();
      status.stop();
    }

    final Status status = globals.logger.startProgress('Generating final package...');

    final String defaultBuildConfiguration = sentenceCase(buildInfos[0].mode.cliName);

    final List<Plugin> plugins = await findPlugins(project);
    // Sort the plugins by name to keep ordering stable in generated files.
    plugins.sort((Plugin left, Plugin right) => left.name.compareTo(right.name));

    final List<Plugin> copiedPlugins = await _produceSwiftPackagePlugins(
      fileSystem: globals.fs,
      cacheDirectory: cacheDirectory,
      plugins: plugins,
      buildInfos: buildInfos,
      packagesDirectory: packagesDirectory,
      defaultBuildConfiguration: defaultBuildConfiguration,
    );

    final List<Plugin> regularPlugins =
        copiedPlugins.where((Plugin p) => !p.isDevDependency).toList();
    final List<Plugin> devPlugins = copiedPlugins.where((Plugin p) => p.isDevDependency).toList();

    final (
      List<SwiftPackagePackageDependency> devPluginPackageDependencies,
      List<SwiftPackageTargetDependency> devTargetDependencies,
    ) = await _generateSwiftPackages(
      flutterPluginsSwiftPackage: pluginRegistrantSwiftPackage,
      symlinkDirectory: packagesDirectory.childDirectory(defaultBuildConfiguration),
      fileSystem: globals.fs,
      plugins: devPlugins,
      defaultBuildConfiguration: defaultBuildConfiguration,
    );

    final (
      List<SwiftPackagePackageDependency> packageDependencies,
      List<SwiftPackageTargetDependency> targetDependencies,
      List<SwiftPackageTarget> additionalTargets,
    ) = await _generateDependenciesAndTargets(
      packagesDirectory: packagesDirectory,
      defaultBuildConfiguration: defaultBuildConfiguration,
      pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
      regularPlugins: regularPlugins,
    );

    // Create FlutterPluginRegistrant source files
    await produceRegistrantSourceFiles(
      buildInfos: buildInfos,
      pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
      regularPlugins: regularPlugins,
      devPlugins: devPlugins,
      targetDependencies: targetDependencies,
    );

    final Directory swiftPackageManagerPluginDirectory = outputDirectory.childDirectory('Plugins');
    ErrorHandlingFileSystem.deleteIfExists(swiftPackageManagerPluginDirectory, recursive: true);
    final Directory updateConfigurationPlugin = swiftPackageManagerPluginDirectory.childDirectory(
      'FlutterConfigurationPlugin',
    );
    final SwiftPackagePackageDependency updateConfigurationPluginDependency =
        _createSwiftPackageManagerPluginDependency(
          pluginName: 'FlutterConfigurationPlugin',
          pluginDirectory: updateConfigurationPlugin,
          pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
        );
    packageDependencies.add(updateConfigurationPluginDependency);

    await _createPluginRegistrant(
      pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
      packageDependencies: packageDependencies,
      targetDependencies: targetDependencies,
      additionalTargets: additionalTargets,
      devPackageDependencies: devPluginPackageDependencies,
      devTargetDependencies: devTargetDependencies,
    );

    final Directory scriptsDirectory = outputDirectory.childDirectory('Scripts');
    ErrorHandlingFileSystem.deleteIfExists(scriptsDirectory, recursive: true);

    _createConfigurationPluginAndScript(
      pluginsDirectory: updateConfigurationPlugin,
      scriptsDirectory: scriptsDirectory,
      pluginRegistrantManifest: pluginRegistrantSwiftPackage.childFile('Package.swift'),
      pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
    );

    _createIncrementalPreBuildActionScript(
      scriptsDirectory: scriptsDirectory,
      pluginRegistrantManifest: pluginRegistrantSwiftPackage.childFile('Package.swift'),
    );

    status.stop();

    return FlutterCommandResult.success();
  }

  /// Delete all cached plugins, except the FlutterFramework.
  void _deletePluginsFromCache(Directory cacheDirectory) {
    for (final FileSystemEntity entity in cacheDirectory.listSync(followLinks: false)) {
      if (entity.basename.endsWith(kFlutterFrameworkSwiftPackageName) ||
          entity.basename.endsWith('.fingerprint')) {
        continue;
      }
      ErrorHandlingFileSystem.deleteIfExists(entity, recursive: true);
    }
  }

  Future<
    (
      List<SwiftPackagePackageDependency>,
      List<SwiftPackageTargetDependency>,
      List<SwiftPackageTarget>,
    )
  >
  _generateDependenciesAndTargets({
    required Directory packagesDirectory,
    required String defaultBuildConfiguration,
    required Directory pluginRegistrantSwiftPackage,
    required List<Plugin> regularPlugins,
  }) async {
    final (
      SwiftPackageTargetDependency flutterFrameworkTargetDependency,
      SwiftPackagePackageDependency flutterFrameworkPackageDependency,
    ) = await _generateFlutterFrameworkSwiftPackage(
      symlinkDirectory: packagesDirectory.childDirectory(defaultBuildConfiguration),
      pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
      defaultBuildConfiguration: defaultBuildConfiguration,
    );

    final (SwiftPackageTargetDependency appTargetDependency, SwiftPackageTarget appTargetBinary) =
        _generateAppFrameworkSwiftDependency();

    final (
      List<SwiftPackageTargetDependency> cocoapodTargetDependencies,
      List<SwiftPackageTarget> cocoapodBinaryTargets,
    ) = _generateCocoaPodsBinaryTargets(
      pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
      defaultBuildConfiguration: defaultBuildConfiguration,
      fileSystem: globals.fs,
    );

    final (
      List<SwiftPackagePackageDependency> regularPluginPackageDependencies,
      List<SwiftPackageTargetDependency> regularTargetDependencies,
    ) = await _generateSwiftPackages(
      flutterPluginsSwiftPackage: pluginRegistrantSwiftPackage,
      symlinkDirectory: packagesDirectory.childDirectory(defaultBuildConfiguration),
      fileSystem: globals.fs,
      plugins: regularPlugins,
      defaultBuildConfiguration: defaultBuildConfiguration,
    );

    return (
      <SwiftPackagePackageDependency>[
        flutterFrameworkPackageDependency,
        ...regularPluginPackageDependencies,
      ],
      <SwiftPackageTargetDependency>[
        flutterFrameworkTargetDependency,
        appTargetDependency,
        ...cocoapodTargetDependencies,
        ...regularTargetDependencies,
      ],
      <SwiftPackageTarget>[appTargetBinary, ...cocoapodBinaryTargets],
    );
  }

  Future<void> _produceFlutterFramework(
    BuildInfo buildInfo,
    DarwinPlatform platform,
    Directory modeDirectory,
  ) async {
    final String engineCacheFlutterFrameworkDirectory = globals.artifacts!.getArtifactPath(
      platform.xcframeworkArtifact,
      platform: platform.targetPlatform,
      mode: buildInfo.mode,
    );
    final String flutterFrameworkFileName = globals.fs.path.basename(
      engineCacheFlutterFrameworkDirectory,
    );
    final Directory flutterFrameworkCopy = modeDirectory.childDirectory(flutterFrameworkFileName);

    copyDirectory(
      globals.fs.directory(engineCacheFlutterFrameworkDirectory),
      flutterFrameworkCopy,
      followLinks: false,
    );
  }

  Future<void> _produceAppFramework(
    BuildInfo buildInfo,
    Directory cacheDirectory,
    Directory pluginRegistrantSwiftPackage,
  ) async {
    const String appFrameworkName = 'App.framework';
    final String xcodeBuildConfiguration = sentenceCase(buildInfo.mode.cliName);
    final Directory modeDirectory = pluginRegistrantSwiftPackage.childDirectory(
      xcodeBuildConfiguration,
    );

    final List<Directory> frameworks = <Directory>[];

    // Dev dependencies are removed from release builds if the explicit package
    // dependencies flag is on.
    final bool devDependenciesEnabled =
        !featureFlags.isExplicitPackageDependenciesEnabled || !buildInfo.mode.isRelease;

    try {
      for (final DarwinPlatform platform in targetPlatforms) {
        for (final DarwinSDK sdk in platform.sdks) {
          final Directory outputBuildDirectory = cacheDirectory
              .childDirectory(xcodeBuildConfiguration)
              .childDirectory(sdk.name);
          frameworks.add(outputBuildDirectory.childDirectory(appFrameworkName));
          final Map<String, String> iosDefines = <String, String>{};
          if (platform == DarwinPlatform.ios) {
            iosDefines.addAll(<String, String>{
              kIosArchs: defaultIOSArchsForEnvironment(
                sdk.sdkType!,
                globals.artifacts!,
              ).map((DarwinArch e) => e.name).join(' '),
              kSdkRoot: await globals.xcode!.sdkLocation(sdk.sdkType!),
            });
          }
          final Environment environment = Environment(
            projectDir: globals.fs.currentDirectory,
            packageConfigPath: packageConfigPath(),
            outputDir: outputBuildDirectory,
            buildDir: project.dartTool.childDirectory('flutter_build'),
            cacheDir: globals.cache.getRoot(),
            flutterRootDir: globals.fs.directory(Cache.flutterRoot),
            defines: <String, String>{
              kTargetFile: targetFile,
              kTargetPlatform: getNameForTargetPlatform(platform.targetPlatform),
              ...iosDefines,
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
                globals.artifacts!.usesLocalArtifacts
                    ? null
                    : globals.flutterVersion.engineRevision,
            generateDartPluginRegistry: true,
          );
          Target target;

          switch (platform) {
            case DarwinPlatform.ios:
              // Always build debug for simulator.
              if (buildInfo.isDebug || sdk.sdkType == EnvironmentType.simulator) {
                target = const DebugIosApplicationBundle();
              } else if (buildInfo.isProfile) {
                target = const ProfileIosApplicationBundle();
              } else {
                target = const ReleaseIosApplicationBundle();
              }
            case DarwinPlatform.macos:
              if (buildInfo.isDebug) {
                target = const DebugMacOSBundleFlutterAssets();
              } else if (buildInfo.isProfile) {
                target = const ProfileMacOSBundleFlutterAssets();
              } else {
                target = const ReleaseMacOSBundleFlutterAssets();
              }
          }

          final BuildResult result = await buildSystem.build(target, environment);
          if (!result.success) {
            for (final ExceptionMeasurement measurement in result.exceptions.values) {
              globals.printError(measurement.exception.toString());
            }
            throwToolExit('The App.xcframework build failed.');
          }
        }
      }
    } finally {}

    await BuildFrameworkCommand.produceXCFramework(
      frameworks,
      'App',
      modeDirectory,
      cacheDirectory,
      globals.processManager,
      xcodeBuildConfiguration,
    );
  }

  (SwiftPackageTargetDependency, SwiftPackageTarget) _generateAppFrameworkSwiftDependency() {
    return (
      SwiftPackageTargetDependency.target(name: 'App'),
      SwiftPackageTarget.binaryTarget(name: 'App', relativePath: r'\(mode)/App.xcframework'),
    );
  }

  Future<void> _produceCocoaPodPlugins(
    BuildInfo buildInfo,
    Directory cacheDirectory,
    Directory pluginRegistrantSwiftPackage,
  ) async {
    if (boolArg('plugins') && hasPlugins(project)) {
      // TODO: SPM- what to do here?
    }

    // TODO: SPM - when to delete CocoaPodsFrameworks?

    final String xcodeBuildConfiguration = sentenceCase(buildInfo.mode.cliName);
    final Directory modeDirectory = pluginRegistrantSwiftPackage.childDirectory(
      xcodeBuildConfiguration,
    );
    final Fingerprinter fingerprinter = _cocoapodsFingerprinter(
      cacheDirectory.path,
      modeDirectory,
      xcodeBuildConfiguration,
    );
    final bool dependenciesChanged = !fingerprinter.doesFingerprintMatch();
    final Directory cocoapodFrameworkDirectory = modeDirectory.childDirectory(
      'CocoaPodsFrameworks',
    );

    if (!dependenciesChanged && cocoapodFrameworkDirectory.existsSync()) {
      globals.logger.printStatus('Skipping building CocoaPod plugins. No change detected');
      return;
    }

    final Map<String, List<Directory>> createdFrameworks = <String, List<Directory>>{};
    try {
      for (final DarwinPlatform platform in targetPlatforms) {
        final XcodeBasedProject xcodeProject = platform.xcodeProject(project);
        final String buildDirectory;
        switch (platform) {
          case DarwinPlatform.ios:
            buildDirectory = getIosBuildDirectory();
          case DarwinPlatform.macos:
            buildDirectory = getMacOSBuildDirectory();
        }
        await processPodsIfNeeded(xcodeProject, buildDirectory, buildInfo.mode);

        for (final DarwinSDK sdk in platform.sdks) {
          final String configuration;
          if (sdk.sdkType == EnvironmentType.simulator) {
            // Always build debug for simulator.
            configuration = sentenceCase(BuildMode.debug.cliName);
          } else {
            configuration = xcodeBuildConfiguration;
          }
          final Directory outputBuildDirectory = cacheDirectory
              .childDirectory(xcodeBuildConfiguration)
              .childDirectory(sdk.name);
          final List<String> pluginsBuildCommand = <String>[
            ...globals.xcode!.xcrunCommand(),
            'xcodebuild',
            '-alltargets',
            '-sdk',
            sdk.name,
            '-configuration',
            configuration,
            'SYMROOT=${outputBuildDirectory.path}',
            'ONLY_ACTIVE_ARCH=NO', // No device targeted, so build all valid architectures.
            'BUILD_LIBRARY_FOR_DISTRIBUTION=YES',
            if (boolArg('static')) 'MACH_O_TYPE=staticlib',
          ];
          final ProcessResult buildPluginsResult = await globals.processManager.run(
            pluginsBuildCommand,
            workingDirectory: xcodeProject.hostAppRoot.childDirectory('Pods').path,
            includeParentEnvironment: false,
          );
          if (buildPluginsResult.exitCode != 0) {
            throwToolExit('Unable to build plugin frameworks: ${buildPluginsResult.stderr}');
          }
          final Directory configurationBuildDir;
          if (platform == DarwinPlatform.macos) {
            configurationBuildDir = outputBuildDirectory.childDirectory(configuration);
          } else {
            configurationBuildDir = outputBuildDirectory.childDirectory(
              '$configuration-${sdk.name}',
            );
          }
          final Iterable<Directory> products =
              configurationBuildDir.listSync(followLinks: false).whereType<Directory>();
          for (final Directory builtProduct in products) {
            for (final Directory podProduct
                in builtProduct.listSync(followLinks: false).whereType<Directory>()) {
              final String podFrameworkName = podProduct.basename;
              if (globals.fs.path.extension(podFrameworkName) != '.framework') {
                continue;
              }
              final String binaryName = globals.fs.path.basenameWithoutExtension(podFrameworkName);
              if (createdFrameworks[binaryName] == null) {
                createdFrameworks[binaryName] = <Directory>[];
              }
              createdFrameworks[binaryName]?.add(podProduct);
            }
          }
        }
      }

      for (final String frameworkName in createdFrameworks.keys) {
        final List<Directory>? frameworkDirectories = createdFrameworks[frameworkName];
        if (frameworkDirectories != null) {
          await BuildFrameworkCommand.produceXCFramework(
            frameworkDirectories,
            frameworkName,
            cocoapodFrameworkDirectory,
            cacheDirectory,
            globals.processManager,
            xcodeBuildConfiguration,
          );
        }
      }
      fingerprinter.writeFingerprint();
    } finally {}

    return;
  }

  Future<void> _produceFlutterFrameworkSwiftPackage({
    required BuildInfo buildInfo,
    required Directory cacheDirectory,
    required Directory symlinkDirectory,
    required Directory pluginRegistrantSwiftPackage,
  }) async {
    final Directory flutterFrameworkSwiftPackage = cacheDirectory.childDirectory(
      kFlutterFrameworkSwiftPackageName,
    );

    final Directory engineDir = flutterFrameworkSwiftPackage.childDirectory(cache.engineRevision)
      ..createSync(recursive: true);
    for (final DarwinPlatform platform in targetPlatforms) {
      await _produceFlutterFramework(buildInfo, platform, engineDir);
    }

    final Link symlink = symlinkDirectory.childLink(kFlutterFrameworkSwiftPackageName);
    ErrorHandlingFileSystem.deleteIfExists(symlink);
    symlink.createSync(flutterFrameworkSwiftPackage.path, recursive: true);

    final SwiftPackageManager spm = SwiftPackageManager(
      artifacts: globals.artifacts!,
      cache: globals.cache,
      fileSystem: globals.fs,
      templateRenderer: globals.templateRenderer,
    );
    await spm.generateConditionalFlutterFrameworkSwiftPackage(
      project,
      platforms: targetPlatforms,
      buildMode: buildInfo.mode,
      manifestPath: flutterFrameworkSwiftPackage.childFile('Package.swift'),
      remoteFramework: remoteFlutterFramework,
      buildModeInPath: false,
    );
  }

  Future<(SwiftPackageTargetDependency, SwiftPackagePackageDependency)>
  _generateFlutterFrameworkSwiftPackage({
    required Directory symlinkDirectory,
    required Directory pluginRegistrantSwiftPackage,
    required String defaultBuildConfiguration,
  }) async {
    final Link symlink = symlinkDirectory.childLink(kFlutterFrameworkSwiftPackageName);
    final String relativePath = globals.fs.path.relative(
      symlink.path,
      from: pluginRegistrantSwiftPackage.path,
    );

    return (
      SwiftPackageTargetDependency.product(
        name: 'Flutter',
        packageName: kFlutterFrameworkSwiftPackageName,
      ),
      SwiftPackagePackageDependency.local(
        packageName: kFlutterFrameworkSwiftPackageName,
        localPath: relativePath.replaceFirst(defaultBuildConfiguration, r'\(mode)'),
      ),
    );
  }

  /// Create a FlutterGeneratedPluginRegistrant, that has dependencies on Flutter,
  /// CocoaPods plugins (made into xcframeworks), and SwiftPM plugins.
  Future<
    (
      List<SwiftPackagePackageDependency> packageDependencies,
      List<SwiftPackageTargetDependency> targetDependencies,
    )
  >
  _generateSwiftPackages({
    required Directory flutterPluginsSwiftPackage,
    required Directory symlinkDirectory,
    required FileSystem fileSystem,
    required List<Plugin> plugins,
    required String defaultBuildConfiguration,
  }) async {
    final File manifestFile = flutterPluginsSwiftPackage.childFile('Package.swift');
    final (
      List<SwiftPackagePackageDependency> packageDependencies,
      List<SwiftPackageTargetDependency> targetDependencies,
    ) = SwiftPackageManager.dependenciesForPlugins(
      plugins: plugins,
      platforms: targetPlatforms,
      fileSystem: fileSystem,
      pathRelativeTo: manifestFile.parent.path,
      symlinkDirectory: symlinkDirectory,
      buildModeToReplace: defaultBuildConfiguration,
    );

    return (packageDependencies, targetDependencies);
  }

  Future<List<Plugin>> _produceSwiftPackagePlugins({
    required FileSystem fileSystem,
    required Directory cacheDirectory,
    required List<Plugin> plugins,
    required List<BuildInfo> buildInfos,
    required Directory packagesDirectory,
    required String defaultBuildConfiguration,
  }) async {
    final List<Plugin> pluginDependencies = <Plugin>[];

    for (final DarwinPlatform platform in targetPlatforms) {
      // Copy Swift Package plugins into a child directory so they are relatively located.
      final List<Plugin> copiedPlugins = await _copySwiftPackagePlugins(
        destination: cacheDirectory,
        platform: platform,
        plugins: plugins,
        fileSystem: fileSystem,
        alreadyCopiedPlugins: pluginDependencies,
        buildInfos: buildInfos,
        packagesDirectory: packagesDirectory,
        defaultBuildConfiguration: defaultBuildConfiguration,
      );
      pluginDependencies.addAll(copiedPlugins);
    }

    return pluginDependencies;
  }

  /// Find all xcframeworks in the [frameworksDir] and create a Swift Package
  /// named [packageName] that produces a library for each.
  (List<SwiftPackageTargetDependency>, List<SwiftPackageTarget>) _generateCocoaPodsBinaryTargets({
    required Directory pluginRegistrantSwiftPackage,
    required String defaultBuildConfiguration,
    required FileSystem fileSystem,
  }) {
    final List<SwiftPackageTargetDependency> cocoapodTargetDependencies =
        <SwiftPackageTargetDependency>[];
    final List<SwiftPackageTarget> cocoapodBinaryTargets = <SwiftPackageTarget>[];

    // They should all have the same directories, so just pick the first.

    final Directory cocoapodsFrameworksDirectory = pluginRegistrantSwiftPackage
        .childDirectory(defaultBuildConfiguration)
        .childDirectory('CocoaPodsFrameworks');

    if (cocoapodsFrameworksDirectory.existsSync()) {
      for (final FileSystemEntity entity in cocoapodsFrameworksDirectory.listSync()) {
        if (entity is Directory && entity.basename.endsWith('xcframework')) {
          final String frameworkName = fileSystem.path.basenameWithoutExtension(entity.path);
          final Set<SwiftPackagePlatform> platformConditions = <SwiftPackagePlatform>{};
          for (final FileSystemEntity subfile in entity.listSync()) {
            if (subfile.basename.contains(DarwinPlatform.ios.name)) {
              platformConditions.add(SwiftPackagePlatform.ios);
            } else {
              if (subfile.basename.contains(DarwinPlatform.macos.name)) {
                platformConditions.add(SwiftPackagePlatform.macos);
              }
            }
          }
          cocoapodTargetDependencies.add(
            SwiftPackageTargetDependency.target(
              name: frameworkName,
              platformCondition: platformConditions.toList(),
            ),
          );
          cocoapodBinaryTargets.add(
            SwiftPackageTarget.binaryTarget(
              name: frameworkName,
              relativePath: '\\(mode)/CocoaPodsFrameworks/${entity.basename}',
            ),
          );
        }
      }
    }
    return (cocoapodTargetDependencies, cocoapodBinaryTargets);
  }

  /// Copy plugins with a Package.swift for the given [platform] to [destination].
  Future<List<Plugin>> _copySwiftPackagePlugins({
    required List<BuildInfo> buildInfos,
    required Directory packagesDirectory,
    required String defaultBuildConfiguration,
    required List<Plugin> plugins,
    required Directory destination,
    required DarwinPlatform platform,
    required FileSystem fileSystem,
    required List<Plugin> alreadyCopiedPlugins,
  }) async {
    final List<Plugin> copiedPlugins = <Plugin>[];
    for (final Plugin plugin in plugins) {
      if (alreadyCopiedPlugins
          .where((Plugin copiedPlugin) => copiedPlugin.name == plugin.name)
          .isNotEmpty) {
        continue;
      }
      final String? pluginSwiftPackageManifestPath = plugin.pluginSwiftPackageManifestPath(
        fileSystem,
        platform.name,
      );
      if (plugin.platforms[platform.name] == null ||
          pluginSwiftPackageManifestPath == null ||
          !fileSystem.file(pluginSwiftPackageManifestPath).existsSync()) {
        continue;
      }
      final Directory pluginSource = fileSystem.directory(plugin.path);
      final Directory pluginDestination = destination.childDirectory(plugin.name)
        ..createSync(recursive: true);

      copyDirectory(
        pluginSource,
        pluginDestination,
        shouldCopyDirectory: (Directory dir) => !dir.path.endsWith('example'),
      );

      final String? packagePath = plugin.pluginSwiftPackagePath(
        fileSystem,
        platform.name,
        overridePath: pluginDestination.path,
      );
      if (packagePath == null) {
        throwToolExit('message');
      }
      for (final BuildInfo buildInfo in buildInfos) {
        final String xcodeBuildConfiguration = sentenceCase(buildInfo.mode.cliName);
        final Link pluginSymlink = packagesDirectory
            .childDirectory(xcodeBuildConfiguration)
            .childLink(plugin.name);
        ErrorHandlingFileSystem.deleteIfExists(pluginSymlink);
        pluginSymlink.createSync(packagePath);
      }

      final Plugin copiedPlugin = Plugin(
        name: plugin.name,
        path: pluginDestination.path,
        platforms: plugin.platforms,
        defaultPackagePlatforms: plugin.defaultPackagePlatforms,
        pluginDartClassPlatforms: plugin.pluginDartClassPlatforms,
        dependencies: plugin.dependencies,
        isDirectDependency: plugin.isDirectDependency,
        isDevDependency: plugin.isDevDependency,
      );
      copiedPlugins.add(copiedPlugin);
    }

    return copiedPlugins;
  }

  // Create FlutterPluginRegistrant Swift Package with dependencies on the
  // Swift Package plugins, CocoaPods xcframeworks, and Flutter/App xcframeworks.
  Future<void> _createPluginRegistrant({
    required Directory pluginRegistrantSwiftPackage,
    required List<SwiftPackagePackageDependency> packageDependencies,
    required List<SwiftPackageTargetDependency> targetDependencies,
    required List<SwiftPackageTarget> additionalTargets,
    required List<SwiftPackagePackageDependency> devPackageDependencies,
    required List<SwiftPackageTargetDependency> devTargetDependencies,
  }) async {
    const String swiftPackageName = kPluginSwiftPackageName;
    final File manifestFile = pluginRegistrantSwiftPackage.childFile('Package.swift');

    final SwiftPackageProduct generatedProduct = SwiftPackageProduct(
      name: swiftPackageName,
      targets: <String>[swiftPackageName],
      libraryType: SwiftPackageLibraryType.static,
    );

    final List<SwiftPackageTarget> targets = <SwiftPackageTarget>[
      SwiftPackageTarget.defaultTarget(
        name: swiftPackageName,
        dependencies: targetDependencies,
        path: '\\(mode)/Sources/$kPluginSwiftPackageName',
      ),
      ...additionalTargets,
    ];

    String? devDependenciesTemplate;
    if (devPackageDependencies.isNotEmpty) {
      final String devPackageDependenciesString = devPackageDependencies
          .map((SwiftPackagePackageDependency dep) => dep.format())
          .join(',\n');
      final String devTargetDependenciesString = devTargetDependencies
          .map((SwiftPackageTargetDependency dep) => dep.format())
          .join(',\n');
      devDependenciesTemplate = globals.templateRenderer
          .renderString(_devDependenciesConditionalTemplate, <String, Object>{
            'packageDependencies': devPackageDependenciesString,
            'targetDependencies': devTargetDependenciesString,
          });
    }

    final SwiftPackage pluginsPackage = SwiftPackage(
      manifest: manifestFile,
      name: swiftPackageName,
      swiftCodeBeforePackageDefinition: 'let mode = "Debug"', // TODO: SPM - don't hardcode
      platforms: <SwiftPackageSupportedPlatform>[
        SwiftPackageManager.iosSwiftPackageSupportedPlatform,
        SwiftPackageManager.macosSwiftPackageSupportedPlatform,
      ],
      products: <SwiftPackageProduct>[generatedProduct],
      dependencies: packageDependencies,
      targets: targets,
      templateRenderer: globals.templateRenderer,
      swiftCodeAfterPackageDefinition: devDependenciesTemplate,
    );

    pluginsPackage.createSwiftPackage(
      skipSourceFileCreation: <String, bool>{'FlutterPluginRegistrant': true},
    );
  }

  @visibleForOverriding
  Future<void> produceRegistrantSourceFiles({
    required List<BuildInfo> buildInfos,
    required Directory pluginRegistrantSwiftPackage,
    required List<Plugin> regularPlugins,
    required List<Plugin> devPlugins,
    required List<SwiftPackageTargetDependency> targetDependencies,
  }) async {
    throw UnimplementedError();
  }

  static Fingerprinter _frameworkFingerprinter(
    String cacheDirectoryPath,
    String buildMode,
    Iterable<Directory> frameworks,
    String frameworkBinaryName,
  ) {
    final List<String> childFiles = <String>[];
    for (final Directory framework in frameworks) {
      if (framework.existsSync()) {
        for (final FileSystemEntity entity in framework.listSync(recursive: true)) {
          if (entity is File) {
            childFiles.add(entity.path);
          }
        }
      }
    }

    final Fingerprinter fingerprinter = Fingerprinter(
      fingerprintPath: globals.fs.path.join(
        cacheDirectoryPath,
        'build_${buildMode}_$frameworkBinaryName.fingerprint',
      ),
      paths: <String>[
        globals.fs.path.join(
          Cache.flutterRoot!,
          'packages',
          'flutter_tools',
          'lib',
          'src',
          'commands',
          'build_darwin_framework.dart',
        ),
        ...childFiles,
      ],
      fileSystem: globals.fs,
      logger: globals.logger,
    );
    return fingerprinter;
  }

  Fingerprinter _cocoapodsFingerprinter(
    String cacheDirectoryPath,
    Directory modeDirectory,
    String xcodeBuildConfiguration,
  ) {
    final List<String> fingerprintedFiles = <String>[];

    // Add already created xcframeworks
    if (modeDirectory.childDirectory('CocoaPodsFrameworks').existsSync()) {
      for (final FileSystemEntity entity in modeDirectory
          .childDirectory('CocoaPodsFrameworks')
          .listSync(recursive: true)) {
        if (entity is File) {
          fingerprintedFiles.add(entity.path);
        }
      }
    }

    // If the Xcode project, Podfile, generated plugin Swift Package, or podhelper
    // have changed since last run, pods should be updated.
    for (final DarwinPlatform platform in targetPlatforms) {
      final XcodeBasedProject xcodeProject = platform.xcodeProject(project);
      fingerprintedFiles.add(xcodeProject.xcodeProjectInfoFile.path);
      fingerprintedFiles.add(xcodeProject.podfile.path);
      if (xcodeProject.flutterPluginSwiftPackageManifest.existsSync()) {
        fingerprintedFiles.add(xcodeProject.flutterPluginSwiftPackageManifest.path);
      }
    }

    final Fingerprinter fingerprinter = Fingerprinter(
      fingerprintPath: globals.fs.path.join(
        cacheDirectoryPath,
        'build_${xcodeBuildConfiguration}_pod_inputs.fingerprint',
      ),
      paths: <String>[
        globals.fs.path.join(
          Cache.flutterRoot!,
          'packages',
          'flutter_tools',
          'bin',
          'podhelper.rb',
        ),
        globals.fs.path.join(
          Cache.flutterRoot!,
          'packages',
          'flutter_tools',
          'lib',
          'src',
          'commands',
          'build_darwin_framework.dart',
        ),
        ...fingerprintedFiles,
      ],
      fileSystem: globals.fs,
      logger: globals.logger,
    );
    return fingerprinter;
  }

  void _createConfigurationPluginAndScript({
    required Directory pluginRegistrantSwiftPackage,
    required Directory pluginsDirectory,
    required Directory scriptsDirectory,
    required File pluginRegistrantManifest,
  }) {
    // TODO: SPM - update flutter framework too
    ErrorHandlingFileSystem.deleteIfExists(pluginsDirectory, recursive: true);
    final File manifest = pluginsDirectory.childFile('Package.swift')..createSync(recursive: true);
    final File debugPluginSwiftFiles = pluginsDirectory
      .childDirectory('Plugins')
      .childDirectory('Debug')
      .childFile('UpdateConfiguration.swift')..createSync(recursive: true);
    final File profilePluginSwiftFiles = pluginsDirectory
      .childDirectory('Plugins')
      .childDirectory('Profile')
      .childFile('UpdateConfiguration.swift')..createSync(recursive: true);
    final File releasePluginSwiftFiles = pluginsDirectory
      .childDirectory('Plugins')
      .childDirectory('Release')
      .childFile('UpdateConfiguration.swift')..createSync(recursive: true);
    final File validateSwiftFiles = pluginsDirectory
      .childDirectory('Plugins')
      .childDirectory('Validate')
      .childFile('ValidateConfiguration.swift')..createSync(recursive: true);
    final File packageTemplate = pluginsDirectory
      .childDirectory('Plugins')
      .childFile('template.swift.tmpl')..createSync(recursive: true);

    // TODO: SPM - move to templates
    manifest.writeAsStringSync('''
// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FlutterConfigurationPlugin",
    products: [
        .plugin(name: "FlutterConfigurationPlugin", targets: ["Switch to Debug Mode", "Switch to Profile Mode", "Switch to Release Mode", "Validate Configuration"])
    ],
    targets: [
        .plugin(
            name: "Switch to Debug Mode",
            capability: .command(
                intent: .custom(verb: "switch-to-debug", description: "Updates package to use the Debug mode Flutter framework"),
                permissions: [
                    .writeToPackageDirectory(reason: "Updates package to use the Debug mode Flutter framework"),
                ]
            ),
            path: "Plugins/Debug"
        ),
        .plugin(
            name: "Switch to Profile Mode",
            capability: .command(
                intent: .custom(verb: "switch-to-profile", description: "Updates package to use the Profile mode Flutter framework"),
                permissions: [
                    .writeToPackageDirectory(reason: "Updates package to use the Profile mode Flutter framework")
                ]
            ),
            path: "Plugins/Profile"
        ),
        .plugin(
            name: "Switch to Release Mode",
            capability: .command(
                intent: .custom(verb: "switch-to-release", description: "Updates package to use the Release mode Flutter framework"),
                permissions: [
                    .writeToPackageDirectory(reason: "Updates package to use the Release mode Flutter framework")
                ]
            ),
            path: "Plugins/Release"
        ),
        .plugin(
            name: "Validate Configuration",
            capability: .command(
                intent: .custom(verb: "validate", description: "Validate Flutter packages have the correct configuration set"),
                permissions: []
            ),
            path: "Plugins/Validate"
        )
    ]
)
''');

    debugPluginSwiftFiles.writeAsStringSync(r'''
import PackagePlugin
import Foundation

@main
struct FlutterConfigurationPlugin: CommandPlugin {
    // Entry point for command plugins applied to Swift Packages.
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let file = "Package.swift"
        let dir = context.package.directoryURL
        let fileURL = dir.appendingPathComponent(file)
        let templateFile = "template.swift.tmpl"
        let templateFileURL = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: templateFile)
        let text = try String(contentsOf: templateFileURL, encoding: .utf8)
        let replaced = text.replacingOccurrences(of: "$CONFIGURATION", with: "Debug")
        try replaced.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
''');

    profilePluginSwiftFiles.writeAsStringSync(r'''
import PackagePlugin
import Foundation

@main
struct FlutterConfigurationPlugin: CommandPlugin {
    // Entry point for command plugins applied to Swift Packages.
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let file = "Package.swift"
        let dir = context.package.directoryURL
        let fileURL = dir.appendingPathComponent(file)
        let templateFile = "template.swift.tmpl"
        let templateFileURL = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: templateFile)
        let text = try String(contentsOf: templateFileURL, encoding: .utf8)
        let replaced = text.replacingOccurrences(of: "$CONFIGURATION", with: "Profile")
        try replaced.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
''');

    releasePluginSwiftFiles.writeAsStringSync(r'''
import PackagePlugin
import Foundation

@main
struct FlutterConfigurationPlugin: CommandPlugin {
    // Entry point for command plugins applied to Swift Packages.
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let file = "Package.swift"
        let dir = context.package.directoryURL
        let fileURL = dir.appendingPathComponent(file)
        let templateFile = "template.swift.tmpl"
        let templateFileURL = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: templateFile)
        let text = try String(contentsOf: templateFileURL, encoding: .utf8)
        let replaced = text.replacingOccurrences(of: "$CONFIGURATION", with: "Release")
        try replaced.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
''');

    // TODO: SPM - if install mode, exit with error instead of warning
    // TODO: SPM - throw helpful error is missing argument
    validateSwiftFiles.writeAsStringSync('''
import PackagePlugin
import Foundation

@main
struct FlutterValidateConfiguration: CommandPlugin {
    // Entry point for command plugins applied to Swift Packages.
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let configuration = arguments[1].capitalized
        let file = "Package.swift"
        let dir = context.package.directoryURL
        let fileURL = dir.appendingPathComponent(file)
        let text = try String(contentsOf: fileURL, encoding: .utf8)

        if (text.contains("let mode = \\"\\(configuration)\\"")) {
            print("success")
            return
        }

        print("warning: The current build configuration is set to \\(configuration), but Flutter packages are not. Please comlpete one of the following:")
        print("note:   1) Right click on FlutterPluginRegistrant in Xcode's Project Navigator and select \\"Switch to \\(configuration) Mode\\".")
        print("note:   or")
        print("note:   2) Run the following in a terminal:")
        print("note:       cd ${pluginRegistrantSwiftPackage.path}")
        print("note:       env -i swift package plugin --package FlutterConfigurationPlugin --allow-writing-to-package-directory switch-to-debug")
    }
}''');

    final File script = scriptsDirectory.childFile('validate_configuration.sh')
      ..createSync(recursive: true);
    script.writeAsStringSync('''
#!/bin/bash
# Copyright 2013 The Flutter Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

EchoWarning() {
  echo "warning: \$@" 1>&2
}

ParseFlutterBuildMode() {
  # Use FLUTTER_BUILD_MODE if it's set, otherwise use the Xcode build configuration name
  # This means that if someone wants to use an Xcode build config other than Debug/Profile/Release,
  # they _must_ set FLUTTER_BUILD_MODE so we know what type of artifact to build.
  local build_mode="\$(echo "\${FLUTTER_BUILD_MODE:-\${CONFIGURATION}}" | tr "[:upper:]" "[:lower:]")"

  case "\$build_mode" in
    *release*) build_mode="release";;
    *profile*) build_mode="profile";;
    *debug*) build_mode="debug";;
    *)
    # TODO: link to documentation
      EchoWarning "========================================================================"
      EchoWarning "WARNING: Unknown FLUTTER_BUILD_MODE: \${build_mode}. Please see [insert link here] on how to setup FLUTTER_BUILD_MODE."
      EchoWarning "========================================================================"
      exit -1;;
  esac

  echo "\${build_mode}"
}

ValidateBuildMode() {
  if [[ \$ACTION == "clean" ]]; then
    exit 0
  fi
  # Get the build mode
  local build_mode="\$(ParseFlutterBuildMode)"

  if [[ -z "\$build_mode" ]]; then
    exit -1
  fi

  pushd "${pluginRegistrantSwiftPackage.absolute.path}"  > /dev/null
  local output=\$(env -i swift package plugin --package FlutterConfigurationPlugin validate --configuration \${build_mode} 2>&1)
  if [ "\$output" != "success" ]; then
    # If the output is not "success", print the entire output to stderr.
    echo "\$output" 1>&2
  fi
}

ValidateBuildMode
''');

    packageTemplate.writeAsStringSync(
      pluginRegistrantManifest.readAsStringSync().replaceFirst(
        'let mode = "Debug"', // TODO: SPM - don't hardcode
        r'let mode = "$CONFIGURATION"',
      ),
    );
  }

  void _createIncrementalPreBuildActionScript({
    required Directory scriptsDirectory,
    required File pluginRegistrantManifest,
  }) {
    // TODO: SPM - use macos or ios?
    final String environmentExports =
        project.ios.generatedEnvironmentVariableExportScript.readAsStringSync();
    final File script = scriptsDirectory.childFile('pre_build.sh')..createSync(recursive: true);
    script.writeAsStringSync('''
$environmentExports

export "FLUTTER_GENERATED_PLUGIN_REGISTRANT_PACKAGE_SWIFT=${pluginRegistrantManifest.path}"

# Needed because if it is set, cd may print the path it changed to.
unset CDPATH

BIN_DIR="\$FLUTTER_ROOT/packages/flutter_tools/bin/"
DART="\$FLUTTER_ROOT/bin/dart"

"\$DART" "\$BIN_DIR/xcode_backend.dart" prepare-native
''');
  }

  SwiftPackagePackageDependency _createSwiftPackageManagerPluginDependency({
    required String pluginName,
    required Directory pluginDirectory,
    required Directory pluginRegistrantSwiftPackage,
  }) {
    return SwiftPackagePackageDependency.local(
      packageName: pluginName,
      localPath: globals.fs.path.relative(
        pluginDirectory.path,
        from: pluginRegistrantSwiftPackage.path,
      ),
    );
  }

  // TODO: SPM
  void _produceNativeAssets() {
    //   // Copy the native assets. The native assets have already been signed in
    //   // buildNativeAssetsMacOS.
    //   final Directory nativeAssetsDirectory = globals.fs
    //       .directory(getBuildDirectory())
    //       .childDirectory('native_assets/ios/');
    //   if (await nativeAssetsDirectory.exists()) {
    //     final ProcessResult rsyncResult = await globals.processManager.run(<Object>[
    //       'rsync',
    //       '-av',
    //       '--filter',
    //       '- .DS_Store',
    //       '--filter',
    //       '- native_assets.yaml',
    //       '--filter',
    //       '- native_assets.json',
    //       nativeAssetsDirectory.path,
    //       modeDirectory.path,
    //     ]);
    //     if (rsyncResult.exitCode != 0) {
    //       throwToolExit('Failed to copy native assets:\n${rsyncResult.stderr}');
    //     }
    //   }
    //   try {
    //     // Delete the intermediaries since they would have been copied into our
    //     // output frameworks.
    //     if (iPhoneBuildOutput.existsSync()) {
    //       iPhoneBuildOutput.deleteSync(recursive: true);
    //     }
    //     if (simulatorBuildOutput.existsSync()) {
    //       simulatorBuildOutput.deleteSync(recursive: true);
    //     }
    //   } finally {
    //     // status.stop();
    //   }
  }
}

/*

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension UpdateFramework: XcodeCommandPlugin {
    /// This entry point is called when operating on an Xcode project.
    func performCommand(context: XcodePluginContext, arguments: [String]) throws {
        debugPrint(context)
    }
}
#endif
*/

class BuildDarwinFrameworkCommand extends BuildFrameworkCommand {
  BuildDarwinFrameworkCommand({
    required super.logger,
    super.flutterVersion,
    required super.buildSystem,
    required bool verboseHelp,
    super.cache,
    super.platform,
  }) : super(verboseHelp: verboseHelp) {
    usesFlavorOption();

    // argParser
    //   ..addFlag(
    //     'universal',
    //     help: '(deprecated) Produce universal frameworks that include all valid architectures.',
    //     hide: !verboseHelp,
    //   )
    //   ..addFlag(
    //     'xcframework',
    //     help: '(deprecated) Produce xcframeworks that include all valid architectures.',
    //     negatable: false,
    //     defaultsTo: true,
    //     hide: !verboseHelp,
    //   );
  }

  @override
  final String name = 'darwin-framework';

  @override
  final String description =
      'Produces .xcframeworks for a Flutter project '
      'and its plugins for integration into existing, plain iOS Xcode projects.\n'
      'This can only be run on macOS hosts.';

  @override
  Future<Set<DevelopmentArtifact>> get requiredArtifacts async => const <DevelopmentArtifact>{
    DevelopmentArtifact.iOS,
    DevelopmentArtifact.macOS,
  };

  @override
  List<DarwinPlatform> get targetPlatforms => <DarwinPlatform>[
    DarwinPlatform.ios,
    DarwinPlatform.macos,
  ];

  @override
  Future<void> validateCommand() async {
    await super.validateCommand();
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
    if (!project.macos.existsSync()) {
      throwToolExit('Project does not support macOS');
    }

    final Directory outputDirectory = globals.fs.directory(
      globals.fs.path.absolute(globals.fs.path.normalize(outputArgument)),
    );
    final List<BuildInfo> buildInfos = await getBuildInfos();

    return buildWithSwiftPM(buildInfos: buildInfos, outputDirectory: outputDirectory);
  }

  @override
  Future<void> produceRegistrantSourceFiles({
    required List<BuildInfo> buildInfos,
    required Directory pluginRegistrantSwiftPackage,
    required List<Plugin> regularPlugins,
    required List<Plugin> devPlugins,
    required List<SwiftPackageTargetDependency> targetDependencies,
  }) async {
    for (final BuildInfo buildInfo in buildInfos) {
      final String xcodeBuildConfiguration = sentenceCase(buildInfo.mode.cliName);
      final Directory modeDirectory = pluginRegistrantSwiftPackage.childDirectory(
        xcodeBuildConfiguration,
      );
      List<Plugin> plugins;
      if (buildInfo.isRelease) {
        plugins = regularPlugins;
      } else {
        plugins = regularPlugins + devPlugins;
      }
      final File implementationFile = modeDirectory
          .childDirectory('Sources')
          .childDirectory(kPluginSwiftPackageName)
          .childFile('GeneratedPluginRegistrant.m');
      final File headerFile = modeDirectory
          .childDirectory('Sources')
          .childDirectory(kPluginSwiftPackageName)
          .childDirectory('include')
          .childFile('GeneratedPluginRegistrant.h');

      await writeDarwinPluginRegistrant(
        project,
        plugins,
        pluginRegistrantHeader: headerFile,
        pluginRegistrantImplementation: implementationFile,
      );
    }
  }
}

/*

import Foundation
import PackagePlugin

@main
struct FlutterValidateConfiguration: CommandPlugin {
    // Entry point for command plugins applied to Swift Packages.
    func performCommand(context: PluginContext, arguments: [String])
        async throws
    {
        let configuration = arguments[1].capitalized
        let dir = context.package.directoryURL
        let symlinkPath = dir.appendingPathComponent("Current").path()

        let fileManager = FileManager.default

        do {
            let targetPath = try fileManager.destinationOfSymbolicLink(
                atPath: symlinkPath
            )
            print(
                "Symlink '\(symlinkPath)' currently points to: '\(targetPath)'"
            )
            if (!targetPath.contains(configuration)) {
                try fileManager.removeItem(atPath: symlinkPath)
                let newTargetPath = "./\(configuration)"
                try fileManager.createSymbolicLink(atPath: symlinkPath, withDestinationPath: newTargetPath)
                let debugNewTargetPath = try fileManager.destinationOfSymbolicLink(
                    atPath: symlinkPath
                )
                print(
                    "Symlink '\(symlinkPath)' now points to: '\(debugNewTargetPath)'"
                )
            }
        } catch {
            print(
                "Error getting symlink for \(symlinkPath): \(error.localizedDescription)"
            )
        }
    }
}

*/
