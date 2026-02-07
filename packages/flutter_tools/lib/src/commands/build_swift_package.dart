// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:hooks_runner/hooks_runner.dart' as build_hooks;
import 'package:meta/meta.dart';
import 'package:process/process.dart';
import 'package:unified_analytics/unified_analytics.dart';

import '../artifacts.dart';
import '../base/common.dart';
import '../base/error_handling_io.dart';
import '../base/file_system.dart';
import '../base/fingerprint.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/platform.dart';
import '../base/template.dart';
import '../base/version.dart';
import '../build_info.dart';
import '../build_system/build_system.dart';
import '../build_system/targets/ios.dart';
import '../build_system/targets/macos.dart';
import '../cache.dart';
import '../convert.dart';
import '../darwin/darwin.dart';
import '../features.dart';
import '../flutter_plugins.dart';
import '../globals.dart';
import '../ios/xcodeproj.dart';
import '../isolated/native_assets/native_assets.dart';
import '../macos/cocoapod_utils.dart';
import '../macos/swift_package_manager.dart';
import '../macos/swift_packages.dart';
import '../macos/xcode.dart';
import '../plugins.dart';
import '../project.dart';
import '../runner/flutter_command.dart';
import '../template.dart';
import '../version.dart';
import 'build.dart';

const String kPluginSwiftPackageName = 'FlutterPluginRegistrant';
const String _kPackages = 'Packages';
const String _kFrameworks = 'Frameworks';
const String _kCocoaPods = 'CocoaPods';
const String _kPlugins = 'Plugins';
const String _kNativeAssets = 'NativeAssets';
const String _kSources = 'Sources';
const String _kScripts = 'Scripts';
const String _kFlutterConfigurationPlugin = 'FlutterConfigurationPlugin';
const List<String> _kSupportedPlatforms = ['ios', 'macos'];

class BuildSwiftPackage extends BuildSubCommand {
  BuildSwiftPackage({
    required super.logger,
    required Analytics analytics,
    required Artifacts artifacts,
    required BuildSystem buildSystem,
    required Cache cache,
    required FeatureFlags featureFlags,
    required FileSystem fileSystem,
    required FlutterVersion flutterVersion,
    required Platform platform,
    required ProcessManager processManager,
    required TemplateRenderer templateRenderer,
    required Xcode? xcode,
    required bool verboseHelp,
  }) : _analytics = analytics,
       _artifacts = artifacts,
       _cache = cache,
       _platform = platform,
       _processManager = processManager,
       _buildSystem = buildSystem,
       _featureFlags = featureFlags,
       _fileSystem = fileSystem,
       _flutterVersion = flutterVersion,
       _templateRenderer = templateRenderer,
       _xcode = xcode,
       super(verboseHelp: verboseHelp) {
    usesFlavorOption();
    addTreeShakeIconsFlag();
    usesTargetOption();
    usesPubOption();
    usesDartDefineOption();
    addSplitDebugInfoOption();
    addDartObfuscationOption();
    usesExtraDartFlagOptions(verboseHelp: verboseHelp);
    addEnableExperimentation(hide: !verboseHelp);
    argParser
      ..addOption(
        'output',
        abbr: 'o',
        valueHelp: 'path/to/directory/',
        help: 'Location to write the frameworks.',
      )
      ..addMultiOption(
        'build-mode',
        allowed: ['debug', 'profile', 'release'],
        defaultsTo: ['debug', 'profile', 'release'],
      )
      ..addOption('platform', allowed: _kSupportedPlatforms, defaultsTo: 'ios')
      ..addFlag(
        'static',
        help:
            'Build CocoaPods plugins as static frameworks. Link on, but do not embed these frameworks in the existing Xcode project.',
      )
      ..addFlag(
        'cocoapods-as-binary-targets',
        defaultsTo: true,
        help: 'Adds CocoaPod-only plugins as binary targets in the generated swift package.',
      )
      ..addFlag('remote', help: 'Uses a remote url for the Flutter framework');
  }

  @override
  final name = 'swift-packages';

  @override
  final description =
      'Produces Swift packages and scripts for a Flutter project and its plugins for integration '
      'into existing, native non-Flutter iOS and macOS Xcode projects.\n'
      'This can only be run on macOS hosts.';

  @override
  Future<Set<DevelopmentArtifact>> get requiredArtifacts async {
    switch (_targetPlatform) {
      case FlutterDarwinPlatform.ios:
        return <DevelopmentArtifact>{DevelopmentArtifact.iOS};
      case FlutterDarwinPlatform.macos:
        return <DevelopmentArtifact>{DevelopmentArtifact.macOS};
    }
  }

  final Platform _platform;
  final BuildSystem _buildSystem;
  final FileSystem _fileSystem;
  final Artifacts _artifacts;
  final ProcessManager _processManager;
  final Xcode? _xcode;
  final Cache _cache;
  final Analytics _analytics;
  final TemplateRenderer _templateRenderer;
  final FlutterVersion _flutterVersion;
  final FeatureFlags _featureFlags;

  @override
  bool get supported => _platform.isMacOS;

  FlutterDarwinPlatform get _targetPlatform {
    final String? platformString = stringArg('platform');
    if (platformString != null) {
      final FlutterDarwinPlatform? darwinPlatform = FlutterDarwinPlatform.fromName(platformString);
      if (darwinPlatform != null) {
        return darwinPlatform;
      }
    }
    throwToolExit(
      'The $platformString platform is being targeted, but is not supported for this command. '
      'Supported platforms include: ${_kSupportedPlatforms.join(', ')}.',
    );
  }

  Future<List<BuildInfo>> _getBuildInfos() async {
    final List<String> buildModes = stringsArg('build-mode');
    return <BuildInfo>[
      if (buildModes.contains('debug')) await getBuildInfo(forcedBuildMode: BuildMode.debug),
      if (buildModes.contains('profile')) await getBuildInfo(forcedBuildMode: BuildMode.profile),
      if (buildModes.contains('release')) await getBuildInfo(forcedBuildMode: BuildMode.release),
    ];
  }

  bool get useRemoteFlutterFramework => boolArg('remote');

  @override
  Future<void> validateCommand() async {
    await super.validateCommand();
    _validateTargetPlatform();
    _validateFeatureFlags();
    _validateXcodeVersion();
  }

  /// Validates the Flutter project supports the [_targetPlatform].
  ///
  /// Throws a [ToolExit] if iOS/macOS subproject does not exist.
  void _validateTargetPlatform() {
    switch (_targetPlatform) {
      case FlutterDarwinPlatform.ios:
        if (!project.ios.existsSync()) {
          throwToolExit(
            'The iOS platform is being targeted but the Flutter project does not support iOS. Use '
            'the "--platform" flag to change the targeted platforms.',
          );
        }
      case FlutterDarwinPlatform.macos:
        if (!project.macos.existsSync()) {
          throwToolExit(
            'The macOS platform is being targeted but the Flutter project does not support macOS. Use '
            'the "--platform" flag to change the targeted platforms.',
          );
        }
    }
  }

  /// Validates the SwiftPM feature flag is enabled.
  ///
  /// Throws a [ToolExit] if the flag is disabled.
  void _validateFeatureFlags() {
    if (!_featureFlags.isSwiftPackageManagerEnabled) {
      throwToolExit(
        'Swift Package Manager is disabled. Ensure it is enabled in your global config ("flutter '
        'config --enable-swift-package-manager") and is not disabled in your Flutter '
        "project's pubspec.yaml.",
      );
    }
  }

