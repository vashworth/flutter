// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../base/file_system.dart';
import '../base/project_migrator.dart';
import '../xcode_project.dart';

// Migrate Xcode Thin Binary build phase to depend on Info.plist from build directory
// as an input file to ensure it has been created before inserting the NSBonjourServices key
// to avoid an mDNS error.
class FlutterPackageMigration extends ProjectMigrator {
  FlutterPackageMigration(XcodeBasedProject project, super.logger)
    : _xcodeProjectInfoFile = project.xcodeProjectInfoFile;

  final File _xcodeProjectInfoFile;

  @override
  void migrate() {
    if (!_xcodeProjectInfoFile.existsSync()) {
      logger.printTrace('Xcode project not found, skipping script build phase dependency analysis removal.');
      return;
    }

    final String originalProjectContents = _xcodeProjectInfoFile.readAsStringSync();

    if (originalProjectContents.contains('/* FlutterPackage in Frameworks */')) {
      return;
    }

    // Add Info.plist from build directory as an input file to Thin Binary build phase.
    // Path for the Info.plist is ${TARGET_BUILD_DIR}/\${INFOPLIST_PATH}

    // Example:
    // 3B06AD1E1E4923F5004D2608 /* Thin Binary */ = {
    //   isa = PBXShellScriptBuildPhase;
    //   alwaysOutOfDate = 1;
    //   buildActionMask = 2147483647;
    //   files = (
		// 	 );
		// 	 inputPaths = (
		// 	 );


    // TODO: insert in order

    String newProjectContents = originalProjectContents;

    newProjectContents = _migrateBuildFile(newProjectContents);

    newProjectContents = _migrateFileReference(newProjectContents);

    newProjectContents = _migrateFrameworksBuildPhase(newProjectContents);

    newProjectContents = _migrateGroupPackages(newProjectContents);

    newProjectContents = _migrateGroupFrameworks(newProjectContents);

    newProjectContents = _migrateNativeTarget(newProjectContents);

    newProjectContents = _migrateSwiftPackageProductDependency(newProjectContents);

    if (originalProjectContents != newProjectContents) {
      logger.printStatus('Adding Flutter Package as a dependency.');
      _xcodeProjectInfoFile.writeAsStringSync(newProjectContents);
    }
  }

  String _migrateBuildFile(String newProjectContents) {
    // PBXBuildFile

    const String originalString = '''
/* Begin PBXBuildFile section */
''';
    const String replacementString = r'''
/* Begin PBXBuildFile section */
		7813C6BD29DF633800574229 /* FlutterPackage in Frameworks */ = {isa = PBXBuildFile; productRef = 7813C6BC29DF633800574229 /* FlutterPackage */; };
''';
    return newProjectContents.replaceAll(originalString, replacementString);
  }

  String _migrateFileReference(String newProjectContents) {
    // PBXFileReference
    const String originalString = '''
/* Begin PBXFileReference section */
''';
    const String replacementString = r'''
/* Begin PBXFileReference section */
		7813C6BA29DF632500574229 /* FlutterPackage */ = {isa = PBXFileReference; lastKnownFileType = wrapper; path = FlutterPackage; sourceTree = "<group>"; };
''';
    return newProjectContents.replaceAll(originalString, replacementString);
  }

  String _migrateFrameworksBuildPhase(String newProjectContents) {
    // PBXFrameworksBuildPhase
    const String originalString = '''
		97C146EB1CF9000F007C117D /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
''';
    const String replacementString = r'''
		97C146EB1CF9000F007C117D /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				7813C6BD29DF633800574229 /* FlutterPackage in Frameworks */,
''';
    return newProjectContents.replaceAll(originalString, replacementString);
  }

  String _migrateGroupPackages(String newProjectContents) {
    // PBXGroup
    const String originalGroupString = '''
		9740EEB11CF90186004384FC /* Flutter */ = {
			isa = PBXGroup;
''';
    const String replacementGroupString = r'''
		7813C6B929DF632500574229 /* Packages */ = {
			isa = PBXGroup;
			children = (
				7813C6BA29DF632500574229 /* FlutterPackage */,
			);
			name = Packages;
			sourceTree = "<group>";
		};
		9740EEB11CF90186004384FC /* Flutter */ = {
			isa = PBXGroup;
''';

    String content = newProjectContents.replaceAll(originalGroupString, replacementGroupString);

    const String originalGroupChildString = '''
		97C146E51CF9000F007C117D = {
			isa = PBXGroup;
			children = (
''';
    const String replacementGroupChildString = r'''
		97C146E51CF9000F007C117D = {
			isa = PBXGroup;
			children = (
				7813C6B929DF632500574229 /* Packages */,
''';
    content = content.replaceAll(originalGroupChildString, replacementGroupChildString);


    return content;
  }

