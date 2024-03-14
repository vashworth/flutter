// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:process/process.dart';

import '../artifacts.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/project_migrator.dart';
import '../base/template.dart';
import '../build_info.dart';
import '../ios/xcodeproj.dart';
import '../migrations/flutter_package_migration.dart';
import '../plugins.dart';
import '../project.dart';
import '../template.dart';

// TODO: SPM - comment
class SwiftPackageManager {
  SwiftPackageManager({
    required Artifacts artifacts,
    required FileSystem fileSystem,
    required Logger logger,
    required TemplateRenderer templateRenderer,
    required ProcessManager processManager,
    required XcodeProjectInterpreter xcodeProjectInterpreter,
  }) : _artifacts = artifacts,
    _fileSystem = fileSystem,
    _logger = logger,
    _processManager = processManager,
    _templateRenderer = templateRenderer,
    _xcodeProjectInterpreter = xcodeProjectInterpreter;

  final Artifacts _artifacts;
  final FileSystem _fileSystem;
  final TemplateRenderer _templateRenderer;
  final Logger _logger;
  final ProcessManager _processManager;
  final XcodeProjectInterpreter _xcodeProjectInterpreter;

  static const String _defaultFlutterPluginsSwiftPackageName = 'FlutterPackage';

  static String flutterPackagesPath(XcodeBasedProject project) {
    return '${project.hostAppRoot.path}/Flutter/Packages/$_defaultFlutterPluginsSwiftPackageName';
  }

  static Directory flutterPackageDirectory(XcodeBasedProject project, FileSystem fileSystem) {
    return fileSystem.directory(flutterPackagesPath(project));
  }

  Future<void> generate(
    List<Plugin> plugins,
    SupportedPlatform platform,
    XcodeBasedProject project, {
    String? overrideSwiftPackagePath,
    String? overrideSwiftPackageName,
    bool includeFlutterFramework = true,
    bool migrateApp = true,
    bool skipIfNoDependencies = true,
    SwiftPackageLibraryType? libraryType,
  }) async {
    _validatePlatform(platform);

    final (List<SwiftPackagePackageDependency> packageDependencies, List<SwiftPackageTargetDependency> targetProducts) = _dependenciesForPlugins(plugins, platform);

    // If skipIfNoDependencies is true, there aren't any swift package plugins,
    // and the project hasn't been migrated yet, don't generate a Swift package
    // or migrate the app since it's not needed. If the project has already been
    // migrated, regenerate the Package.swift even if there are no dependencies
    // in case there previously were dependencies.
    if (skipIfNoDependencies && packageDependencies.isEmpty && !projectMigrated(project)) {
      return;
    }

    final String swiftPackagePath = overrideSwiftPackagePath ?? flutterPackagesPath(project);
    final String swiftPackageName = overrideSwiftPackageName ?? _defaultFlutterPluginsSwiftPackageName;
    final SwiftPackage pluginsPackage = SwiftPackage(
      swiftPackagePath: '$swiftPackagePath/Package.swift',
      fileSystem: _fileSystem,
      logger: _logger,
      templateRenderer: _templateRenderer,
    );

    SwiftPackageTarget? frameworkTarget;
    SwiftPackageTargetDependency? frameworkTargetDependency;
    if (includeFlutterFramework && packageDependencies.isNotEmpty) {
      final String flutterFramework = platform == SupportedPlatform.ios ? 'Flutter' : 'FlutterMacOS';
      frameworkTarget = SwiftPackageTarget.binaryTarget(
        name: flutterFramework,
        path: '$flutterFramework.xcframework',
      );
      frameworkTargetDependency = SwiftPackageTargetDependency(name: flutterFramework);
    }

    final List<SwiftPackageTarget> packageTargets = <SwiftPackageTarget>[
      if (frameworkTarget != null) frameworkTarget,
      SwiftPackageTarget(
        name: swiftPackageName,
        dependencies: <SwiftPackageTargetDependency>[
          if (frameworkTargetDependency != null) frameworkTargetDependency,
          ...targetProducts,
        ],
      ),
    ];

    final SwiftPackageContext packageContext = SwiftPackageContext(
      name: swiftPackageName,
      platforms: <SwiftPackageSupportedPlatform>[
        if (platform == SupportedPlatform.ios) SwiftPackageSupportedPlatform(platform: SwiftPackagePlatform.ios, version: '12.0'),
        if (platform == SupportedPlatform.macos) SwiftPackageSupportedPlatform(platform: SwiftPackagePlatform.macos, version: '10.14'),
      ],
      products: <SwiftPackageProduct>[
        SwiftPackageProduct(
          name: swiftPackageName,
          targets: <String>[swiftPackageName],
          libraryType: libraryType,
        ),
      ],
      dependencies: packageDependencies,
      targets: packageTargets,
    );

    // Create FlutterPackage, which adds dependencies to the Flutter Framework and plugins.
    await pluginsPackage.createSwiftPackage(packageContext);

    if (includeFlutterFramework) {
      // You need to setup the framework symlink so xcodebuild commands like
      // showSettings will still work. The BuildMode is not known yet, so set
      // to debug for now. The correct framework will be symlinked when the
      // project is built.
      setupFlutterFramework(
        platform,
        project,
        BuildMode.debug,
        artifacts: _artifacts,
        fileSystem: _fileSystem,
        processManager: _processManager,
        logger: _logger,
      );
    }
    if (migrateApp) {
      await _migrateProject(project, platform);
    }
  }

