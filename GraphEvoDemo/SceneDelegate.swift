//
//  SceneDelegate 2.swift
//  GraphEvoDemo
//
//  Created by Valerio Buriani on 09/09/25.
//


import UIKit
import CloudKit

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
        let tabBarController = UINavigationController(rootViewController: DemoLaunchViewController())
        window.rootViewController = tabBarController
        self.window = window
        window.makeKeyAndVisible()
        if let metadata = connectionOptions.cloudKitShareMetadata { routeNativeInvitation(metadata) }
    }
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        routeNativeInvitation(cloudKitShareMetadata)
    }
    private func routeNativeInvitation(_ metadata: CKShare.Metadata) {
        guard let navigation = window?.rootViewController as? UINavigationController else { return }
        if let existing = navigation.viewControllers.last as? PublicV2ViewController {
            existing.receiveNativeInvitation(metadata)
            return
        }
        do {
            let controller = try PublicV2ViewController.make()
            controller.receiveNativeInvitation(metadata)
            navigation.pushViewController(controller, animated: false)
        } catch {
            let alert = UIAlertController(title: "Invitation unavailable", message: "The invitation could not be retained locally. Open the original Apple invitation again after resolving local storage availability.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            navigation.present(alert, animated: true)
        }
    }
}
