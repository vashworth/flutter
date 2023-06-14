// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'dart:io';
import '../base/logger.dart';
import '../base/process.dart';
import '../convert.dart';

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:meta/meta.dart';
import 'package:platform/platform.dart';
import '../globals.dart' as globals;
import '../macos/xcode.dart';
import '../xcode_project.dart';
import 'xcresult.dart';


class XCDebug {
  XCDebug(this._processUtils, this._logger, this._xcode, this.project, this.deviceId);


  final ProcessUtils _processUtils;
  final Logger _logger;
  final Xcode _xcode;
  final IosProject project;
  final String deviceId;

  String? _xcodeProcessId;
  List<String>? logKeys;


  Future<bool> _openProjectInXcode() async {
    try {
      final RunResult result = await _processUtils.run(
        <String>[
          'open',
          // '-a',
          // _xcode.xcodeSelectPath!,
          '-n', // Open new instance even if one is already running
          '-F', // Open the application fresh
          '-g', // Do not bring the application to the foreground
          '-j', // Launches the app hidden
          project.xcodeProject.path
        ],
        throwOnError: true,
      );
      if (result.exitCode == 0) {
        return true;
      }
    } catch (e, stackTrace) {
      print(e);
      print(stackTrace);
    }
    return false;
  }

  Future<List<String>> _getXcodeProcessIds() async {
    try {
      final RunResult result = await _processUtils.run(
        <String>[
          'pgrep',
          '-f',
          '/Applications/Xcode-beta.app/Contents/MacOS/Xcode',
        ],
      );

      if (result.exitCode == 0) {
        final String listOutput = result.stdout;
        return LineSplitter.split(listOutput).toList();
      }
    } catch (e, stackTrace) {
      print(e);
      print(stackTrace);
    }
    return <String>[];
  }

  Future<bool> installAndLaunchApp() async {
    final List<String> xcodeProcesses = await _getXcodeProcessIds();
    final bool success = await _openProjectInXcode();
    if (!success) {
      print('Failed to open Xcode');
      return false;
    }
    final List<String> newXcodeProcesses = await _getXcodeProcessIds();

    for (final String processId in newXcodeProcesses) {
      if (!xcodeProcesses.contains(processId)) {
        _xcodeProcessId = processId;
        break;
      }
    }
    if (_xcodeProcessId == null) {
      print('No Xcode process found to target');
      return false;
    }

    try {

      // TODO: path to DerivedData/Runner-xxx/Logs/Launch/LogStoreManifest.plist
      Map<String, dynamic> propertyValues = globals.plistParser.parseFile('path/Logs/Launch/LogStoreManifest.plist');
      // XCResultGenerator
      if (propertyValues.containsKey('logs')) {
        final Map<String, dynamic> logs = propertyValues['logs'] as Map<String, dynamic>;
        logKeys = logs.keys.toList();
      }
    } catch (e, stackTrace) {
      print(e);
      print(stackTrace);
    }


    int maxRetires = 3;
    for (int currentTry = 0; currentTry < maxRetires; currentTry++) {
      try {
        final RunResult result = await _processUtils.run(
          <String>[
            ..._xcode.xcrunCommand(),
            'xcdebug',
            '--pid', // Xcode process id
            _xcodeProcessId!,
            '--background', // Leave Xcode as background app
            '-s', // scheme
            project.hostAppProjectName,
            '-d', // destination
            deviceId,
          ],
          throwOnError: true,
        );

        print(result.exitCode);
        if (result.stderr.isNotEmpty) {
          // 2023-06-08 16:51:45.390 xcdebug[91211:711350] Error: Error Domain=NSOSStatusErrorDomain Code=-10000 "errAEEventFailed" UserInfo={ErrorNumber=-10000, ErrorString=The workspace document Runner.xcodeproj has not finished loading. Check the 'loaded' property before messaging a workspace document.}
          if (result.stderr.contains('xcodeproj has not finished loading')) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            continue;
          }
        }
        if (result.exitCode == 0) {
          return true;
        }
      } catch (err, stackTrace) {
        print(err);
        print(stackTrace);
      }
    }

    return false;
  }

  Future<void> checkForLaunchFailure() async {
    try {
      // TODO: path to DerivedData/Runner-xxx/Logs/Launch/LogStoreManifest.plist
      final Map<String, dynamic> propertyValues = globals.plistParser.parseFile('path/Logs/Launch/LogStoreManifest.plist');
      //
      if (!propertyValues.containsKey('logs')) {
        return;
      }

      final Map<String, dynamic> logs = propertyValues['logs'] as Map<String, dynamic>;
      final List<String> newLogKeys = logs.keys.toList();
      String? logId;
      for (final String logKey in newLogKeys) {
        if (logKeys != null && !logKeys!.contains(logKey)) {
          logId = logKey;
          break;
        }
      }
      if (logId == null) {
        print('Did not find log');
        return;
      }

      final Map<String, dynamic> logInfo = logs[logId] as Map<String, dynamic>;
      final String fileName = logInfo['fileName'] as String;

      // TODO: path to DerivedData/Runner-xxx/Logs/Launch/fileName
      final XCResultGenerator xcResultGenerator = XCResultGenerator(
        resultPath: 'path/Logs/Launch/$fileName',
        xcode: globals.xcode!,
        processUtils: globals.processUtils,
      );

      final XCResult result = await xcResultGenerator.generate();

      if (result.parseSuccess) {
        for (final XCResultIssue issue in result.issues) {
          print(issue.message);
        }
      }


    } catch (e, stackTrace) {
      print(e);
      print(stackTrace);
    }
  }

  Future<void> killXcode() async {
    if (_xcodeProcessId == null) {
      print('No Xcode process found to kill');
      return;
    }
    try {
      await _processUtils.run(
        <String>[
          'kill',
          _xcodeProcessId!,
        ],
        throwOnError: true,
      );
    } catch (err, stackTrace) {
      print(err);
      print(stackTrace);
    }

  }

}
