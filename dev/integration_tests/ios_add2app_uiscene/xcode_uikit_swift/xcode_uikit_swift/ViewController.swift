// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import UIKit
//import Flutter

class ViewController: UIViewController {
  var flutterEngine: String?
  
  override func viewDidLoad() {
    super.viewDidLoad()
    // Do any additional setup after loading the view.
  }
  
  override func viewIsAppearing(_ animated: Bool) {
    guard let sceneDelegate = self.view.window?.windowScene?.delegate as? SceneDelegate else { return }
    let flutterEngine = sceneDelegate.flutterEngine
    let flutterViewController =
            FlutterViewController(engine: flutterEngine, nibName: nil, bundle: nil)
  }


}