  /// Validates the Xcode version is equal to or greater than 15.
  ///
  /// Throws a [ToolExit] if the Xcoder version is less than 15.
  void _validateXcodeVersion() {
    final Version? xcodeVersion = _xcode?.currentVersion;
    if (xcodeVersion == null || xcodeVersion.major < 15) {
      throwToolExit(
        'Flutter requires Xcode 15 or greater when using Swift Package Manager. Please ensure '
        'Xcode is installed and meets the version requirements.',
      );
    }
  }

  late BuildSwiftPackageUtils utils = BuildSwiftPackageUtils(
    analytics: _analytics,
    artifacts: _artifacts,
    buildSystem: _buildSystem,
    cache: _cache,
    fileSystem: _fileSystem,
    flutterVersion: _flutterVersion,
    logger: logger,
    platform: _platform,
    processManager: _processManager,
    project: project,
    templateRenderer: _templateRenderer,
    xcode: _xcode!,
  );
  late final pluginRegistrant = FlutterPluginRegistrantSwiftPackage(
    targetPlatform: _targetPlatform,
    utils: utils,
  );
  late final flutterFramework = FlutterFrameworkDependency(
    targetPlatform: _targetPlatform,
    utils: utils,
  );
  late final appFramework = _AppFrameworkAndNativeAssetsDependencies(
    targetPlatform: _targetPlatform,
    utils: utils,
  );
  late final cocoapodFrameworks = _CocoaPodPluginDependencies(
    targetPlatform: _targetPlatform,
    utils: utils,
  );
  late final pluginFrameworks = _FlutterPluginDependencies(
    targetPlatform: _targetPlatform,
    utils: utils,
  );

  @override
  Future<FlutterCommandResult> runCommand() async {
    final String outputArgument =
        stringArg('output') ??
        _fileSystem.path.join(_fileSystem.currentDirectory.path, 'build', 'ios', 'SwiftPackages');

    if (outputArgument.isEmpty) {
      throwToolExit('Please provide a value for --output.');
    }

    final Directory outputDirectory = _fileSystem.directory(
      _fileSystem.path.absolute(_fileSystem.path.normalize(outputArgument)),
    );
    final Directory pluginRegistrantSwiftPackage = outputDirectory.childDirectory(
      kPluginSwiftPackageName,
    );
    pluginRegistrantSwiftPackage.createSync(recursive: true);

    await project.regeneratePlatformSpecificTooling(releaseMode: false);

    final List<BuildInfo> buildInfos = await _getBuildInfos();
    if (buildInfos.isEmpty) {
      throwToolExit('--build-mode is required.');
    }

    final Directory cacheDirectory = outputDirectory.childDirectory('.cache');
    cacheDirectory.createSync(recursive: true);

    final List<Plugin> plugins = await findPlugins(project);
    plugins.sort((Plugin left, Plugin right) => left.name.compareTo(right.name));
    await pluginFrameworks.copyPlugins(
      plugins: plugins,
      outputDirectory: outputDirectory,
      remote: useRemoteFlutterFramework,
    );

    for (final buildInfo in buildInfos) {
      final String xcodeBuildConfiguration = buildInfo.mode.uppercaseName;
      final Directory xcframeworkOutput = pluginRegistrantSwiftPackage
          .childDirectory(xcodeBuildConfiguration)
          .childDirectory(_kFrameworks);
      await _buildXcframeworks(
        buildInfo,
        xcodeBuildConfiguration,
        cacheDirectory,
        xcframeworkOutput,
      );

      await _generateSwiftPackages(
        xcodeBuildConfiguration,
        buildInfo.mode,
        outputDirectory,
        plugins,
        xcframeworkOutput,
        pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
      );
    }
    createSourcesSymlink(pluginRegistrantSwiftPackage, buildInfos.first.mode.uppercaseName);

    await _createBuildScripts(outputDirectory);
    await _createConfigurationSwiftPlugin(outputDirectory, buildInfos);

    return FlutterCommandResult.success();
  }

  /// Copy or build xcframeworks for the Flutter framework, App framework, CocoaPod plugins,
  /// and native assets.
  Future<void> _buildXcframeworks(
    BuildInfo buildInfo,
    String xcodeBuildConfiguration,
    Directory cacheDirectory,
    Directory xcframeworkOutput,
  ) async {
    logger.printStatus('Building for $xcodeBuildConfiguration...');
    if (!useRemoteFlutterFramework) {
      await flutterFramework.generateArtifacts(
        buildMode: buildInfo.mode,
        xcframeworkOutput: xcframeworkOutput,
      );
    }

    await appFramework.generateArtifacts(
      buildInfo: buildInfo,
      cacheDirectory: cacheDirectory.childDirectory('FlutterFrameworks'),
      packageConfigPath: packageConfigPath(),
      targetFile: targetFile,
      xcframeworkOutput: xcframeworkOutput,
    );
    await cocoapodFrameworks.generateArtifacts(
      buildInfo: buildInfo,
      buildStatic: boolArg('static'),
      cacheDirectory: cacheDirectory.childDirectory('CocoaPodsFrameworks'),
      xcframeworkOutput: xcframeworkOutput.childDirectory(_kCocoaPods),
    );
  }

  Future<void> _generateSwiftPackages(
    String xcodeBuildConfiguration,
    BuildMode mode,
    Directory outputDirectory,
    List<Plugin> plugins,
    Directory xcframeworkOutput, {
    required Directory pluginRegistrantSwiftPackage,
  }) async {
    final Status status = logger.startProgress('   ├─Generating swift packages...');
    try {
      final Directory swiftDependencyPackages = pluginRegistrantSwiftPackage
          .childDirectory(xcodeBuildConfiguration)
          .childDirectory(_kPackages);
      ErrorHandlingFileSystem.deleteIfExists(swiftDependencyPackages, recursive: true);

      await flutterFramework.generateSwiftPackage(
        swiftDependencyPackages,
        mode,
        status,
        remote: useRemoteFlutterFramework,
      );

      await pluginRegistrant.generateSwiftPackage(
        cocoapods: cocoapodFrameworks,
        flutterFramework: flutterFramework,
        flutterPlugins: pluginFrameworks,
        appFramework: appFramework,
        outputDirectory: outputDirectory,
        includeCocoaPodBinaryTargets: boolArg('cocoapods-as-binary-targets'),
        plugins: plugins,
        xcodeBuildConfiguration: xcodeBuildConfiguration,
        swiftDependencyPackages: swiftDependencyPackages,
        xcframeworkOutput: xcframeworkOutput,
        pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
      );
    } finally {
      status.stop();
    }
  }

  /// Creates relative symlinks for Sources and Package.swift using the [defaultBuildMode] so that
  /// the package may easily be switched to a different build mode by updating the symlink.
  ///
  /// Creates a symlink from the Sources directory to the './[defaultBuildMode]' directory.
  ///
  /// Creates a symlink from Package.swift to "./[defaultBuildMode]/Package.swift"
  @visibleForTesting
  void createSourcesSymlink(Directory pluginRegistrantSwiftPackage, String defaultBuildMode) {
    final Link sourcesLink = pluginRegistrantSwiftPackage.childLink(_kSources);
    final Link manifestLink = pluginRegistrantSwiftPackage.childLink('Package.swift');
    _createOrUpdateSymlink(sourcesLink, './$defaultBuildMode');
    _createOrUpdateSymlink(manifestLink, './$defaultBuildMode/Package.swift');
  }

