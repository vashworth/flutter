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
  group('validateCommand', () {
    testWithoutContext('_validateTargetPlatforms', () async {
    //  BuildSwiftPackages
    });

  });
}

// class FakeAnalytics extends Fake implements Analytics {}

// class FakeXcode extends Fake implements Xcode {}

// class FakeFlutterVersion extends Fake implements FlutterVersion {}

// class FakeArtifacts extends Fake implements Artifacts {
//   FakeArtifacts(this.engineArtifactPath);

//   final String engineArtifactPath;
//   @override
//   String getArtifactPath(
//     Artifact artifact, {
//     TargetPlatform? platform,
//     BuildMode? mode,
//     EnvironmentType? environmentType,
//   }) {
//     return engineArtifactPath;
//   }
// }

// class FakeBuildSystem extends Fake implements BuildSystem {}

// class FakeCache extends Fake implements Cache {}

// class FakeFlutterProject extends Fake implements FlutterProject {}

// class FakeTemplateRenderer extends Fake implements TemplateRenderer {}
