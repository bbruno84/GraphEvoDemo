//
//  AppDelegate.swift
//  GraphEvoDemo
//
//  Created by GraphEvoDemo contributors.
//


import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        print("✅ App launched - initializing Graph")
        let _ = GraphProvider.shared.graph
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("☁️ GraphEvoDemo remote notification received: \(userInfo)")
        // GraphEvo's internal remote-change coordinator processes Persistent
        // History after the store has been prepared in GraphProvider.
        completionHandler(.newData)
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
