//
//  SceneDelegate 2.swift
//  GraphEvoDemo
//
//  Created by GraphEvoDemo contributors.
//


import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {

        guard let windowScene = scene as? UIWindowScene else {
            print("❌ Not a UIWindowScene")
            return
        }

        print("✅ SceneDelegate started")

        let window = UIWindow(windowScene: windowScene)
        let root: UIViewController
        if let request = V02Request.parse(ProcessInfo.processInfo.arguments) {
            root = V02ViewController(request: request)
        } else if let request = V01OwnerOnlyShareTrial.parse(ProcessInfo.processInfo.arguments) {
            root = V01OwnerOnlyShareViewController(request: request)
        } else if let request = V01LaunchRequest.parse(ProcessInfo.processInfo.arguments) {
            root = V01ViewController(automaticRequest: request)
        } else {
            root = LaunchViewController(style: .insetGrouped)
        }
        let tabBarController = UINavigationController(rootViewController: root)
        window.rootViewController = tabBarController
        self.window = window
        window.makeKeyAndVisible()
    }
}
