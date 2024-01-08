// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:process/process.dart';

import '../artifacts.dart';
import '../base/common.dart';
import '../base/error_handling_io.dart';
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
import 'cocoapods.dart';

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

  static String flutterPackagesPath(XcodeBasedProject project) {
    return '${project.hostAppRoot.path}/Flutter/Packages/FlutterPackage';
  }

  Future<void> generate(List<Plugin> plugins, SupportedPlatform platform, XcodeBasedProject project) async {
    if (platform != SupportedPlatform.ios && platform != SupportedPlatform.macos) {
      throwToolExit('The platform ${platform.name} is not compatible with Swift Package Manager. Only iOS and macOS is allowed.');
    }
    final List<SwiftPackagePackageDependency> packageDependencies = <SwiftPackagePackageDependency>[];
    final List<SwiftPackageTargetDependency> packageProducts = <SwiftPackageTargetDependency>[];

    for (final Plugin plugin in plugins) {
      final String? pluginSwiftPackagePath = plugin.pluginSwiftPackagePath(platform.name);
      if (plugin.platforms[platform.name] == null || pluginSwiftPackagePath == null) {
        _logger.printTrace('Skipping ${plugin.name} for ${platform.name}. Not compatible with SPM.');
        continue;
      }
      final SwiftPackage pluginSwiftPackage = SwiftPackage(
        swiftPackagePath: pluginSwiftPackagePath,
        fileSystem: _fileSystem,
        logger: _logger,
        templateRenderer: _templateRenderer,
      );
      if (await pluginSwiftPackage.swiftPackage.exists()) {
        // plugin already has a Package.swift
        // Add plugin as dependency
        packageDependencies.add(
          SwiftPackagePackageDependency(name: plugin.name, path: _fileSystem.file(pluginSwiftPackagePath).parent.path),
        );
        packageProducts.add(SwiftPackageTargetDependency(name: plugin.name, package: plugin.name));
      } else {
        _logger.printStatus('Using a non-spm plugin: ${plugin.name}');
      }
    }

    // TODO: if no dependencies, no need for Flutter.xcframework either

    final SwiftPackage flutterPackage = SwiftPackage(
      swiftPackagePath: '${flutterPackagesPath(project)}/Package.swift',
      fileSystem: _fileSystem,
      logger: _logger,
      templateRenderer: _templateRenderer,
    );

    final String flutterFramework = platform == SupportedPlatform.ios ? 'Flutter' : 'FlutterMacOS';

    if (packageDependencies.isNotEmpty || flutterPackage.swiftPackage.existsSync()) {
      final SwiftPackageContext packageContext = SwiftPackageContext(
        name: 'FlutterPackage',
        platforms: <SwiftPackageSupportedPlatform>[
          if (platform == SupportedPlatform.ios) SwiftPackageSupportedPlatform(platform: SwiftPackagePlatform.ios, version: '12.0'),
          if (platform == SupportedPlatform.macos) SwiftPackageSupportedPlatform(platform: SwiftPackagePlatform.macos, version: '10.14'),
        ],
        products: <SwiftPackageProduct>[
          SwiftPackageProduct(name: 'FlutterPackage', targets: <String>['FlutterPackage']),
        ],
        dependencies: packageDependencies,
        targets: <SwiftPackageTarget>[
          if (packageDependencies.isNotEmpty) SwiftPackageTarget.binaryTarget(
            name: flutterFramework,
            path: '$flutterFramework.xcframework',
          ),
          SwiftPackageTarget(
            name: 'FlutterPackage',
            dependencies: <SwiftPackageTargetDependency>[
              if (packageDependencies.isNotEmpty) SwiftPackageTargetDependency(name: flutterFramework),
              ...packageProducts,
            ],
          ),
        ],
      );

      // Create FlutterPackage, which adds dependencies to the Flutter Framework and plugins.
      await flutterPackage.createSwiftPackage(packageContext);

      // You need to setup the framework symlink so xcodebuild commands like showSettings will still work
      setupFlutterFramework(
        platform,
        project,
        BuildMode.debug,
        artifacts: _artifacts,
        fileSystem: _fileSystem,
      );

      await migrateProject(project, platform);
    }
  }

  Future<void> migrateProject(XcodeBasedProject project, SupportedPlatform platform) async {
    final FlutterPackageMigration flutterPackageMigration = FlutterPackageMigration(
      project,
      platform,
      xcodeProjectInterpreter: _xcodeProjectInterpreter,
      logger: _logger,
      fileSystem: _fileSystem,
      processManager: _processManager,
    );

    try {
      final ProjectMigration migration = ProjectMigration(<ProjectMigrator>[
        flutterPackageMigration,
      ]);
      migration.run();

      // Get the build settings to make sure it compiles
      await _xcodeProjectInterpreter.getInfo(
        project.hostAppRoot.path,
      );

    } on Exception {
      if (flutterPackageMigration.backupProjectSettings.existsSync()) {
        _logger.printError('Restoring project settings from backup file...');
        flutterPackageMigration.backupProjectSettings.copySync(project.xcodeProjectInfoFile.path);
      }
      rethrow;
    } finally {
      ErrorHandlingFileSystem.deleteIfExists(flutterPackageMigration.backupProjectSettings);
    }
  }

  static void setupFlutterFramework(
    SupportedPlatform platform,
    XcodeBasedProject project,
    BuildMode buildMode, {
    required Artifacts artifacts,
    required FileSystem fileSystem,
  }) {
    if (platform != SupportedPlatform.ios && platform != SupportedPlatform.macos) {
      throwToolExit('The platform ${platform.name} is not compatible with Swift Package Manager. Only iOS and macOS is allowed.');
    }
    final String flutterPackagesPath = '${project.hostAppRoot.path}/Flutter/Packages/FlutterPackage';
    final Directory flutterPackageDir = fileSystem.directory(flutterPackagesPath);

    // TODO: SPM - macos
    String engineCacheFlutterFramework = artifacts.getArtifactPath(
      platform == SupportedPlatform.ios ? Artifact.flutterXcframework : Artifact.flutterMacOSFramework,
      platform: platform == SupportedPlatform.ios ? TargetPlatform.ios : TargetPlatform.darwin,
      mode: buildMode,
    );

    Link frameworkSymlink = flutterPackageDir.childLink('Flutter.xcframework');

    if (platform == SupportedPlatform.macos) {
      engineCacheFlutterFramework = '/Users/vashworth/Development/flutter/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework';
      frameworkSymlink = flutterPackageDir.childLink('FlutterMacOS.xcframework');
    }

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
      final File requiredSwiftFile = _fileSystem.file('${swiftPackage.parent.path}/Sources/${target.name}/${target.name}.swift');
      final bool fileAlreadyExists = await requiredSwiftFile.exists();
      if (!fileAlreadyExists) {
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
    // this.swiftLanguageVersions,
  });

  final String name;

  // defaultLocalization: LanguageTag? = nil,

  final List<SwiftPackageSupportedPlatform> platforms;

  // pkgConfig: String? = nil,

  // providers: [SystemPackageProvider]? = nil,

  final List<SwiftPackageProduct> products;

  final List<SwiftPackagePackageDependency> dependencies;

  // targets: [Target] = [],
  final List<SwiftPackageTarget> targets;

  // final List<SwiftLanguageVersion>? swiftLanguageVersions;

  // cLanguageStandard: CLanguageStandard? = nil,
  // cxxLanguageStandard: CXXLanguageStandard? = nil

  static const String _singleIndent = '    ';

  Map<String, String> get templateContext {

    final Map<String, String> context = <String, String>{
      'packageName': _stringifyName(),
      'swiftToolsVersion': '5.7',
      'defaultLocalization': '',
      'platforms': _stringifyPlatforms(),
      'pkgConfig': '',
      'providers': '',
      'products': _stringifyProducts(),
      'dependencies': _stringifyDependencies(),
      'targets': _stringifyTargets(),
      'swiftLanguageVersions': '',
      'cLanguageStandard': '',
      'cxxLanguageStandard': '',
    };
    return context;
  }

  String _stringifyName() {
    return '${_singleIndent}name: "$name",\n';
  }

  String _stringifyPlatforms() {
    // platforms: [
    //     .macOS("10.14"),
    //     .iOS(.v11),
    // ],
    final List<String> platformStrings = <String>[];
    for (final SwiftPackageSupportedPlatform platform in platforms) {
      final String platformString = '$_singleIndent$_singleIndent${platform.platform.name}("${platform.version}")';
      platformStrings.add(platformString);
    }
    return <String>[
'''
${_singleIndent}platforms: [
${platformStrings.join(",\n")}
$_singleIndent],
'''
    ].join();
  }

  String _stringifyProducts() {
    final List<String> libraries = <String>[];
    for (final SwiftPackageProduct product in products) {
      String typeString = '';
      // if (product.libraryType != null) {
      //   typeString = ', type: ${product.libraryType!.name}';
      // }
      String targetsString = '';
      if (product.targets.isNotEmpty) {
        targetsString = ', targets: ["${product.targets.join('", ')}"]';
      }
      final String library = '$_singleIndent$_singleIndent.library(name: "${product.name}"$typeString$targetsString)';
      libraries.add(library);
    }

    return <String>[
'''
${_singleIndent}products: [
${libraries.join(",\n")}
$_singleIndent],
'''
    ].join();
  }

  String _stringifyDependencies() {
    final List<String> packages = <String>[];
    for (final SwiftPackagePackageDependency dependency in dependencies) {
      final String package = '$_singleIndent$_singleIndent.package(name: "${dependency.name}", path: "${dependency.path}")';
      packages.add(package);
    }

    return '''
${_singleIndent}dependencies: [
${packages.join(",\n")}
$_singleIndent],
''';
  }

  String _stringifyTargets() {
    const String targetIndent = '$_singleIndent$_singleIndent';
    const String targetDetailsIndent = '$_singleIndent$_singleIndent$_singleIndent';
    const String dependencyIndent = '$_singleIndent$_singleIndent$_singleIndent$_singleIndent';
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

      // ${targetDetailsIndent}


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

// enum SwiftLanguageVersion {
//   v3(name: '.v3'),
//   v4(name: '.v4'),
//   v4_2(name: '.v4_2'),
//   v5(name: '.v5'),
//   custom(name: '.version({{customVersion}})');

//   const SwiftLanguageVersion({required this.name});

//   final String name;
// }

class SwiftPackageSupportedPlatform {
  SwiftPackageSupportedPlatform({
    required this.platform,
    this.version,
  });

  final SwiftPackagePlatform platform;
  final String? version;
  // First available in PackageDescription 5.0
  // Configures the minimum deployment target version for the iOS platform using a custom version string.
  // platforms: [.iOS(.v12)],
  // platforms: [.iOS],
  // platforms: [.macOS(.v10_15), .iOS(.v13)],
  // platforms: [.iOS("8.0.1")],
}

enum SwiftPackagePlatform {
  ios(name: '.iOS'),
  macos(name: '.macOS'),
  tvos(name: '.tvOS'),
  watchos(name: '.watchOS');

  const SwiftPackagePlatform({required this.name});

  final String name;
}

class SwiftPackageProduct {
  SwiftPackageProduct({
    // this.productType,
    required this.name,
    // this.libraryType,
    required this.targets,
  });

  // final SwiftPackageProductType productType;
  final String name;
  // final SwiftPackageLibraryType? libraryType;
  final List<String> targets;
}

// enum SwiftPackageProductType {
//   library(name: '.library');

//   const SwiftPackageProductType({required this.name});

//   final String name;
// }

// enum SwiftPackageLibraryType {
//   static(name: '.static'),
//   dynamic(name: '.dynamic');

//   const SwiftPackageLibraryType({required this.name});

//   final String name;
// }

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
    // this.resources,
    this.publicHeadersPath,
    this.dependencies,
    this.binaryTarget = false,
  });

  SwiftPackageTarget.binaryTarget({
    required this.name,
    this.path,
    this.exclude,
    this.sources,
    // this.resources,
    this.publicHeadersPath,
    this.dependencies,
    this.binaryTarget = true,
  });

  final String name;
  final String? path;
  final List<String>? exclude;
  final List<String>? sources;
  // final List<String>? resources;
  final String? publicHeadersPath;
  final List<SwiftPackageTargetDependency>? dependencies;
  final bool binaryTarget;

  // TODO: resources
}

