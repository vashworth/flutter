import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/build_swift_packages.dart';
import 'package:flutter_tools/src/darwin/darwin.dart';
import 'package:flutter_tools/src/isolated/mustache_template.dart';
import 'package:flutter_tools/src/macos/xcode.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/version.dart';
import 'package:test_api/fake.dart';
import 'package:unified_analytics/unified_analytics.dart';

import '../../src/common.dart';
import '../../src/fake_process_manager.dart';

void main() {
  group('FlutterFrameworkDependency', () {
    testWithoutContext('generateArtifacts', () async {
      const xcframeworkOutputPath = 'output/FlutterPluginRegistrant/Debug';
      const engineArtifactPath = '/flutter/bin/cache/artifacts/engine/ios/Flutter.xcframework';

      final fs = MemoryFileSystem.test();
      final Directory xcframeworkOutput = fs.directory(xcframeworkOutputPath);
      final processManager = FakeProcessManager.list([
        const FakeCommand(
          command: [
            'rsync',
            '-av',
            '--delete',
            '--filter',
            '- .DS_Store/',
            '--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r',
            engineArtifactPath,
            xcframeworkOutputPath,
          ],
        ),
      ]);
      final testUtils = BuildSwiftPackageUtils(
        analytics: FakeAnalytics(),
        artifacts: FakeArtifacts(engineArtifactPath),
        buildSystem: FakeBuildSystem(),
        cache: FakeCache(),
        fileSystem: fs,
        flutterVersion: FakeFlutterVersion(),
        logger: BufferLogger.test(),
        platform: FakePlatform(),
        processManager: processManager,
        project: FakeFlutterProject(),
        targetPlatforms: [FlutterDarwinPlatform.ios],
        templateRenderer: FakeTemplateRenderer(),
        xcode: FakeXcode(),
      );

      final flutterFrameworkDependency = FlutterFrameworkDependency(utils: testUtils);
      await flutterFrameworkDependency.generateArtifacts(
        buildMode: BuildMode.debug,
        xcframeworkOutput: xcframeworkOutput,
      );
      expect(processManager.hasRemainingExpectations, false);
    });

    testWithoutContext('generateArtifacts fails', () async {
      const xcframeworkOutputPath = 'output/FlutterPluginRegistrant/Debug';
      const engineArtifactPath = '/flutter/bin/cache/artifacts/engine/ios/Flutter.xcframework';
      final fs = MemoryFileSystem.test();

      final Directory xcframeworkOutput = fs.directory(xcframeworkOutputPath);

      final logger = BufferLogger.test();
      final processManager = FakeProcessManager.list([
        const FakeCommand(
          command: [
            'rsync',
            '-av',
            '--delete',
            '--filter',
            '- .DS_Store/',
            '--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r',
            engineArtifactPath,
            xcframeworkOutputPath,
          ],
          exitCode: 1,
        ),
      ]);
      final testUtils = BuildSwiftPackageUtils(
        analytics: FakeAnalytics(),
        artifacts: FakeArtifacts(engineArtifactPath),
        buildSystem: FakeBuildSystem(),
        cache: FakeCache(),
        fileSystem: fs,
        flutterVersion: FakeFlutterVersion(),
        logger: logger,
        platform: FakePlatform(),
        processManager: processManager,
        project: FakeFlutterProject(),
        targetPlatforms: [FlutterDarwinPlatform.ios],
        templateRenderer: FakeTemplateRenderer(),
        xcode: FakeXcode(),
      );

      final flutterFrameworkDependency = FlutterFrameworkDependency(utils: testUtils);
      await expectToolExitLater(
        flutterFrameworkDependency.generateArtifacts(
          buildMode: BuildMode.debug,
          xcframeworkOutput: xcframeworkOutput,
        ),
        contains('Failed to copy $engineArtifactPath'),
      );
      expect(processManager.hasRemainingExpectations, false);
    });

    testWithoutContext('generateSwiftPackage', () async {
      const packageDirectoryPath = 'output/FlutterPluginRegistrant/Packages';
      const engineArtifactPath = '/flutter/bin/cache/artifacts/engine/ios/Flutter.xcframework';

      final fs = MemoryFileSystem.test();
      final Directory packageDirectory = fs.directory(packageDirectoryPath);
      final testUtils = BuildSwiftPackageUtils(
        analytics: FakeAnalytics(),
        artifacts: FakeArtifacts(engineArtifactPath),
        buildSystem: FakeBuildSystem(),
        cache: FakeCache(),
        fileSystem: fs,
        flutterVersion: FakeFlutterVersion(),
        logger: BufferLogger.test(),
        platform: FakePlatform(),
        processManager: FakeProcessManager.any(),
        project: FakeFlutterProject(),
        targetPlatforms: [FlutterDarwinPlatform.ios],
        templateRenderer: const MustacheTemplateRenderer(),
        xcode: FakeXcode(),
      );

      final flutterFrameworkDependency = FlutterFrameworkDependency(utils: testUtils);
      flutterFrameworkDependency.generateSwiftPackage(packageDirectory);

      final File generatedManifest = packageDirectory
          .childDirectory('FlutterFramework')
          .childFile('Package.swift');
      expect(generatedManifest.existsSync(), isTrue);
      expect(generatedManifest.readAsStringSync(), '''
// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
//  Generated file. Do not edit.
//

import PackageDescription

let package = Package(
    name: "FlutterFramework",
    products: [
        .library(name: "FlutterFramework", targets: ["FlutterFramework"])
    ],
    dependencies: [
        \n    ],
    targets: [
        .target(
            name: "FlutterFramework",
            dependencies: [
                .target(name: "Flutter", condition: .when(platforms: [.iOS]))
            ]
        ),
        .binaryTarget(
            name: "Flutter",
            path: "../../Frameworks/Flutter.xcframework"
        )
    ]
)
''');
    });

    testWithoutContext('packageDependency', () async {
      const engineArtifactPath = '/flutter/bin/cache/artifacts/engine/ios/Flutter.xcframework';

      final fs = MemoryFileSystem.test();
      final testUtils = BuildSwiftPackageUtils(
        analytics: FakeAnalytics(),
        artifacts: FakeArtifacts(engineArtifactPath),
        buildSystem: FakeBuildSystem(),
        cache: FakeCache(),
        fileSystem: fs,
        flutterVersion: FakeFlutterVersion(),
        logger: BufferLogger.test(),
        platform: FakePlatform(),
        processManager: FakeProcessManager.any(),
        project: FakeFlutterProject(),
        targetPlatforms: [FlutterDarwinPlatform.ios],
        templateRenderer: const MustacheTemplateRenderer(),
        xcode: FakeXcode(),
      );

      final flutterFrameworkDependency = FlutterFrameworkDependency(utils: testUtils);
      expect(
        flutterFrameworkDependency.packageDependency.format(),
        contains('.package(name: "FlutterFramework", path: "Packages/FlutterFramework")'),
      );
    });

    testWithoutContext('targetDependency', () async {
      const engineArtifactPath = '/flutter/bin/cache/artifacts/engine/ios/Flutter.xcframework';

      final fs = MemoryFileSystem.test();
      final testUtils = BuildSwiftPackageUtils(
        analytics: FakeAnalytics(),
        artifacts: FakeArtifacts(engineArtifactPath),
        buildSystem: FakeBuildSystem(),
        cache: FakeCache(),
        fileSystem: fs,
        flutterVersion: FakeFlutterVersion(),
        logger: BufferLogger.test(),
        platform: FakePlatform(),
        processManager: FakeProcessManager.any(),
        project: FakeFlutterProject(),
        targetPlatforms: [FlutterDarwinPlatform.ios],
        templateRenderer: const MustacheTemplateRenderer(),
        xcode: FakeXcode(),
      );

      final flutterFrameworkDependency = FlutterFrameworkDependency(utils: testUtils);
      expect(
        flutterFrameworkDependency.targetDependency.format(),
        contains('.product(name: "FlutterFramework", package: "FlutterFramework")'),
      );
    });
  });
}

class FakeAnalytics extends Fake implements Analytics {}

class FakeXcode extends Fake implements Xcode {}

class FakeFlutterVersion extends Fake implements FlutterVersion {}

class FakeArtifacts extends Fake implements Artifacts {
  FakeArtifacts(this.engineArtifactPath);

  final String engineArtifactPath;
  @override
  String getArtifactPath(
    Artifact artifact, {
    TargetPlatform? platform,
    BuildMode? mode,
    EnvironmentType? environmentType,
  }) {
    return engineArtifactPath;
  }
}

class FakeBuildSystem extends Fake implements BuildSystem {}

class FakeCache extends Fake implements Cache {}

class FakeFlutterProject extends Fake implements FlutterProject {}

class FakeTemplateRenderer extends Fake implements TemplateRenderer {}
