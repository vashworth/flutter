// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/template.dart';
import '../plugins.dart';
import '../template.dart';
import 'cocoapods.dart';

class SwiftPackage {
  SwiftPackage({
    required this.swiftPackagePath,
    required FileSystem fileSystem,
    required Logger logger,
    this.overwriteExisting = false,
    required TemplateRenderer templateRenderer,
  })  : _fileSystem = fileSystem,
        _logger = logger,
        _templateRenderer = templateRenderer;

  final FileSystem _fileSystem;
  final TemplateRenderer _templateRenderer;
  final Logger _logger;

  final String swiftPackagePath;
  final bool overwriteExisting;

  File get swiftPackage => _fileSystem.file(swiftPackagePath);


  Future<void> createSwiftPackage(SwiftPackageContext packageContext, {bool manifestOnly = false}) async {
    if (overwriteExisting == false && await swiftPackage.exists()) {
      _logger.printError('A Package.swift was already found');
      return;
    }
    if (manifestOnly == false) {
      // Swift Packages require at least one source file, whether it be in Swift or Objective C.
      final File requiredSwiftFile = _fileSystem.file('${swiftPackage.parent.path}/Sources/${packageContext.name}/${packageContext.name}.swift');

      final bool fileAlreadyExists = await requiredSwiftFile.exists();
      if (!fileAlreadyExists || overwriteExisting == true) {
        if (!fileAlreadyExists) {
          await requiredSwiftFile.create(recursive: true);
        }
      }
    }
    final Template template = await Template.fromName(
      'swift_package_manager',
      fileSystem: _fileSystem,
      logger: _logger,
      templateRenderer: _templateRenderer,
      templateManifest: null,
    );

    final int fileCount = template.render(
      swiftPackage.parent,
      packageContext.templateContext,
      overwriteExisting: false,
      printStatusWhenWriting: true,
    );
    print(fileCount);

    return;
  }
}

class SwiftPackageContext {
  SwiftPackageContext({
    required this.name,
    this.platforms,
    required this.products,
    required this.dependencies,
    required this.targets,
    this.swiftLanguageVersions,
  });

  final String name;

  // defaultLocalization: LanguageTag? = nil,

  final List<SwiftPackageSupportedPlatform>? platforms;

  // pkgConfig: String? = nil,

  // providers: [SystemPackageProvider]? = nil,

  final List<SwiftPackageProduct> products;

  final List<SwiftPackagePackageDependency> dependencies;

  // targets: [Target] = [],
  final List<SwiftPackageTarget> targets;

  final List<SwiftLanguageVersion>? swiftLanguageVersions;

  // cLanguageStandard: CLanguageStandard? = nil,
  // cxxLanguageStandard: CXXLanguageStandard? = nil

  Map<String, String> get templateContext {
    if (platforms != null) {

    }

    final Map<String, String> context = <String, String>{
      'packageName': _stringifyName(),
      'swiftToolsVersion': '5.7',
      'defaultLocalization': '',
      'platforms': '',
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
    return '    name: "$name",\n';
  }

  String _stringifyProducts() {
    final List<String> libraries = <String>[];
    for (final SwiftPackageProduct product in products) {
      String typeString = '';
      if (product.libraryType != null) {
        typeString = ', type: ${product.libraryType!.name}';
      }
      String targetsString = '';
      if (product.targets.isNotEmpty) {
        targetsString = ', targets: ["${product.targets.join('", ')}"]';
      }
      final String library = '        .library(name: "${product.name}"$typeString$targetsString),\n';
      libraries.add(library);
    }

    return <String>[
'''
    products: [
''',
      ...libraries,
'''
    ],
'''
    ].join();
  }

  String _stringifyDependencies() {
    final List<String> packages = <String>[];
    for (final SwiftPackagePackageDependency dependency in dependencies) {
      final String package = '        .package(name: "${dependency.name}", path: "${dependency.path}"),\n';
      packages.add(package);
    }

    return <String>[
'''
    dependencies: [
''',
      ...packages,
'''
    ],
'''
    ].join();
  }

  String _stringifyTargets() {
    const String targetIndent = '        ';
    const String targetDetailsIndent = '            ';
    const String dependencyIndent = '                ';
    final List<String> targetList = <String>[];
    for (final SwiftPackageTarget target in targets) {
      String pathString = '';
      if (target.path != null) {
        pathString = 'path: "${target.path}"';
      }
      String excludeString = '';
      if (target.exclude != null) {
        excludeString = 'exclude: ["${target.exclude!.join('", ')}"]';
      }
      String sourcesString = '';
      if (target.sources != null) {
        sourcesString = 'sources: ["${target.sources!.join('", ')}"]';
      }
      String headersString = '';
      if (target.publicHeadersPath != null) {
        headersString = 'publicHeadersPath: "${target.publicHeadersPath}"';
      }

      final List<String> targetDependencies = <String>[];
      if (target.dependencies != null) {
        for (final SwiftPackageTargetDependency dependency in target.dependencies!) {
          targetDependencies.add('$dependencyIndent.product(name: "${dependency.name}", package: "${dependency.package}"),\n');
        }
      }


      final String targetString = <String>[
        '$targetIndent.target(',
        '\n${targetDetailsIndent}name: "${target.name}"',
        if (pathString.isNotEmpty) ',\n$targetDetailsIndent$pathString',
        if (excludeString.isNotEmpty) ',\n$targetDetailsIndent$excludeString',
        if (sourcesString.isNotEmpty) ',\n$targetDetailsIndent$sourcesString',
        if (targetDependencies.isNotEmpty)
          ...<String>[
            ',\n${targetDetailsIndent}dependencies: [\n',
            ...targetDependencies,
            '$targetDetailsIndent]',
          ],
        if (headersString.isNotEmpty) ',\n$targetDetailsIndent$headersString',
        '\n$targetIndent)\n',
      ].join();
      targetList.add(targetString);
    }

    return <String>[
'''
    targets: [
''',
      ...targetList,
'''
    ]
'''
    ].join();
  }
}

enum SwiftLanguageVersion {
  v3(name: '.v3'),
  v4(name: '.v4'),
  v4_2(name: '.v4_2'),
  v5(name: '.v5'),
  custom(name: '.version({{customVersion}})');

  const SwiftLanguageVersion({required this.name});

  final String name;
}

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
    this.libraryType,
    required this.targets,
  });

  // final SwiftPackageProductType productType;
  final String name;
  final SwiftPackageLibraryType? libraryType;
  final List<String> targets;
}

// enum SwiftPackageProductType {
//   library(name: '.library');

//   const SwiftPackageProductType({required this.name});

//   final String name;
// }

enum SwiftPackageLibraryType {
  static(name: '.static'),
  dynamic(name: '.dynamic');

  const SwiftPackageLibraryType({required this.name});

  final String name;
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
    // this.resources,
    this.publicHeadersPath,
    this.dependencies,
  });

  final String name;
  final String? path;
  final List<String>? exclude;
  final List<String>? sources;
  // final List<String>? resources;
  final String? publicHeadersPath;
  final List<SwiftPackageTargetDependency>? dependencies;

  // TODO: resources
}

class SwiftPackageTargetDependency {
  SwiftPackageTargetDependency({
    required this.name,
    required this.package,
  });

  final String name;
  final String package;
}