class SwiftPackageTargetDependency {
  SwiftPackageTargetDependency({
    required this.name,
    this.package,
  });

  final String name;
  final String? package;
}

class DarwinPluginPackageManagement {

  DarwinPluginPackageManagement({
    required this.fileSystem,
    required this.logger,
    required this.cocoapods,
  });

  final FileSystem fileSystem;
  final CocoaPods cocoapods;
  final Logger logger;

  Map<SupportedPlatform, int> pluginCount = <SupportedPlatform, int>{};
  Map<SupportedPlatform, int> swiftPackagePluginCount = <SupportedPlatform, int>{};
  Map<SupportedPlatform, int> cocoapodPluginCount = <SupportedPlatform, int>{};

  Future<bool> usingCocoaPodsPlugin({
    required List<Plugin> plugins,
    required FlutterProject project,
    required SupportedPlatform platform,
  }) async {
    if (platform != SupportedPlatform.ios && platform != SupportedPlatform.macos) {
      throwToolExit('Unable to check CocoaPods usage for ${platform.name} project');
    }
    if (pluginCount[platform] == null) {
      await _evaluatePlugins(plugins: plugins, project: project, platform: platform);
    }
    if (project.usingSwiftPackageManager) {
      if (pluginCount[platform] == swiftPackagePluginCount[platform]) {
        return false;
      }
    }
    if (cocoapodPluginCount[platform]! > 0) {
      return true;
    }
    return false;
  }