  void _createOrUpdateSymlink(Link link, String target) {
    if (link.existsSync()) {
      link.updateSync(target);
    } else {
      link.createSync(target);
    }
  }

  Future<void> _createBuildScripts(Directory outputDirectory) async {
    final Directory scriptsDirectory = outputDirectory.childDirectory(_kScripts);
    ErrorHandlingFileSystem.deleteIfExists(scriptsDirectory, recursive: true);
    final Template template = await Template.fromName(
      _fileSystem.path.join('module', 'ios', 'swift_package_manager', 'Scripts'),
      fileSystem: _fileSystem,
      templateManifest: null,
      logger: logger,
      templateRenderer: _templateRenderer,
    );
    template.render(scriptsDirectory, <String, Object>{}, printStatusWhenWriting: false);
  }

  Future<void> _createConfigurationSwiftPlugin(
    Directory outputDirectory,
    List<BuildInfo> buildInfos,
  ) async {
    final Directory swiftConfigurationPluginDirectory = outputDirectory.childDirectory(
      _kFlutterConfigurationPlugin,
    );
    ErrorHandlingFileSystem.deleteIfExists(swiftConfigurationPluginDirectory, recursive: true);

    final Template template = await Template.fromName(
      _fileSystem.path.join('module', 'ios', 'swift_package_manager', 'FlutterConfigurationPlugin'),
      fileSystem: _fileSystem,
      templateManifest: null,
      logger: logger,
      templateRenderer: _templateRenderer,
    );
    template.render(swiftConfigurationPluginDirectory, <String, Object>{
      'buildModes': [
        for (final buildInfo in buildInfos)
          {'uppercaseName': buildInfo.mode.uppercaseName, 'lowercaseName': buildInfo.mode.cliName},
      ],
      'useRemoteFlutterFramework': useRemoteFlutterFramework,
    }, printStatusWhenWriting: false);
    final Directory directoryPerBuildMode = swiftConfigurationPluginDirectory
        .childDirectory('Plugins')
        .childDirectory('BuildMode');

    // Copy for each build mode (rename for the last)
    for (var index = 0; index <= buildInfos.length - 1; index++) {
      final isLast = index == buildInfos.length - 1;
      final BuildInfo buildInfo = buildInfos[index];
      final Directory destination = swiftConfigurationPluginDirectory
          .childDirectory('Plugins')
          .childDirectory(buildInfo.mode.uppercaseName);
      if (!isLast) {
        copyDirectory(directoryPerBuildMode, destination);
      } else {
        directoryPerBuildMode.renameSync(destination.path);
      }
      final File swiftFile = destination.childFile('UpdateConfiguration.swift');
      swiftFile.writeAsStringSync(
        swiftFile.readAsStringSync().replaceAll(r'$(CONFIGURATION)', buildInfo.mode.uppercaseName),
      );
    }
  }

  /// Create an xcframework from a list of frameworks.
  static Future<void> produceXCFramework({
    required Iterable<Directory> frameworks,
    required String frameworkBinaryName,
    required Directory outputDirectory,
    required ProcessManager processManager,
  }) async {
    final Directory xcframeworkOutput = outputDirectory.childDirectory(
      '$frameworkBinaryName.xcframework',
    );

    ErrorHandlingFileSystem.deleteIfExists(xcframeworkOutput, recursive: true);
    final xcframeworkCommand = <String>[
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
  }
}

@visibleForTesting
class FlutterFrameworkDependency {
  FlutterFrameworkDependency({
    required FlutterDarwinPlatform targetPlatform,
    required BuildSwiftPackageUtils utils,
  }) : _targetPlatform = targetPlatform,
       _utils = utils;

  final FlutterDarwinPlatform _targetPlatform;
  final BuildSwiftPackageUtils _utils;

  /// Copies the Flutter/FlutterMacOS xcframework to [xcframeworkOutput].
  Future<void> generateArtifacts({
    required BuildMode buildMode,
    required Directory xcframeworkOutput,
  }) async {
    final Status status = _utils.logger.startProgress('   ├─Copying Flutter.xcframework...');
    try {
      final String frameworkArtifactPath = _utils.artifacts.getArtifactPath(
        _targetPlatform.xcframeworkArtifact,
        platform: _targetPlatform.targetPlatform,
        mode: buildMode,
      );
      final ProcessResult result = await _utils.processManager.run(<String>[
        'rsync',
        '-av',
        '--delete',
        '--filter',
        '- .DS_Store/',
        '--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r',
        frameworkArtifactPath,
        xcframeworkOutput.path,
      ]);
      if (result.exitCode != 0) {
        throwToolExit(
          'Failed to copy $frameworkArtifactPath (exit ${result.exitCode}:\n'
          '${result.stdout}\n---\n${result.stderr}',
        );
      }
    } finally {
      status.stop();
    }
  }

  /// Creates a FlutterFramework swift package within the [packageDirectory]. This swift package
  /// vends the Flutter xcframework.
  Future<void> generateSwiftPackage(
    Directory packageDirectory,
    BuildMode mode,
    Status status, {
    bool remote = false,
  }) async {
    final product = SwiftPackageProduct(
      name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
      targets: <String>[kFlutterGeneratedFrameworkSwiftPackageTargetName],
    );
    final List<SwiftPackageTargetDependency> targetDependencies = [];
    final List<SwiftPackageTarget> binaryTargets = [];

    targetDependencies.add(
      SwiftPackageTargetDependency.target(
        name: _targetPlatform.binaryName,
        platformCondition: [_targetPlatform.swiftPackagePlatform],
      ),
    );
    binaryTargets.add(
      await binaryTarget(
        packageDirectory: packageDirectory,
        remote: remote,
        platform: _targetPlatform,
        mode: mode,
      ),
    );

    final flutterFrameworkPackage = SwiftPackage(
      manifest: packageDirectory
          .childDirectory(kFlutterGeneratedFrameworkSwiftPackageTargetName)
          .childFile('Package.swift'),
      name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
      platforms: [],
      products: [product],
      dependencies: [],
      targets: [
        SwiftPackageTarget.defaultTarget(
          name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
          dependencies: targetDependencies,
        ),
        ...binaryTargets,
      ],
      templateRenderer: _utils.templateRenderer,
    );
    flutterFrameworkPackage.createSwiftPackage();
  }

  /// The package dependency for the FlutterFramework.
  ///
  /// ```swift
  ///   dependencies: [
  ///     .package(name: "FlutterFramework", path: "Packages/FlutterFramework"),
  /// ```
  SwiftPackagePackageDependency get packageDependency => SwiftPackagePackageDependency(
    name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
    path: '$_kSources/$_kPackages/$kFlutterGeneratedFrameworkSwiftPackageTargetName',
  );

  /// The target dependency for the FlutterFramework.
  ///
  /// ```swift
  ///  .target(
  ///    name: "FlutterPluginRegistrant",
  ///    dependencies: [
  ///      .product(name: "FlutterFramework", package: "FlutterFramework"),
  /// ```
  SwiftPackageTargetDependency get targetDependency => SwiftPackageTargetDependency.product(
    name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
    packageName: kFlutterGeneratedFrameworkSwiftPackageTargetName,
  );

