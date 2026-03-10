import Foundation
import UIKit
import Combine
import AppTrackingTransparency
import AdSupport
import GoogleMobileAds
import UserMessagingPlatform
import SwiftUI

// MARK: - Ad Unit IDs
private enum AdUnitID {
    static let appID        = "ca-app-pub-8441279613750528~1032884484"
    static let interstitial = "ca-app-pub-8441279613750528/4696362559"
    static let banner       = "ca-app-pub-8441279613750528/3174572910"
}

// MARK: - AdMobManager
final class AdMobManager: NSObject, ObservableObject {

    static let shared = AdMobManager()

    @Published var isInterstitialReady: Bool = false
    @Published var isInitialized: Bool       = false
    @Published var attStatus: ATTrackingManager.AuthorizationStatus = .notDetermined

    private var interstitialAd: InterstitialAd?
    private var onAdDismissed: (() -> Void)?

    private override init() { super.init() }

    // MARK: - Initialize (UMP → AdMob)
    // onConsentComplete wird aufgerufen sobald der UMP-Dialog abgeschlossen ist
    // (oder übersprungen wurde). Ideal um danach den ATT-Prompt zu zeigen.
    func initialize(onConsentComplete: (() -> Void)? = nil) {
        let params = RequestParameters()
        params.isTaggedForUnderAgeOfConsent = false

        ConsentInformation.shared.requestConsentInfoUpdate(
            with: params) { [weak self] error in
                if let error {
                    #if DEBUG
                    print("[UMP] Info update error: \(error)")
                    #endif
                    // Auch bei Fehler Callback ausführen, damit ATT nicht blockiert
                    DispatchQueue.main.async { onConsentComplete?() }
                    return
                }
                // Consent Form laden & anzeigen (nur wenn nötig)
                ConsentForm.loadAndPresentIfRequired(
                    from: UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .flatMap { $0.windows }
                        .first { $0.isKeyWindow }?
                        .rootViewController) { [weak self] error in
                        if let error {
                            #if DEBUG
                            print("[UMP] Form error: \(error)")
                            #endif
                        }
                        // Erst JETZT AdMob starten
                        if ConsentInformation.shared.canRequestAds {
                            self?.startAdMob()
                        }
                        // UMP abgeschlossen → Callback für ATT-Prompt
                        DispatchQueue.main.async { onConsentComplete?() }
                    }
            }
    }

    private func startAdMob() {
        MobileAds.shared.start { [weak self] _ in
            DispatchQueue.main.async {
                self?.isInitialized = true
                self?.loadInterstitial()
            }
        }
    }

    // MARK: - ATT-Prompt (einmalig nach Onboarding)
    func requestTrackingPermission() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            ATTrackingManager.requestTrackingAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    self?.attStatus = status
                    self?.loadInterstitial()
                }
            }
        }
    }

    // MARK: - Load Interstitial
    func loadInterstitial() {
        guard isInitialized else { return }
        let request = Request()
        InterstitialAd.load(with: AdUnitID.interstitial, request: request) { [weak self] ad, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    #if DEBUG
                    print("[AdMob] Interstitial load error: \(error.localizedDescription)")
                    #endif
                    return
                }
                self.interstitialAd = ad
                self.interstitialAd?.fullScreenContentDelegate = self
                self.isInterstitialReady = true
            }
        }
    }

    // MARK: - Show Interstitial (nach jeder Fahrt)
    func showInterstitial(onDismiss: @escaping () -> Void = {}) {
        guard !SubscriptionManager.shared.isPro else { onDismiss(); return }
        guard isInitialized, isInterstitialReady, let ad = interstitialAd else { onDismiss(); return }

        self.onAdDismissed = onDismiss

        guard let rootVC = rootViewController() else { onDismiss(); return }
        ad.present(from: rootVC)
    }

    // MARK: - Helper
    private func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController
    }
}

// MARK: - FullScreenContentDelegate
extension AdMobManager: FullScreenContentDelegate {
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        DispatchQueue.main.async { [weak self] in
            self?.onAdDismissed?()
            self?.isInterstitialReady = false
            self?.interstitialAd = nil
            self?.loadInterstitial()
        }
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        #if DEBUG
        print("[AdMob] Präsentation fehlgeschlagen: \(error.localizedDescription)")
        #endif
        DispatchQueue.main.async { [weak self] in
            self?.onAdDismissed?()
        }
    }
}

// MARK: - AdMobBannerView (SwiftUI)
// Wird bei Pro-Usern automatisch ausgeblendet.

struct AdMobBannerView: View {
    @EnvironmentObject private var subscription: SubscriptionManager

    var body: some View {
        if !subscription.isPro {
            GADBannerViewRepresentable(adUnitID: AdUnitID.banner)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
        }
    }
}

// MARK: - BannerView Representable
struct GADBannerViewRepresentable: UIViewRepresentable {
    let adUnitID: String

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = adUnitID
        banner.rootViewController = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}
}
