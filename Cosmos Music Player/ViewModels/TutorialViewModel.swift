//
//  TutorialViewModel.swift
//  Cosmos Music Player
//
//  View model for the tutorial flow
//

import Foundation
import UIKit
import CloudKit

class TutorialViewModel: ObservableObject {
    @Published var currentStep: Int = 0
    @Published var isSignedIntoAppleID: Bool = false
    @Published var isiCloudDriveEnabled: Bool = false
    @Published var appleIDDetectionFailed: Bool = false
    @Published var iCloudDetectionFailed: Bool = false
    
    init() {
        setupNotificationObservers()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupNotificationObservers() {
        // Monitor iCloud Drive availability changes
        NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.info("iCloud Drive status changed - rechecking...", category: "Tutorial")
            self?.checkiCloudDriveStatus()
        }
        
        // Monitor CloudKit account changes  
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.info("CloudKit account status changed - rechecking...", category: "Tutorial")
            self?.checkAppleIDStatus()
        }
    }
    
    var canProceedFromAppleID: Bool {
        return true // Always allow proceeding - let user decide
    }
    
    var canProceedFromiCloud: Bool {
        return true // Always allow proceeding - let user decide
    }
    
    func nextStep() {
        if currentStep < 2 {
            currentStep += 1
        }
    }
    
    func previousStep() {
        if currentStep > 0 {
            currentStep -= 1
        }
    }
    
    func checkAppleIDStatus() {
        // NOTE: CKContainer.default().accountStatus(...) used to be called here.
        // Two crash logs (2026-07-01 19:26:55 and 19:27:36 — same build, same
        // app-binary offset, 41 seconds apart) show a SIGTRAP originating
        // inside CloudKit's own internal dispatch_once, triggered right at
        // this call site. That matches a missing CloudKit/iCloud entitlement
        // in this ad-hoc/unsigned build's provisioning — the same class of
        // issue already worked around for Siri vocabulary setup. The crash
        // is tied to the build's provisioning, not the user's account state,
        // so it would trap every time regardless of retry.
        //
        // Going straight to the FileManager-based check instead avoids
        // CloudKit entirely and needs no entitlement.
        DebugLogger.shared.info("checkAppleIDStatus: using FileManager-only path (CloudKit skipped — ad-hoc build has no CloudKit entitlement)", category: "Tutorial")
        fallbackAppleIDCheck()
    }
    
    private func fallbackAppleIDCheck() {
        // Fallback to FileManager approach if CloudKit fails
        let hasIdentityToken = FileManager.default.ubiquityIdentityToken != nil
        let hasContainerAccess = FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
        
        if hasIdentityToken || hasContainerAccess {
            isSignedIntoAppleID = true
            appleIDDetectionFailed = false
            DebugLogger.shared.info("Apple ID check: fallback detection successful", category: "Tutorial")
        } else {
            isSignedIntoAppleID = false
            appleIDDetectionFailed = true
            DebugLogger.shared.warning("Apple ID check: fallback detection failed", category: "Tutorial")
        }
    }
    
    func checkiCloudDriveStatus() {
        // Check specifically for iCloud Drive document storage availability
        // This is the correct use of ubiquityIdentityToken according to Apple docs
        
        let hasIdentityToken = FileManager.default.ubiquityIdentityToken != nil
        let hasContainerAccess = FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
        
        DebugLogger.shared.info("iCloud Drive check: identity token=\(hasIdentityToken), container access=\(hasContainerAccess)", category: "Tutorial")
        
        if hasIdentityToken {
            // Identity token exists - iCloud Drive document storage is definitely enabled
            isiCloudDriveEnabled = true
            iCloudDetectionFailed = false
            DebugLogger.shared.info("iCloud Drive check: confirmed enabled (identity token present)", category: "Tutorial")
            
        } else if hasContainerAccess {
            // Has container URL but no identity token
            // This can happen when user is signed into iCloud but iCloud Drive is disabled
            // Let's try to create a test file to verify write access
            checkiCloudDriveWriteAccess()
            
        } else {
            // No container access - either not signed in or iCloud Drive completely disabled
            isiCloudDriveEnabled = false
            iCloudDetectionFailed = false
            DebugLogger.shared.info("iCloud Drive check: disabled (no container access)", category: "Tutorial")
        }
    }
    
    private func checkiCloudDriveWriteAccess() {
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            isiCloudDriveEnabled = false
            iCloudDetectionFailed = true
            DebugLogger.shared.warning("iCloud Drive check: container became unavailable", category: "Tutorial")
            return
        }
        
        // Try to check if the container is actually writable
        do {
            let testFolderURL = containerURL.appendingPathComponent("Cosmos Player", isDirectory: true)
            
            // Try to create the app folder (this is what our app would do anyway)
            if !FileManager.default.fileExists(atPath: testFolderURL.path) {
                try FileManager.default.createDirectory(at: testFolderURL, 
                                                     withIntermediateDirectories: true, 
                                                     attributes: nil)
            }
            
            // If we can access and create directories, iCloud Drive is working
            isiCloudDriveEnabled = true
            iCloudDetectionFailed = false
            DebugLogger.shared.info("iCloud Drive check: enabled (verified write access)", category: "Tutorial")
            
        } catch {
            // Cannot write to container - iCloud Drive is likely disabled for this app
            isiCloudDriveEnabled = false
            iCloudDetectionFailed = false
            DebugLogger.shared.error("iCloud Drive check: no write access: \(error.localizedDescription)", category: "Tutorial")
        }
    }
    
    @MainActor func openAppleIDSettings() {
        // Try multiple URL schemes for Apple ID settings
        let appleIDUrls = [
            "prefs:root=APPLE_ACCOUNT",
            "prefs:root=APPLE_ACCOUNT&path=SIGN_IN",
            "App-prefs:APPLE_ACCOUNT",
            "App-prefs:root=APPLE_ACCOUNT"
        ]

        for urlString in appleIDUrls {
            if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
        
        // If none work, open main Settings app (user can navigate to Apple ID from there)
        openMainSettings()
    }
    
    @MainActor func openiCloudSettings() {
        // Try multiple URL schemes for iCloud settings
        let iCloudUrls = [
            "prefs:root=CASTLE",
            "prefs:root=CASTLE&path=STORAGE_AND_BACKUP",
            "App-prefs:CASTLE",
            "App-prefs:root=CASTLE"
        ]
        
        for urlString in iCloudUrls {
            if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
        
        // If none work, open main Settings app (user can navigate to iCloud from there)
        openMainSettings()
    }
    
    @MainActor private func openMainSettings() {
        // Open the main Settings app (not app-specific settings)
        if let url = URL(string: "prefs:"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let url = URL(string: "App-Prefs:"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            // Last resort: open app-specific settings
            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            UIApplication.shared.open(url)
        }
    }
    
    func completeTutorial() {
        // Save that tutorial has been completed
        UserDefaults.standard.set(true, forKey: "HasCompletedTutorial")
        DebugLogger.shared.info("Tutorial completed and saved to UserDefaults", category: "Tutorial")
    }
    
    static func shouldShowTutorial() -> Bool {
        return !UserDefaults.standard.bool(forKey: "HasCompletedTutorial")
    }
}