  Future<SwiftPackageTarget> binaryTarget({
    required bool remote,
    required Directory packageDirectory,
    required FlutterDarwinPlatform platform,
    required BuildMode mode,
  }) async {
    if (remote) {
      final Uri url = Uri.parse(
        '${_utils.cache.storageBaseUrl}/flutter_infra_release/flutter/${cache.engineRevision}/${platform.artifactName(mode)}/${platform.artifactZip}',
      );
      final Directory destination = packageDirectory.childDirectory('temp');
      await _utils.cache.downloadFile('url', url, destination);
      final ProcessResult checksumResult = _utils.processManager.runSync([
        'swift',
        'package',
        'compute-checksum',
        platform.artifactZip,
      ], workingDirectory: destination.path);
      return SwiftPackageTarget.remoteBinaryTarget(
        name: platform.binaryName,
        zipUrl: url.toString(),
        zipChecksum: checksumResult.stdout.toString().trim(),
      );
    }
    return SwiftPackageTarget.binaryTarget(
      name: platform.binaryName,
      relativePath: '../../$_kFrameworks/${platform.binaryName}.xcframework',
    );
  }
}

class _AppFrameworkAndNativeAssetsDependencies {
  _AppFrameworkAndNativeAssetsDependencies({
    required FlutterDarwinPlatform targetPlatform,
    required BuildSwiftPackageUtils utils,
  }) : _targetPlatform = targetPlatform,
       _utils = utils;

  final FlutterDarwinPlatform _targetPlatform;
  final BuildSwiftPackageUtils _utils;

  static const String _binaryName = 'App';

  /// Builds an App.framework for every platform and sdk and then combines them into
  /// a single xcframework.
  ///
  /// Intermediate build files are put in the [cacheDirectory]. The final xcframework is copied to
  /// the [xcframeworkOutput].
  Future<void> generateArtifacts({
    required BuildInfo buildInfo,
    required Directory xcframeworkOutput,
    required Directory cacheDirectory,
    required String packageConfigPath,
    required String targetFile,
  }) async {
    const appFrameworkName = '$_binaryName.framework';
    final String xcodeBuildConfiguration = buildInfo.mode.uppercaseName;
    final frameworks = <Directory>[];
    final Map<String, Set<String>> nativeAssetFrameworks = {};
    Status status = _utils.logger.startProgress('   ├─Building $_binaryName.xcframework...');
    try {
      for (final XcodeSdk sdk in _targetPlatform.sdks) {
        final Directory outputBuildDirectory = cacheDirectory
            .childDirectory(xcodeBuildConfiguration)
            .childDirectory(sdk.platformName);
        await _buildFlutterTarget(
          buildInfo: buildInfo,
          outputBuildDirectory: outputBuildDirectory,
          packageConfigPath: packageConfigPath,
          targetFile: targetFile,
          platform: _targetPlatform,
          sdk: sdk,
        );
        final Directory appFramework = outputBuildDirectory.childDirectory(appFrameworkName);
        _findNativeAssetFrameworks(appFramework, nativeAssetFrameworks);
        frameworks.add(appFramework);
      }
      await BuildSwiftPackage.produceXCFramework(
        frameworks: frameworks,
        frameworkBinaryName: _binaryName,
        outputDirectory: xcframeworkOutput,
        processManager: _utils.processManager,
      );
    } finally {
      status.stop();
    }

    ErrorHandlingFileSystem.deleteIfExists(
      xcframeworkOutput.childDirectory(_kNativeAssets),
      recursive: true,
    );
    if (nativeAssetFrameworks.isNotEmpty) {
      status = _utils.logger.startProgress('   ├─Copying native assets...');
      try {
        await _createXcframeworksForNativeAssets(
          nativeAssetFrameworks,
          xcframeworkOutput.childDirectory(_kNativeAssets),
        );
      } finally {
        status.stop();
      }
    }
  }

  Future<void> _buildFlutterTarget({
    required BuildInfo buildInfo,
    required Directory outputBuildDirectory,
    required String packageConfigPath,
    required String targetFile,
    required FlutterDarwinPlatform platform,
    required XcodeSdk sdk,
  }) async {
    final environment = Environment(
      projectDir: _utils.fileSystem.currentDirectory,
      packageConfigPath: packageConfigPath,
      outputDir: outputBuildDirectory,
      buildDir: _utils.project.dartTool.childDirectory('flutter_build'),
      cacheDir: _utils.cache.getRoot(),
      flutterRootDir: _utils.fileSystem.directory(Cache.flutterRoot),
      defines: <String, String>{
        kTargetFile: targetFile,
        kTargetPlatform: getNameForTargetPlatform(platform.targetPlatform),
        ...await _platformDefines(platform, sdk),
        ...buildInfo.toBuildSystemEnvironment(),
        kXcodeBuildScript: kXcodeBuildScriptValueNativeBuild,
      },
      artifacts: _utils.artifacts,
      fileSystem: _utils.fileSystem,
      logger: _utils.logger,
      processManager: _utils.processManager,
      platform: _utils.platform,
      analytics: _utils.analytics,
      engineVersion: _utils.artifacts.usesLocalArtifacts
          ? null
          : _utils.flutterVersion.engineRevision,
      generateDartPluginRegistry: true,
    );
    final Target target = _determineTarget(platform, sdk, buildInfo);

    final BuildResult result = await _utils.buildSystem.build(target, environment);
    if (!result.success) {
      for (final ExceptionMeasurement measurement in result.exceptions.values) {
        _utils.logger.printError(measurement.exception.toString());
      }
      throwToolExit('The $_binaryName.xcframework build failed.');
    }
  }

  void _findNativeAssetFrameworks(
    Directory appFramework,
    Map<String, Set<String>> nativeAssetFrameworks,
  ) {
    final File nativeAssetsManifest = appFramework
        .childDirectory('flutter_assets')
        .childFile('NativeAssetsManifest.json');
    if (!nativeAssetsManifest.existsSync()) {
      return;
    }
    final List<build_hooks.KernelAsset>? assets = NativeAssetsJson.decodeFromJson(
      nativeAssetsManifest.readAsStringSync(),
    );
    assets?.forEach((build_hooks.KernelAsset asset) {
      final build_hooks.KernelAssetPath assetPath = asset.path;
      if (assetPath is build_hooks.KernelAssetAbsolutePath) {
        final [String directory, String name] = assetPath.uri.pathSegments;
        nativeAssetFrameworks.putIfAbsent(asset.id, () => <String>{}).add(directory);
      }
    });
  }

  Future<void> _createXcframeworksForNativeAssets(
    Map<String, Set<String>> nativeAssetFrameworks,
    Directory xcframeworkOutput,
  ) async {
    final Directory nativeAssetsDirectory = _utils.fileSystem
        .directory(getBuildDirectory())
        .childDirectory('native_assets/ios/');
    if (!await nativeAssetsDirectory.exists()) {
      return;
    }
    for (final String key in nativeAssetFrameworks.keys) {
      // Parse package name from key
      // package:<package>/<name>
      final String packageName = key.replaceAll('package:', '').split('/').first;
      final List<Directory> frameworks = nativeAssetFrameworks[key]!
          .map((String directoryName) => nativeAssetsDirectory.childDirectory(directoryName))
          .toList();
      await BuildSwiftPackage.produceXCFramework(
        frameworks: frameworks,
        frameworkBinaryName: packageName,
        outputDirectory: xcframeworkOutput,
        processManager: _utils.processManager,
      );
    }
  }

