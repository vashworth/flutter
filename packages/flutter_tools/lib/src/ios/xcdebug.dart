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

import '../macos/xcode.dart';
import '../xcode_project.dart';


class XCDebug {
  XCDebug(this._processUtils, this._logger, this._xcode, this.project, this.deviceId);


  final ProcessUtils _processUtils;
  final Logger _logger;
  final Xcode _xcode;
  final IosProject project;
  final String deviceId;

  String? _xcodeProcessId;


  Future<bool> _openProjectInXcode() async {
    try {
      final RunResult result = await _processUtils.run(
        <String>[
          'open',
          '-n',
          '-F',
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

    int maxRetires = 3;
    for (int currentTry = 0; currentTry < maxRetires; currentTry++) {
      try {
        final RunResult result = await _processUtils.run(
          <String>[
            ..._xcode.xcrunCommand(),
            'xcdebug',
            '--pid', // Xcode process id
            _xcodeProcessId!,
            '-s', // scheme
            project.hostAppProjectName,
            '-d', // destination
            deviceId,
            '-b', // Leave Xcode as background app
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