  (List<SwiftPackagePackageDependency>, List<SwiftPackageTargetDependency>) _dependenciesForPlugins(
    List<Plugin> plugins,
    SupportedPlatform platform,
  ) {
    final List<SwiftPackagePackageDependency> packageDependencies = <SwiftPackagePackageDependency>[];
    final List<SwiftPackageTargetDependency> targetProducts = <SwiftPackageTargetDependency>[];

    for (final Plugin plugin in plugins) {
      final String? pluginSwiftPackagePath = plugin.pluginSwiftPackagePath(platform.name);
      if (plugin.platforms[platform.name] == null || pluginSwiftPackagePath == null) {
        _logger.printTrace('Skipping ${plugin.name} for ${platform.name}. Not compatible with SPM.');
        continue;
      }
      if (_fileSystem.file(pluginSwiftPackagePath).existsSync()) {
        // If plugin has a Package.swift, add plugin as a dependency
        packageDependencies.add(
          SwiftPackagePackageDependency(name: plugin.name, path: _fileSystem.file(pluginSwiftPackagePath).parent.path),
        );
        targetProducts.add(SwiftPackageTargetDependency(name: plugin.name, package: plugin.name));
      } else {
        _logger.printTrace('Using a non-spm plugin: ${plugin.name}');
      }
    }
    return (packageDependencies, targetProducts);
  }

  static bool projectMigrated(XcodeBasedProject project) {
    if (project.xcodeProjectInfoFile.existsSync() && project.xcodeProjectInfoFile.readAsStringSync().contains(FlutterPackageMigration.flutterPackageFileReferenceIdentifier)) {
      return true;
    }
    return false;
  }

  Future<void> _migrateProject(XcodeBasedProject project, SupportedPlatform platform) async {
    final ProjectMigration migration = ProjectMigration(<ProjectMigrator>[
      FlutterPackageMigration(
        project,
        platform,
        xcodeProjectInterpreter: _xcodeProjectInterpreter,
        logger: _logger,
        fileSystem: _fileSystem,
        processManager: _processManager,
      ),
    ]);
    await migration.run();
  }

  /// Validates the platform is either iOS or macOS, otherwise throw an error
  /// and exit.
  static void _validatePlatform(SupportedPlatform platform) {
    if (platform != SupportedPlatform.ios && platform != SupportedPlatform.macos) {
      throwToolExit('The platform ${platform.name} is not compatible with Swift Package Manager. Only iOS and macOS is allowed.');
    }
  }

  static void setupFlutterFramework(
    SupportedPlatform platform,
    XcodeBasedProject project,
    BuildMode buildMode, {
    required Artifacts artifacts,
    required FileSystem fileSystem,
    required ProcessManager processManager,
    required Logger logger,
  }) {
    _validatePlatform(platform);
    final String xcframeworkName = platform == SupportedPlatform.macos ? 'FlutterMacOS.xcframework' : 'Flutter.xcframework';
    final Directory flutterPackageDir = flutterPackageDirectory(project, fileSystem);
    if (!flutterPackageDir.existsSync()) {
      // This can happen when Swift Package Manager is enabled, but the project
      // hasn't been migrated yet since it doesn't have any Swift Package
      // Manager plugin dependencies.
      logger.printTrace('FlutterPackage does not exist, skipping adding link to $xcframeworkName.');
      return;
    }

    String engineCacheFlutterFramework;
    if (platform == SupportedPlatform.macos) {
      engineCacheFlutterFramework = artifacts.getArtifactPath(
        Artifact.flutterMacOSXcframework,
        platform: TargetPlatform.darwin,
        mode: buildMode,
      );
    } else {
      engineCacheFlutterFramework = artifacts.getArtifactPath(
        Artifact.flutterXcframework,
        platform: TargetPlatform.ios,
        mode: buildMode,
      );
    }
    final Link frameworkSymlink = flutterPackageDir.childLink(xcframeworkName);
    if (!frameworkSymlink.existsSync()) {
      frameworkSymlink.createSync(engineCacheFlutterFramework);
    } else if (frameworkSymlink.targetSync() != engineCacheFlutterFramework) {
      frameworkSymlink.updateSync(engineCacheFlutterFramework);
    }
  }
}