  /// The target dependency for the App framework.
  ///
  /// ```swift
  ///  .target(
  ///    name: "FlutterPluginRegistrant",
  ///    dependencies: [
  ///      .target(name: "App"),
  /// ```
  SwiftPackageTargetDependency get targetDependency =>
      SwiftPackageTargetDependency.target(name: _binaryName);

  /// The binary target for the App framework.
  ///
  /// ```swift
  ///   .binaryTarget(
  ///     name: "App",
  ///     path: "Frameworks/App.xcframework"
  ///   )
  /// ```
  SwiftPackageTarget get binaryTarget => SwiftPackageTarget.binaryTarget(
    name: _binaryName,
    relativePath: '$_kSources/$_kFrameworks/$_binaryName.xcframework',
  );

  /// Determine the target to build based on the [platform], [sdk], and [buildInfo].
  Target _determineTarget(FlutterDarwinPlatform platform, XcodeSdk sdk, BuildInfo buildInfo) {
    switch (platform) {
      case FlutterDarwinPlatform.ios:
        // Always build debug for simulator.
        if (buildInfo.isDebug || sdk.sdkType == EnvironmentType.simulator) {
          return const DebugIosApplicationBundle();
        } else if (buildInfo.isProfile) {
          return const ProfileIosApplicationBundle();
        } else {
          return const ReleaseIosApplicationBundle();
        }
      case FlutterDarwinPlatform.macos:
        if (buildInfo.isDebug) {
          return const DebugMacOSBundleFlutterAssets();
        } else if (buildInfo.isProfile) {
          return const ProfileMacOSBundleFlutterAssets();
        } else {
          return const ReleaseMacOSBundleFlutterAssets();
        }
    }
  }

  /// Platform specific defines.
  Future<Map<String, String>> _platformDefines(FlutterDarwinPlatform platform, XcodeSdk sdk) async {
    switch (platform) {
      case FlutterDarwinPlatform.ios:
        return <String, String>{
          kIosArchs: defaultIOSArchsForEnvironment(
            sdk.sdkType,
            _utils.artifacts,
          ).map((DarwinArch e) => e.name).join(' '),
          kSdkRoot: await _utils.xcode.sdkLocation(sdk.sdkType),
        };
      case FlutterDarwinPlatform.macos:
        return <String, String>{
          kDarwinArchs: defaultMacOSArchsForEnvironment(
            _utils.artifacts,
          ).map((DarwinArch e) => e.name).join(' '),
        };
    }
  }

  (List<SwiftPackageTargetDependency>, List<SwiftPackageTarget>) generateDependency({
    required Directory xcframeworkOutput,
    required FileSystem fileSystem,
  }) {
    return generateDependenciesFromDirectory(
      fileSystem: fileSystem,
      dirName: _kNativeAssets,
      xcframeworkDirectory: xcframeworkOutput.childDirectory(_kNativeAssets),
    );
  }
}

class _CocoaPodPluginDependencies {
  _CocoaPodPluginDependencies({
    required FlutterDarwinPlatform targetPlatform,
    required BuildSwiftPackageUtils utils,
  }) : _targetPlatform = targetPlatform,
       _utils = utils;

  final FlutterDarwinPlatform _targetPlatform;
  final BuildSwiftPackageUtils _utils;

  /// Builds CocoaPod plugins for every platform and sdk into frameworks and then combines them into
  /// a single xcframework for each.
  ///
  /// Intermediate build files are put in the [cacheDirectory]. The final xcframeworks are copied to
  /// the [xcframeworkOutput].
  Future<void> generateArtifacts({
    required BuildInfo buildInfo,
    required Directory cacheDirectory,
    required Directory xcframeworkOutput,
    required bool buildStatic,
  }) async {
    final Status status = _utils.logger.startProgress('   ├─Building CocoaPods...');
    var skipped = false;
    try {
      final String xcodeBuildConfiguration = buildInfo.mode.uppercaseName;
      final bool dependenciesChanged = _hasDependenciesChanged(
        cacheDirectory.path,
        xcframeworkOutput,
        buildInfo.mode.cliName,
      );
      if (!dependenciesChanged && xcframeworkOutput.existsSync()) {
        skipped = true;
        return;
      } else if (dependenciesChanged) {
        ErrorHandlingFileSystem.deleteIfExists(cacheDirectory, recursive: true);
        ErrorHandlingFileSystem.deleteIfExists(xcframeworkOutput, recursive: true);
      }

      final createdFrameworks = <String, List<Directory>>{};

      final XcodeBasedProject xcodeProject = _targetPlatform.xcodeProject(_utils.project);
      final Directory podsDirectory = xcodeProject.hostAppRoot.childDirectory('Pods');
      if (!podsDirectory.existsSync() || !xcodeProject.podfile.existsSync()) {
        return;
      }
      await processPodsIfNeeded(xcodeProject, _targetPlatform.buildDirectory(), buildInfo.mode);

      for (final XcodeSdk sdk in _targetPlatform.sdks) {
        final Map<String, List<Directory>> sdkCreatedFrameworks = await _buildCocoaPodsForSdk(
          sdk: sdk,
          platform: _targetPlatform,
          xcodeBuildConfiguration: xcodeBuildConfiguration,
          buildStatic: buildStatic,
          cacheDirectory: cacheDirectory,
          podsDirectory: podsDirectory,
        );
        sdkCreatedFrameworks.forEach((String name, List<Directory> frameworks) {
          createdFrameworks.putIfAbsent(name, () => <Directory>[]).addAll(frameworks);
        });
      }

      for (final String frameworkName in createdFrameworks.keys) {
        final List<Directory>? frameworkDirectories = createdFrameworks[frameworkName];
        if (frameworkDirectories != null) {
          await BuildSwiftPackage.produceXCFramework(
            frameworks: frameworkDirectories,
            frameworkBinaryName: frameworkName,
            outputDirectory: xcframeworkOutput,
            processManager: _utils.processManager,
          );
        }
      }
      _writeFingerprint(cacheDirectory.path, xcframeworkOutput, buildInfo.mode.cliName);
    } finally {
      status.stop();
      if (skipped) {
        _utils.logger.printStatus(
          '   │   └── Skipping building CocoaPod plugins. No change detected',
        );
      }
    }
  }

  /// The target dependencies and binary targets for the CocoaPod plugin xcframeworks.
  ///
  /// ```swift
  ///  .target(
  ///    name: "FlutterPluginRegistrant",
  ///    dependencies: [
  ///      .target(name: "cocoapod_plugin_a"),
  ///
  ///    ...
  ///
  ///   .binaryTarget(
  ///     name: "cocoapod_plugin_a",
  ///     path: "Frameworks/CocoaPods/cocoapod_plugin_a.xcframework"
  ///   )
  /// ```
  (List<SwiftPackageTargetDependency>, List<SwiftPackageTarget>) generateDependency({
    required Directory xcframeworkOutput,
    required FileSystem fileSystem,
  }) {
    return generateDependenciesFromDirectory(
      fileSystem: fileSystem,
      dirName: _kCocoaPods,
      xcframeworkDirectory: xcframeworkOutput.childDirectory(_kCocoaPods),
    );
  }