  String _migrateGroupFrameworks(String newProjectContents) {
    // PBXGroup
    final int startIndex = newProjectContents.indexOf('/* Begin PBXGroup section */');
    final int endIndex = newProjectContents.indexOf('/* End PBXGroup section */');
    final int frameworkIndex = newProjectContents.indexOf('/* Frameworks */ = {', startIndex);
    if (frameworkIndex > -1 && frameworkIndex < endIndex) {
      // Framework group already exists, skip
      return newProjectContents;
    }

    const String originalGroupString = '''
		9740EEB11CF90186004384FC /* Flutter */ = {
			isa = PBXGroup;
''';
    const String replacementGroupString = r'''
		7813C6BB29DF633800574229 /* Frameworks */ = {
			isa = PBXGroup;
			children = (
			);
			name = Frameworks;
			sourceTree = "<group>";
		};
		9740EEB11CF90186004384FC /* Flutter */ = {
			isa = PBXGroup;
''';
    String content = newProjectContents.replaceAll(originalGroupString, replacementGroupString);

    const String originalGroupChildString = '''
		97C146E51CF9000F007C117D = {
			isa = PBXGroup;
			children = (
''';
    const String replacementGroupChildString = r'''
		97C146E51CF9000F007C117D = {
			isa = PBXGroup;
			children = (
				7813C6BB29DF633800574229 /* Frameworks */,
''';
    content = content.replaceAll(originalGroupChildString, replacementGroupChildString);


    return content;
  }

  String _migrateNativeTarget(String newProjectContents) {
    // PBXNativeTarget
    final int startIndex = newProjectContents.indexOf('''
		9740EEB11CF90186004384FC /* Flutter */ = {
			isa = PBXGroup;
''');
    final int endIndex = newProjectContents.indexOf('/* End PBXNativeTarget section */');
    final int packageDependenciesIndex = newProjectContents.indexOf('packageProductDependencies', startIndex);

    if (packageDependenciesIndex > -1 && packageDependenciesIndex < endIndex) {
      // packageProductDependencies already exists, add to it
      const String originalString = '''
			name = Runner;
			packageProductDependencies = (
''';
      const String replacementString = r'''
			name = Runner;
			packageProductDependencies = (
				7813C6BC29DF633800574229 /* FlutterPackage */,
''';
      return newProjectContents.replaceAll(originalString, replacementString);
    }

    const String originalString = '''
			name = Runner;
			productName = Runner;
			productReference = 97C146EE1CF9000F007C117D /* Runner.app */;
''';
    const String replacementString = r'''
			name = Runner;
			packageProductDependencies = (
				7813C6BC29DF633800574229 /* FlutterPackage */,
			);
			productName = Runner;
			productReference = 97C146EE1CF9000F007C117D /* Runner.app */;
''';
    return newProjectContents.replaceAll(originalString, replacementString);
  }

  String _migrateSwiftPackageProductDependency(String newProjectContents) {
    // XCSwiftPackageProductDependency
    if (newProjectContents.contains('/* Begin XCSwiftPackageProductDependency section */')) {
      const String originalString = '''
/* Begin XCSwiftPackageProductDependency section */
''';
    const String replacementString = r'''
/* Begin XCSwiftPackageProductDependency section */
		7813C6BC29DF633800574229 /* FlutterPackage */ = {
			isa = XCSwiftPackageProductDependency;
			productName = FlutterPackage;
		};
''';
    return newProjectContents.replaceAll(originalString, replacementString);
    } else {
      const String originalString = '''
/* End XCConfigurationList section */
''';
    const String replacementString = r'''
/* End XCConfigurationList section */

/* Begin XCSwiftPackageProductDependency section */
		7813C6BC29DF633800574229 /* FlutterPackage */ = {
			isa = XCSwiftPackageProductDependency;
			productName = FlutterPackage;
		};
/* End XCSwiftPackageProductDependency section */
''';
      return newProjectContents.replaceAll(originalString, replacementString);
    }
  }
}