  Future<void> _evaluatePlugins({
    required List<Plugin> plugins,
    required FlutterProject project,
    required SupportedPlatform platform,
  }) async {
    int platformPluginCount = 0;
    int swiftPackageCount = 0;
    int cocoapodCount = 0;
    for (final Plugin plugin in plugins) {
      if (plugin.platforms[platform.name] == null) {
        continue;
      }
      final String? swiftPackagePath = plugin.pluginSwiftPackagePath(platform.name);
      final bool pluginSwiftPackageManagerCompatible = swiftPackagePath != null && fileSystem.file(swiftPackagePath).existsSync();
      final String? podspecPath = plugin.pluginPodspecPath(platform.name);
      final bool pluginCocoapodCompatible = podspecPath != null && fileSystem.file(podspecPath).existsSync();

      // If a plugin is missing both a Package.swift and Podspec, it won't be
      // included by either Swift Package Manager or Cocoapods. This can happen
      // when a plugin doesn't have native platform code.
      // For example, image_picker_macos only uses dart code.
      if (!pluginSwiftPackageManagerCompatible && !pluginCocoapodCompatible) {
        continue;
      }

      platformPluginCount += 1;

      if (pluginSwiftPackageManagerCompatible) {
        swiftPackageCount += 1;
      }

      if (pluginCocoapodCompatible) {
        cocoapodCount += 1;
      } else if (!project.usingSwiftPackageManager && pluginSwiftPackageManagerCompatible) {
        // If not using Swift Package Manager and plugin does not have podspec but does have swift package, warn it will not be used
        logger.printWarning('Plugin ${plugin.name} is only Swift Package Manager compatible. Try enabling Swift Package Manager.');
      }
    }

    if (project.usingSwiftPackageManager) {
      if (platformPluginCount == swiftPackageCount) {
        final XcodeBasedProject xcodeProject = platform == SupportedPlatform.ios ? project.ios : project.macos;
        final File podfileTemplate = await cocoapods.getPodfileTemplate(xcodeProject, xcodeProject.xcodeProject);
        final bool podfileExists = xcodeProject.podfile.existsSync();

        // If all plugins are SPM and generic podfile but pod stuff still exists, recommend pod deintegration
        // If all plugins are SPM and custom podfile, recommend migrating

        // TODO: SPM - messages
        if (podfileExists && xcodeProject.podfile.readAsStringSync() == podfileTemplate.readAsStringSync()) {
          logger.printStatus('All of the plugins you are using for ${platform.name} are Swift Packages. You may consider removing Cococapod files. To remove Cocoapods, in the macos directory run `pod deintegrate` and delete the Podfile.');
        } else if (podfileExists) {
          logger.printStatus('All of the plugins you are using for ${platform.name} are Swift Packages, but you may be using other Cocoapods. You may consider migrating to Swift Package Manager.');
        }
      }
    }

    pluginCount[platform] = platformPluginCount;
    swiftPackagePluginCount[platform] = swiftPackageCount;
    cocoapodPluginCount[platform] = cocoapodCount;
  }
}