  /// Builds CocoaPod plugins into frameworks for the given [xcodeBuildConfiguration], [platform],
  /// and [sdk].
  Future<Map<String, List<Directory>>> _buildCocoaPodsForSdk({
    required XcodeSdk sdk,
    required FlutterDarwinPlatform platform,
    required String xcodeBuildConfiguration,
    required bool buildStatic,
    required Directory cacheDirectory,
    required Directory podsDirectory,
  }) async {
    final Directory outputBuildDirectory = cacheDirectory
        .childDirectory(xcodeBuildConfiguration)
        .childDirectory(sdk.platformName);
    final String configuration = _configurationForSdkType(sdk, xcodeBuildConfiguration);
    final pluginsBuildCommand = <String>[
      ..._utils.xcode.xcrunCommand(),
      'xcodebuild',
      '-alltargets',
      '-sdk',
      sdk.platformName,
      '-configuration',
      configuration,
      'SYMROOT=${outputBuildDirectory.path}',
      'ONLY_ACTIVE_ARCH=NO', // No device targeted, so build all valid architectures.
      'BUILD_LIBRARY_FOR_DISTRIBUTION=YES',
      if (buildStatic) 'MACH_O_TYPE=staticlib',
    ];
    final ProcessResult buildPluginsResult = await _utils.processManager.run(
      pluginsBuildCommand,
      workingDirectory: podsDirectory.path,
    );
    if (buildPluginsResult.exitCode != 0) {
      throwToolExit('Unable to build plugin frameworks: ${buildPluginsResult.stderr}');
    }

    final Directory configurationBuildDir;
    if (platform == FlutterDarwinPlatform.macos) {
      configurationBuildDir = outputBuildDirectory.childDirectory(configuration);
    } else {
      configurationBuildDir = outputBuildDirectory.childDirectory('$configuration-${sdk.name}');
    }

    return _findFrameworks(platform, configurationBuildDir);
  }

  /// Iterates through the build files and find .frameworks
  ///
  /// ex.
  /// ```text
  /// > Debug-iphoneos
  ///   > plugin_a
  ///     > plugin_a.framework
  /// ```
  Future<Map<String, List<Directory>>> _findFrameworks(
    FlutterDarwinPlatform platform,
    Directory configurationBuildDir,
  ) async {
    final sdkCreatedFrameworks = <String, List<Directory>>{};

    final Iterable<Directory> products = configurationBuildDir
        .listSync(followLinks: false)
        .whereType<Directory>();
    for (final builtProduct in products) {
      for (final Directory podProduct
          in builtProduct.listSync(followLinks: false).whereType<Directory>()) {
        final String podFrameworkName = podProduct.basename;
        if (_utils.fileSystem.path.extension(podFrameworkName) != '.framework') {
          continue;
        }
        final String binaryName = _utils.fileSystem.path.basenameWithoutExtension(podFrameworkName);
        sdkCreatedFrameworks.putIfAbsent(binaryName, () => <Directory>[]).add(podProduct);
      }
    }
    return sdkCreatedFrameworks;
  }

  bool _hasDependenciesChanged(
    String cacheDirectoryPath,
    Directory cocoapodFrameworkDirectory,
    String xcodeBuildConfiguration,
  ) {
    final Fingerprinter fingerprinter = _cocoapodsFingerprinter(
      cacheDirectoryPath,
      cocoapodFrameworkDirectory,
      xcodeBuildConfiguration,
    );
    return !fingerprinter.doesFingerprintMatch();
  }

  void _writeFingerprint(
    String cacheDirectoryPath,
    Directory cocoapodFrameworkDirectory,
    String xcodeBuildConfiguration,
  ) {
    final Fingerprinter fingerprinter = _cocoapodsFingerprinter(
      cacheDirectoryPath,
      cocoapodFrameworkDirectory,
      xcodeBuildConfiguration,
    );
    fingerprinter.writeFingerprint();
  }

  Fingerprinter _cocoapodsFingerprinter(
    String cacheDirectoryPath,
    Directory cocoapodFrameworkDirectory,
    String xcodeBuildConfiguration,
  ) {
    final fingerprintedFiles = <String>[];

    // Add already created xcframeworks
    if (cocoapodFrameworkDirectory.existsSync()) {
      for (final FileSystemEntity entity in cocoapodFrameworkDirectory.listSync(recursive: true)) {
        if (entity is File) {
          fingerprintedFiles.add(entity.path);
        }
      }
    }

    // If the Xcode project, Podfile, generated plugin Swift Package, or podhelper
    // have changed since last run, pods should be updated.
    final XcodeBasedProject xcodeProject = _targetPlatform.xcodeProject(_utils.project);
    fingerprintedFiles.add(xcodeProject.xcodeProjectInfoFile.path);
    fingerprintedFiles.add(xcodeProject.podfile.path);
    if (xcodeProject.flutterPluginSwiftPackageManifest.existsSync()) {
      fingerprintedFiles.add(xcodeProject.flutterPluginSwiftPackageManifest.path);
    }

    final fingerprinter = Fingerprinter(
      fingerprintPath: _utils.fileSystem.path.join(
        cacheDirectoryPath,
        'build_${xcodeBuildConfiguration}_pod_inputs.fingerprint',
      ),
      paths: <String>[
        _utils.fileSystem.path.join(
          Cache.flutterRoot!,
          'packages',
          'flutter_tools',
          'bin',
          'podhelper.rb',
        ),
        _utils.fileSystem.path.join(
          Cache.flutterRoot!,
          'packages',
          'flutter_tools',
          'lib',
          'src',
          'commands',
          'build_swift_package.dart',
        ),
        ...fingerprintedFiles,
      ],
      fileSystem: _utils.fileSystem,
      logger: _utils.logger,
    );
    return fingerprinter;
  }

  String _configurationForSdkType(XcodeSdk sdk, String configuration) {
    if (sdk.sdkType == EnvironmentType.simulator) {
      // Always build debug for simulator.
      return BuildMode.debug.uppercaseName;
    } else {
      return configuration;
    }
  }
}

class _FlutterPluginDependencies {
  _FlutterPluginDependencies({
    required FlutterDarwinPlatform targetPlatform,
    required BuildSwiftPackageUtils utils,
  }) : _targetPlatform = targetPlatform,
       _utils = utils;

  final FlutterDarwinPlatform _targetPlatform;
  final BuildSwiftPackageUtils _utils;

  Map<SwiftPackagePlatform, SwiftPackageSupportedPlatform> highestSupportedVersion = {};

