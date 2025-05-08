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
import '../cache.dart';
import '../flutter_plugins.dart';
import '../globals.dart' as globals;
import '../macos/swift_package_manager.dart';
import '../macos/swift_packages.dart';
import '../plugins.dart';
import '../project.dart';
import '../version.dart';
import 'build.dart';

const String kPluginSwiftPackageName = 'FlutterGeneratedPluginRegistrant';

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
      ..addFlag('incremental', help: 'Only rebuilds if changes have been detected');
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

  bool get remoteFlutterFramework {
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
    ProcessManager processManager,
    String buildMode,
  ) async {
    final Directory xcframeworkOutput = outputDirectory.childDirectory(
      '$frameworkBinaryName.xcframework',
    );

    final String buildDirectory = getIosBuildDirectory();
    final Fingerprinter fingerprinter = appFingerprinter(
      buildDirectory,
      buildMode,
      xcframeworkOutput,
      frameworkBinaryName,
    );
    final bool dependenciesChanged = !fingerprinter.doesFingerprintMatch();

    if (!dependenciesChanged) {
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

  /// Create a FlutterGeneratedPluginRegistrant, that has dependencies on Flutter,
  /// CocoaPods plugins (made into xcframeworks), and SwiftPM plugins.
  Future<void> produceSwiftPackages({
    required XcodeBasedProject project,
    required List<BuildInfo> buildInfos,
    required Directory flutterPluginsSwiftPackage,
    required SupportedPlatform platform,
    required FileSystem fileSystem,
  }) async {
    if (!project.usesSwiftPackageManager) {
      return;
    }
    final Status status = globals.logger.startProgress(
      ' ├─Creating $kPluginSwiftPackageName Swift Package...',
    );

    try {
      final List<Plugin> plugins = await findPlugins(project.parent);
      // Sort the plugins by name to keep ordering stable in generated files.
      plugins.sort((Plugin left, Plugin right) => left.name.compareTo(right.name));

      // Copy Swift Package plugins into a child directory so they are relatively located.
      final Directory copiedPluginsDirectory = flutterPluginsSwiftPackage.childDirectory(
        'FlutterPlugins',
      );
      final List<Plugin> copiedPlugins = await _copySwiftPackagePlugins(
        destination: copiedPluginsDirectory,
        platform: platform,
        plugins: plugins,
        fileSystem: fileSystem,
      );

      for (final BuildInfo buildInfo in buildInfos) {
        final String xcodeBuildConfiguration = sentenceCase(buildInfo.mode.cliName);
        final Directory modeDirectory = flutterPluginsSwiftPackage.childDirectory(
          xcodeBuildConfiguration,
        );

        List<Plugin> filteredPlugins;
        if (buildInfo.isRelease) {
          filteredPlugins = copiedPlugins.where((Plugin p) => !p.isDevDependency).toList();
        } else {
          filteredPlugins = copiedPlugins;
        }

        // Create FlutterPluginRegistrant source files
        await produceRegistrantSourceFiles(
          plugins: filteredPlugins,
          swiftPackageDirectory: modeDirectory,
          swiftPackageName: kPluginSwiftPackageName,
        );
      }

      await _produceFlutterPluginRegistrant(
        fileSystem: fileSystem,
        buildInfos: buildInfos,
        flutterPluginsSwiftPackage: flutterPluginsSwiftPackage,
        plugins: copiedPlugins,
        platform: platform,
      );
    } finally {
      status.stop();
    }
  }

  /// Find all xcframeworks in the [frameworksDir] and create a Swift Package
  /// named [packageName] that produces a library for each.
  (List<SwiftPackageTarget>, List<SwiftPackageTargetDependency>) _generateCocoaPodsBinaryTargets({
    required Directory flutterPluginsSwiftPackage,
    required List<BuildInfo> buildInfos,
    required FileSystem fileSystem,
  }) {
    final List<SwiftPackageTarget> targets = <SwiftPackageTarget>[];
    final List<SwiftPackageTargetDependency> targetDependencies = <SwiftPackageTargetDependency>[];

    // They should all have the same directories, so just pick the first.
    final BuildInfo buildMode = buildInfos[0];

    final Directory cocoapodsFrameworksDirectory = flutterPluginsSwiftPackage
        .childDirectory(sentenceCase(buildMode.mode.cliName))
        .childDirectory('CocoaPodsFrameworks');

    if (cocoapodsFrameworksDirectory.existsSync()) {
      for (final FileSystemEntity file in cocoapodsFrameworksDirectory.listSync()) {
        if (file.basename.endsWith('xcframework')) {
          final String frameworkName = fileSystem.path.basenameWithoutExtension(file.path);
          targets.add(
            SwiftPackageTarget.binaryTarget(
              name: frameworkName,
              relativePath: '\\(mode)/CocoaPodsFrameworks/${file.basename}',
            ),
          );
          targetDependencies.add(SwiftPackageTargetDependency.target(name: frameworkName));
        }
      }
    }
    return (targets, targetDependencies);
  }

  /// Copy plugins with a Package.swift for the given [platform] to [destination].
  Future<List<Plugin>> _copySwiftPackagePlugins({
    required List<Plugin> plugins,
    required Directory destination,
    required SupportedPlatform platform,
    required FileSystem fileSystem,
  }) async {
    final List<Plugin> copiedPlugins = <Plugin>[];
    for (final Plugin plugin in plugins) {
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
  Future<void> _produceFlutterPluginRegistrant({
    required Directory flutterPluginsSwiftPackage,
    required List<BuildInfo> buildInfos,
    required SupportedPlatform platform,
    required List<Plugin> plugins,
    required FileSystem fileSystem,
  }) async {
    const String swiftPackageName = kPluginSwiftPackageName;
    final File manifestFile = flutterPluginsSwiftPackage.childFile('Package.swift');

    final List<Plugin> dependencies = plugins.where((Plugin p) => !p.isDevDependency).toList();
    final List<Plugin> devDependencies = plugins.where((Plugin p) => p.isDevDependency).toList();

    // Get SwiftPM plugins
    final (
      List<SwiftPackagePackageDependency> packageDependencies,
      List<SwiftPackageTargetDependency> targetDependencies,
    ) = SwiftPackageManager.dependenciesForPlugins(
      plugins: dependencies,
      platform: platform,
      fileSystem: fileSystem,
      alterPath: (String path) => fileSystem.path.relative(path, from: manifestFile.parent.path),
    );

    final (
      List<SwiftPackagePackageDependency> devPackageDependencies,
      List<SwiftPackageTargetDependency> devTargetDependencies,
    ) = SwiftPackageManager.dependenciesForPlugins(
      plugins: devDependencies,
      platform: platform,
      fileSystem: fileSystem,
      alterPath: (String path) => fileSystem.path.relative(path, from: manifestFile.parent.path),
    );

    // Add CocoaPods plugins to Package.swift
    final (
      List<SwiftPackageTarget> cocoapodsTargets,
      List<SwiftPackageTargetDependency> cocoapodsTargetDependencies,
    ) = _generateCocoaPodsBinaryTargets(
      flutterPluginsSwiftPackage: flutterPluginsSwiftPackage,
      buildInfos: buildInfos,
      fileSystem: fileSystem,
    );
    targetDependencies.addAll(cocoapodsTargetDependencies);

    // Add App framework as a dependency
    targetDependencies.add(SwiftPackageTargetDependency.target(name: 'App'));

    // Add Flutter framework as a dependency
    // TODO: SPM - relative paths
    packageDependencies.add(
      SwiftPackagePackageDependency.remoteClosedRange(
        repositoryUrl: 'https://github.com/flutter/FlutterFramework',
        lowerLimit: '0.0.0',
        upperLimit: '999.999.999',
      ),
    );
    targetDependencies.add(
      SwiftPackageTargetDependency.product(name: 'Flutter', packageName: 'FlutterFramework'),
    );

    final List<SwiftPackageTarget> targets = <SwiftPackageTarget>[
      SwiftPackageTarget.defaultTarget(
        name: swiftPackageName,
        dependencies: targetDependencies,
        path: '\\(mode)/Sources/$kPluginSwiftPackageName',
      ),
      SwiftPackageTarget.binaryTarget(name: 'App', relativePath: r'\(mode)/App.xcframework'),
      ...cocoapodsTargets,
    ];

    final SwiftPackageProduct generatedProduct = SwiftPackageProduct(
      name: swiftPackageName,
      targets: <String>[swiftPackageName],
      libraryType: SwiftPackageLibraryType.static,
    );

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

    packageDependencies.add(
      SwiftPackagePackageDependency.local(
        packageName: 'FlutterConfigurationPlugin',
        localPath: '../FlutterConfigurationPlugin',
      ),
    );

    final SwiftPackage pluginsPackage = SwiftPackage(
      manifest: manifestFile,
      name: swiftPackageName,
      swiftCodeBeforePackageDefinition: 'let mode = "Debug"',
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
    pluginsPackage.createSwiftPackage();

    await _createFlutterConfigPlugin(flutterPluginsSwiftPackage.parent, manifestFile);
    await _createIncrementalPreBuildActionScript(flutterPluginsSwiftPackage.parent);
  }

  @visibleForOverriding
  Future<void> produceRegistrantSourceFiles({
    required String swiftPackageName,
    required Directory swiftPackageDirectory,
    required List<Plugin> plugins,
  }) async {
    throw UnimplementedError();
  }

  static Fingerprinter appFingerprinter(
    String buildDirectory,
    String buildMode,
    Directory xcframeworkOutput,
    String frameworkBinaryName,
  ) {
    final List<String> childFiles = <String>[];
    if (xcframeworkOutput.existsSync()) {
      for (final FileSystemEntity entity in xcframeworkOutput.listSync(recursive: true)) {
        if (entity is File) {
          childFiles.add(entity.path);
        }
      }
    }
    final Fingerprinter fingerprinter = Fingerprinter(
      fingerprintPath: globals.fs.path.join(
        buildDirectory,
        'build_${buildMode}_ios_$frameworkBinaryName.fingerprint',
      ),
      paths: <String>[
        // '{FLUTTER_ROOT}/packages/flutter_tools/lib/src/build_system/targets/ios.dart',
        // globals.fs.path.join(
        //   Cache.flutterRoot!,
        //   'packages',
        //   'flutter_tools',
        //   'lib',
        //   'src',
        // ),
        ...childFiles,
      ],
      fileSystem: globals.fs,
      logger: globals.logger,
    );
    return fingerprinter;
  }

  Future<void> _createFlutterConfigPlugin(
    Directory outputDirectory,
    File pluginRegistrantManifest,
  ) async {
    final Directory flutterConfigSwiftPlugin = outputDirectory.childDirectory(
      'FlutterConfigurationPlugin',
    );
    ErrorHandlingFileSystem.deleteIfExists(flutterConfigSwiftPlugin, recursive: true);
    final File manifest = flutterConfigSwiftPlugin.childFile('Package.swift')
      ..createSync(recursive: true);
    final File debugPluginSwiftFiles = flutterConfigSwiftPlugin
      .childDirectory('Plugins')
      .childDirectory('Debug')
      .childFile('UpdateConfiguration.swift')..createSync(recursive: true);
    final File profilePluginSwiftFiles = flutterConfigSwiftPlugin
      .childDirectory('Plugins')
      .childDirectory('Profile')
      .childFile('UpdateConfiguration.swift')..createSync(recursive: true);
    final File releasePluginSwiftFiles = flutterConfigSwiftPlugin
      .childDirectory('Plugins')
      .childDirectory('Release')
      .childFile('UpdateConfiguration.swift')..createSync(recursive: true);
    final File packageTemplate = flutterConfigSwiftPlugin
      .childDirectory('Plugins')
      .childFile('template.swift.tmpl')..createSync(recursive: true);
    manifest.writeAsStringSync('''
// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FlutterConfigurationPlugin",
    products: [
        .plugin(name: "FlutterConfigurationPlugin", targets: ["Switch to Debug Mode", "Switch to Profile Mode", "Switch to Release Mode"])
    ],
    targets: [
        .plugin(
            name: "Switch to Debug Mode",
            capability: .command(
                intent: .sourceCodeFormatting,
                permissions: [
                    .writeToPackageDirectory(reason: "Updates package to use the Debug mode Flutter framework"),
                ]
            ),
            path: "Plugins/Debug"
        ),
        .plugin(
            name: "Switch to Profile Mode",
            capability: .command(
                intent: .sourceCodeFormatting,
                permissions: [
                    .writeToPackageDirectory(reason: "Updates package to use the Profile mode Flutter framework")
                ]
            ),
            path: "Plugins/Profile"
        ),
        .plugin(
            name: "Switch to Release Mode",
            capability: .command(
                intent: .sourceCodeFormatting,
                permissions: [
                    .writeToPackageDirectory(reason: "Updates package to use the Release mode Flutter framework")
                ]
            ),
            path: "Plugins/Release"
        ),
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
        let replaced = text.replacingOccurrences(of: "$CONFIGURATION", with: "Release")
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

    packageTemplate.writeAsStringSync(
      pluginRegistrantManifest.readAsStringSync().replaceFirst(
        'let mode = "Debug"',
        r'let mode = "$CONFIGURATION"',
      ),
    );
  }

  Future<void> _createIncrementalPreBuildActionScript(Directory outputDirectory) async {
    final File script = outputDirectory.childFile('pre_build.sh')..createSync(recursive: true);
    script.writeAsStringSync(r'''
#!/usr/bin/env bash
# Copyright 2014 The Flutter Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# exit on error, or usage of unset var
set -euo pipefail

export FLUTTER_APPLICATION_PATH=/Users/vashworth/Development/experiment/flutter/vanilla-flutter-app
export FLUTTER_TARGET=lib/main.dart
export DART_OBFUSCATION=false
export TREE_SHAKE_ICONS=false
export VERBOSE_SCRIPT_LOGGING=YES
export FLUTTER_GENERATED_PLUGIN_REGISTRANT_PACKAGE_SWIFT=/Users/vashworth/Development/experiment/flutter/vanilla-flutter-app/build/ios/framework/FlutterGeneratedPluginRegistrant/Package.swift
export FLUTTER_PACKAGE_SWIFT=/Users/vashworth/Development/experiment/flutter/vanilla-flutter-app/build/ios/framework/flutter/Package.swift

# Needed because if it is set, cd may print the path it changed to.
unset CDPATH

FLUTTER_ROOT=/Users/vashworth/Development/flutter
BIN_DIR="$FLUTTER_ROOT/packages/flutter_tools/bin/"
DART="$FLUTTER_ROOT/bin/dart"

"$DART" "$BIN_DIR/xcode_backend.dart" "$@"
''');
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