class SwiftPackage {
  SwiftPackage({
    required this.swiftPackagePath,
    required FileSystem fileSystem,
    required Logger logger,
    required TemplateRenderer templateRenderer,
  })  : _fileSystem = fileSystem,
        _logger = logger,
        _templateRenderer = templateRenderer;

  final FileSystem _fileSystem;
  final TemplateRenderer _templateRenderer;
  final Logger _logger;

  final String swiftPackagePath;

  File get swiftPackage => _fileSystem.file(swiftPackagePath);

  Future<void> createSwiftPackage(SwiftPackageContext packageContext, {bool overwriteExisting = true,}) async {
    if (!overwriteExisting && await swiftPackage.exists()) {
      _logger.printTrace('Skipping creating $swiftPackagePath. Already exists.');
      return;
    }

    // Swift Packages require at least one source file per non-binary target, whether it be in Swift or Objective C.
    for (final SwiftPackageTarget target in packageContext.targets) {
      if (target.binaryTarget) {
        continue;
      }
      final Directory targetDirectory = swiftPackage.parent.childDirectory('Sources').childDirectory(target.name);
      if (!targetDirectory.existsSync() || targetDirectory.listSync().isEmpty) {
        final File requiredSwiftFile = _fileSystem.file('${swiftPackage.parent.path}/Sources/${target.name}/${target.name}.swift');
        await requiredSwiftFile.create(recursive: true);
      }
    }

    final Template template = await Template.fromName(
      'swift_package_manager',
      fileSystem: _fileSystem,
      logger: _logger,
      templateRenderer: _templateRenderer,
      templateManifest: null,
    );

    template.render(
      swiftPackage.parent,
      packageContext.templateContext,
      overwriteExisting: overwriteExisting,
      printStatusWhenWriting: false,
    );
  }
}

class SwiftPackageContext {
  SwiftPackageContext({
    required this.name,
    required this.platforms,
    required this.products,
    required this.dependencies,
    required this.targets,
  });

  final String name;

  final List<SwiftPackageSupportedPlatform> platforms;

  final List<SwiftPackageProduct> products;

  final List<SwiftPackagePackageDependency> dependencies;

  final List<SwiftPackageTarget> targets;

  static const String _singleIndent = '    ';
  static const String _doubleIndent = '$_singleIndent$_singleIndent';

  Map<String, String> get templateContext {

    final Map<String, String> context = <String, String>{
      'packageName': _stringifyName(),
      'swiftToolsVersion': '5.7',
      'platforms': _stringifyPlatforms(),
      'products': _stringifyProducts(),
      'dependencies': _stringifyDependencies(),
      'targets': _stringifyTargets(),
    };
    return context;
  }

  String _stringifyName() {
    return '${_singleIndent}name: "$name",\n';
  }

  String _stringifyPlatforms() {
    // platforms: [
    //     .macOS("10.14"),
    //     .iOS("12.0"),
    // ],
    final List<String> platformStrings = <String>[];
    for (final SwiftPackageSupportedPlatform platform in platforms) {
      final String platformString = '$_doubleIndent${platform.platform.name}("${platform.version}")';
      platformStrings.add(platformString);
    }
    return '''
${_singleIndent}platforms: [
${platformStrings.join(",\n")}
$_singleIndent],
''';
  }

  String _stringifyProducts() {
    // products: [
    //     .library(name: "FlutterPackage", targets: ["FlutterPackage"]),
    //     .library(name: "FlutterDependenciesPackage", type: .dynamic, targets: ["FlutterDependenciesPackage"]),
    // ],
    final List<String> libraries = <String>[];
    for (final SwiftPackageProduct product in products) {
      String targetsString = '';
      if (product.targets.isNotEmpty) {
        targetsString = ', targets: ["${product.targets.join('", ')}"]';
      }
      String libraryTypeString = '';
      if (product.libraryType != null) {
        libraryTypeString = ', type: ${product.libraryType!.name}';
      }
      final String library = '$_doubleIndent.library(name: "${product.name}"$libraryTypeString$targetsString)';
      libraries.add(library);
    }