  Future<void> copyPlugins({
    required List<Plugin> plugins,
    required Directory outputDirectory,
    required bool remote,
  }) async {
    final Directory cachedPluginsDirectory = outputDirectory.childDirectory(_kPlugins);
    try {
      ErrorHandlingFileSystem.deleteIfExists(cachedPluginsDirectory, recursive: true);
    } on FileSystemException catch (e, stackTrace) {
      // Delete may fail due to Xcode writing hidden files to the directory at the same time.
      logger.printTrace('Failed to delete ${cachedPluginsDirectory.path}: $e\n$stackTrace');
    }
    for (final plugin in plugins) {
      // If plugin does not support the platform, skip it.
      if (!plugin.supportSwiftPackageManagerForPlatform(_utils.fileSystem, _targetPlatform)) {
        continue;
      }

      // Copy plugins from pubcache to swift package cache
      // The entire plugin is copied (rather than just the swift package) to maintain any relative
      // links within the plugin.
      final Directory pluginDestination = cachedPluginsDirectory.childDirectory(plugin.name)
        ..createSync(recursive: true);
      copyDirectory(
        _utils.fileSystem.directory(plugin.path),
        pluginDestination,
        shouldCopyDirectory: (Directory dir) => !dir.path.endsWith('example'),
      );

      final String? swiftPackagePath = plugin.pluginSwiftPackagePath(
        _utils.fileSystem,
        _targetPlatform.name,
        overridePath: pluginDestination.path,
      );
      if (swiftPackagePath == null) {
        throwToolExit('1Failed to copy ${plugin.name}.');
      }

      final File swiftPackageManifest = _utils.fileSystem.file(
        _utils.fileSystem.path.join(swiftPackagePath, 'Package.swift'),
      );
      if (!swiftPackageManifest.existsSync()) {
        throwToolExit('2Failed to copy ${plugin.name}');
      }

      await _parseSwiftPackage(swiftPackagePath, swiftPackageManifest, remote: remote);
    }
  }

  Future<(List<SwiftPackagePackageDependency>, List<SwiftPackageTargetDependency>)>
  generatePluginDependencies({
    required Directory swiftDependencyPackages,
    required List<Plugin> plugins,
    required Directory outputDirectory,
  }) async {
    final List<SwiftPackagePackageDependency> packageDependencies = [];
    final List<SwiftPackageTargetDependency> targetDependencies = [];
    final Directory cachedPluginsDirectory = outputDirectory.childDirectory(_kPlugins);
    for (final plugin in plugins) {
      final Directory pluginDestination = cachedPluginsDirectory.childDirectory(plugin.name);
      if (!plugin.supportSwiftPackageManagerForPlatform(_utils.fileSystem, _targetPlatform)) {
        continue;
      }
      final String? swiftPackagePath = plugin.pluginSwiftPackagePath(
        _utils.fileSystem,
        _targetPlatform.name,
        overridePath: pluginDestination.path,
      );
      if (swiftPackagePath == null) {
        throwToolExit('Failed to find copied ${plugin.name}');
      }

      final Link linkToCache = swiftDependencyPackages.childLink(plugin.name);
      if (linkToCache.existsSync()) {
        continue;
      }
      linkToCache.createSync(
        _utils.fileSystem.path.relative(swiftPackagePath, from: linkToCache.parent.path),
        recursive: true,
      );

      packageDependencies.add(
        SwiftPackagePackageDependency(
          name: plugin.name,
          path: '$_kSources/$_kPackages/${plugin.name}',
        ),
      );
      targetDependencies.add(
        SwiftPackageTargetDependency.product(
          name: plugin.name.replaceAll('_', '-'),
          packageName: plugin.name,
          platformCondition: plugin.isDarwinPluginWithSharedSources()
              ? [SwiftPackagePlatform.ios, SwiftPackagePlatform.macos]
              : [_targetPlatform.swiftPackagePlatform],
        ),
      );
    }

    return (packageDependencies, targetDependencies);
  }

  Future<void> _parseSwiftPackage(
    String packagePath,
    File swiftPackageManifest, {
    bool remote = false,
  }) async {
    try {
      final ProcessResult parsedManifest = await _utils.processManager.run([
        'swift',
        'package',
        'dump-package',
      ], workingDirectory: packagePath);
      final SwiftPackage? pluginSwiftPackage = SwiftPackage.fromJson(
        json.decode(parsedManifest.stdout.toString()) as Map<String, Object?>,
        manifest: swiftPackageManifest,
        templateRenderer: _utils.templateRenderer,
      );
      if (pluginSwiftPackage == null) {
        return;
      }

      // Parse the plugins for the minimum deployment target.
      // The FlutterPluginRegistrant needs to match the highest version. Otherwise, it will error.
      for (final SwiftPackageSupportedPlatform swiftPlatform in pluginSwiftPackage.platforms) {
        final SwiftPackageSupportedPlatform? currentHighest =
            highestSupportedVersion[swiftPlatform.platform];
        if (currentHighest == null || currentHighest.version < swiftPlatform.version) {
          highestSupportedVersion[swiftPlatform.platform] = swiftPlatform;
        }
      }
      if (remote) {
        // Parse swift package for FlutterFramework dependency and add if not found
        // If it's not found as a package dependency, add it and add it as a dependency for each target
        var hasDependencyOnFlutter = false;
        for (final SwiftPackagePackageDependency dependency in pluginSwiftPackage.dependencies) {
          if (dependency.name == kFlutterGeneratedFrameworkSwiftPackageTargetName) {
            hasDependencyOnFlutter = true;
            break;
          }
        }
        if (!hasDependencyOnFlutter) {
          // Add the Flutter framework as a dependency for each target
          final ProcessResult addDependencyResult = await _utils.processManager.run([
            'swift',
            'package',
            'add-dependency',
            '../$kFlutterGeneratedFrameworkSwiftPackageTargetName',
            '--type',
            'path',
          ], workingDirectory: packagePath);
          if (addDependencyResult.exitCode != 0) {
            _utils.logger.printTrace(
              'Failed to add $kFlutterGeneratedFrameworkSwiftPackageTargetName as a package dependency to $packagePath',
            );
            return;
          }
          for (final SwiftPackageTarget target in pluginSwiftPackage.targets) {
            final ProcessResult addDependencyResult = await _utils.processManager.run([
              'swift',
              'package',
              'add-target-dependency',
              kFlutterGeneratedFrameworkSwiftPackageTargetName,
              target.name,
              '--package',
              kFlutterGeneratedFrameworkSwiftPackageTargetName,
            ], workingDirectory: packagePath);
            if (addDependencyResult.exitCode != 0) {
              _utils.logger.printTrace(
                'Failed to add $kFlutterGeneratedFrameworkSwiftPackageTargetName as a target dependency of ${target.name} to $packagePath',
              );
            }
          }
        }
      }
    } on Exception catch (e, stackTrace) {
      _utils.logger.printTrace('Failed to decode $packagePath: $e\n$stackTrace');
      return;
    }
  }
}

class FlutterPluginRegistrantSwiftPackage {
  FlutterPluginRegistrantSwiftPackage({
    required FlutterDarwinPlatform targetPlatform,
    required BuildSwiftPackageUtils utils,
  }) : _targetPlatform = targetPlatform,
       _utils = utils;

  final FlutterDarwinPlatform _targetPlatform;
  final BuildSwiftPackageUtils _utils;

  // Create FlutterPluginRegistrant Swift Package with dependencies on the
  // swift pacakge plugins, CocoaPod xcframeworks, and Flutter/App xcframeworks.
  Future<void> generateSwiftPackage({
    required Directory pluginRegistrantSwiftPackage,
    required String xcodeBuildConfiguration,
    required List<Plugin> plugins,
    required Directory outputDirectory,
    required _CocoaPodPluginDependencies cocoapods,
    required _FlutterPluginDependencies flutterPlugins,
    required FlutterFrameworkDependency flutterFramework,
    required _AppFrameworkAndNativeAssetsDependencies appFramework,
    required bool includeCocoaPodBinaryTargets,
    required Directory swiftDependencyPackages,
    required Directory xcframeworkOutput,
  }) async {
    List<SwiftPackageTargetDependency> cocoapodTargetDependencies = [];
    List<SwiftPackageTarget> cocoapodBinaryTargets = [];
    if (includeCocoaPodBinaryTargets) {
      (cocoapodTargetDependencies, cocoapodBinaryTargets) = cocoapods.generateDependency(
        xcframeworkOutput: xcframeworkOutput,
        fileSystem: _utils.fileSystem,
      );
    }

    final (
      List<SwiftPackageTargetDependency> nativeAssetsTargetDependencies,
      List<SwiftPackageTarget> nativeAssetsBinaryTargets,
    ) = appFramework.generateDependency(
      xcframeworkOutput: xcframeworkOutput,
      fileSystem: _utils.fileSystem,
    );
    final (
      List<SwiftPackagePackageDependency> pluginPackageDependencies,
      List<SwiftPackageTargetDependency> pluginTargetDependencies,
    ) = await flutterPlugins.generatePluginDependencies(
      plugins: plugins,
      outputDirectory: outputDirectory,
      swiftDependencyPackages: swiftDependencyPackages,
    );

    final List<SwiftPackageTargetDependency> targetDependencies = [
      flutterFramework.targetDependency,
      appFramework.targetDependency,
      ...pluginTargetDependencies,
      ...cocoapodTargetDependencies,
      ...nativeAssetsTargetDependencies,
    ];
    final List<SwiftPackageTarget> binaryTargets = [
      appFramework.binaryTarget,
      ...cocoapodBinaryTargets,
      ...nativeAssetsBinaryTargets,
    ];
    final List<SwiftPackagePackageDependency> packageDependencies = [
      flutterFramework.packageDependency,
      ...pluginPackageDependencies,
      SwiftPackagePackageDependency(
        name: 'FlutterConfigurationPlugin',
        path: '../FlutterConfigurationPlugin',
      ),
    ];

    const String swiftPackageName = kPluginSwiftPackageName;
    final File manifestFile = pluginRegistrantSwiftPackage
        .childDirectory(xcodeBuildConfiguration)
        .childFile('Package.swift');

    final generatedProduct = SwiftPackageProduct(
      name: swiftPackageName,
      targets: <String>[swiftPackageName],
      libraryType: SwiftPackageLibraryType.static,
    );

    final targets = <SwiftPackageTarget>[
      SwiftPackageTarget.defaultTarget(name: swiftPackageName, dependencies: targetDependencies),
      ...binaryTargets,
    ];

    final pluginsPackage = SwiftPackage(
      manifest: manifestFile,
      name: swiftPackageName,
      platforms: <SwiftPackageSupportedPlatform>[
        highestSupportedVersionForPlatform(FlutterDarwinPlatform.ios, flutterPlugins),
        highestSupportedVersionForPlatform(FlutterDarwinPlatform.macos, flutterPlugins),
      ],
      products: <SwiftPackageProduct>[generatedProduct],
      dependencies: packageDependencies,
      targets: targets,
      templateRenderer: _utils.templateRenderer,
      swiftCodeBeforePackageDefinition: '// $xcodeBuildConfiguration',
    );

    pluginsPackage.createSwiftPackage(generateEmptySources: false);

    await _generateSourceFiles(
      pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
      plugins: plugins,
      xcodeBuildConfiguration: xcodeBuildConfiguration,
    );
  }

  SwiftPackageSupportedPlatform highestSupportedVersionForPlatform(
    FlutterDarwinPlatform platform,
    _FlutterPluginDependencies flutterPlugins,
  ) {
    SwiftPackageSupportedPlatform? supportedPlatform =
        flutterPlugins.highestSupportedVersion[platform.swiftPackagePlatform];
    if (supportedPlatform == null ||
        supportedPlatform.version < platform.supportedPackagePlatform.version) {
      supportedPlatform = platform.supportedPackagePlatform;
    }
    return supportedPlatform;
  }

  /// Generates GeneratedPluginRegistrant source files.
  Future<void> _generateSourceFiles({
    required Directory pluginRegistrantSwiftPackage,
    required List<Plugin> plugins,
    required String xcodeBuildConfiguration,
  }) async {
    final Directory sourcesDirectory = pluginRegistrantSwiftPackage.childDirectory(
      xcodeBuildConfiguration,
    );
    ErrorHandlingFileSystem.deleteIfExists(
      sourcesDirectory.childDirectory(kPluginSwiftPackageName),
      recursive: true,
    );
    final File swiftFile = sourcesDirectory
        .childDirectory(kPluginSwiftPackageName)
        .childFile('GeneratedPluginRegistrant.swift');
    if (_targetPlatform == FlutterDarwinPlatform.ios) {
      await writeIOSPluginRegistrant(
        _utils.project,
        plugins,
        swiftPluginRegistrant: swiftFile,
        templateRenderer: _utils.templateRenderer,
      );
    } else if (_targetPlatform == FlutterDarwinPlatform.macos) {
      await writeMacOSPluginRegistrant(
        _utils.project,
        plugins,
        pluginRegistrantImplementation: swiftFile,
        templateRenderer: _utils.templateRenderer,
      );
    }
  }
}

@visibleForTesting
class BuildSwiftPackageUtils {
  BuildSwiftPackageUtils({
    required this.analytics,
    required this.artifacts,
    required this.buildSystem,
    required this.cache,
    required this.fileSystem,
    required this.flutterVersion,
    required this.logger,
    required this.platform,
    required this.processManager,
    required this.project,
    required this.templateRenderer,
    required this.xcode,
  });

  final Analytics analytics;
  final Artifacts artifacts;
  final BuildSystem buildSystem;
  final Cache cache;
  final FileSystem fileSystem;
  final FlutterVersion flutterVersion;
  final Logger logger;
  final Platform platform;
  final ProcessManager processManager;
  final FlutterProject project;
  final TemplateRenderer templateRenderer;
  final Xcode xcode;
}

(List<SwiftPackageTargetDependency>, List<SwiftPackageTarget>) generateDependenciesFromDirectory({
  required Directory xcframeworkDirectory,
  required FileSystem fileSystem,
  required String dirName,
}) {
  final targetDependencies = <SwiftPackageTargetDependency>[];
  final binaryTargets = <SwiftPackageTarget>[];

  if (xcframeworkDirectory.existsSync()) {
    for (final FileSystemEntity entity in xcframeworkDirectory.listSync()) {
      if (entity is Directory && entity.basename.endsWith('xcframework')) {
        final String frameworkName = fileSystem.path.basenameWithoutExtension(entity.path);
        final platformConditions = <SwiftPackagePlatform>{};
        for (final FileSystemEntity subfile in entity.listSync()) {
          if (subfile.basename.contains(FlutterDarwinPlatform.ios.name)) {
            platformConditions.add(SwiftPackagePlatform.ios);
          } else {
            if (subfile.basename.contains(FlutterDarwinPlatform.macos.name)) {
              platformConditions.add(SwiftPackagePlatform.macos);
            }
          }
        }
        targetDependencies.add(
          SwiftPackageTargetDependency.target(
            name: frameworkName,
            platformCondition: platformConditions.toList(),
          ),
        );
        binaryTargets.add(
          SwiftPackageTarget.binaryTarget(
            name: frameworkName,
            relativePath: '$_kSources/$_kFrameworks/$dirName/${entity.basename}',
          ),
        );
      }
    }
  }
  return (targetDependencies, binaryTargets);
}