    return '''
${_singleIndent}products: [
${libraries.join(",\n")}
$_singleIndent],
''';
  }

  String _stringifyDependencies() {
    // dependencies: [
    //     .package(name: "image_picker_ios", path: "/path/to/packages/image_picker/image_picker_ios/ios/image_picker_ios"),
    // ],
    final List<String> packages = <String>[];
    for (final SwiftPackagePackageDependency dependency in dependencies) {
      final String package = '$_doubleIndent.package(name: "${dependency.name}", path: "${dependency.path}")';
      packages.add(package);
    }

    return '''
${_singleIndent}dependencies: [
${packages.join(",\n")}
$_singleIndent],
''';
  }

  String _stringifyTargets() {
    // targets: [
    //     .binaryTarget(
    //         name: "Flutter",
    //         path: "Flutter.xcframework"
    //     ),
    //     .target(
    //         name: "FlutterPackage",
    //         dependencies: [
    //             "Flutter",
    //             .product(name: "image_picker_ios", package: "image_picker_ios")
    //         ]
    //     ),
    // ]
    const String targetIndent = _doubleIndent;
    const String targetDetailsIndent = '$_doubleIndent$_singleIndent';
    const String dependencyIndent = '$_doubleIndent$_doubleIndent';
    final List<String> targetList = <String>[];
    for (final SwiftPackageTarget target in targets) {
      final String targetType = target.binaryTarget ? 'binaryTarget' : 'target';
      final String name = 'name: "${target.name}"';

      final List<String> targetDetails = <String>[name];
      if (target.path != null) {
        final String path = 'path: "${target.path}"';
        targetDetails.add(path);
      }


      String dependencies = '';
      final List<String> targetDependencies = <String>[];
      if (target.dependencies != null) {
        for (final SwiftPackageTargetDependency dependency in target.dependencies!) {
          if (dependency.package != null) {
            targetDependencies.add('$dependencyIndent.product(name: "${dependency.name}", package: "${dependency.package}")');
          } else {
            targetDependencies.add('$dependencyIndent"${dependency.name}"');
          }
        }
        dependencies = '''
dependencies: [
${targetDependencies.join(",\n")}
$targetDetailsIndent]''';
        targetDetails.add(dependencies);
      }

      targetList.add('''
$targetIndent.$targetType(
$targetDetailsIndent${targetDetails.join(",\n$targetDetailsIndent")}
$targetIndent)''');
    }

    return '''
${_singleIndent}targets: [
${targetList.join(",\n")}
$_singleIndent]''';
  }
}

class SwiftPackageSupportedPlatform {
  SwiftPackageSupportedPlatform({
    required this.platform,
    this.version,
  });

  final SwiftPackagePlatform platform;
  final String? version;
}

enum SwiftPackagePlatform {
  ios(name: '.iOS'),
  macos(name: '.macOS'),
  tvos(name: '.tvOS'),
  watchos(name: '.watchOS');

  const SwiftPackagePlatform({required this.name});

  final String name;
}

enum SwiftPackageLibraryType {
  dynamic(name: '.dynamic'),
  static(name: '.static');

  const SwiftPackageLibraryType({required this.name});

  final String name;
}

class SwiftPackageProduct {
  SwiftPackageProduct({
    required this.name,
    required this.targets,
    this.libraryType,
  });

  final String name;
  final List<String> targets;
  final SwiftPackageLibraryType? libraryType;
}

class SwiftPackagePackageDependency {
  SwiftPackagePackageDependency({
    required this.name,
    required this.path,
  });

  final String name;
  final String path;
}

class SwiftPackageTarget {
  SwiftPackageTarget({
    required this.name,
    this.path,
    this.exclude,
    this.sources,
    this.publicHeadersPath,
    this.dependencies,
    this.binaryTarget = false,
  });

  SwiftPackageTarget.binaryTarget({
    required this.name,
    this.path,
    this.exclude,
    this.sources,
    this.publicHeadersPath,
    this.dependencies,
    this.binaryTarget = true,
  });

  final String name;
  final String? path;
  final List<String>? exclude;
  final List<String>? sources;
  final String? publicHeadersPath;
  final List<SwiftPackageTargetDependency>? dependencies;
  final bool binaryTarget;
}

class SwiftPackageTargetDependency {
  SwiftPackageTargetDependency({
    required this.name,
    this.package,
  });

  final String name;
  final String? package;
}
