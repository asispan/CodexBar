import Foundation
import Testing
@testable import CodexBarCore

struct NousUsageFetcherTests {
    static let accountJSON = """
    {
      "user": { "email": "dev@example.com", "privy_did": "did:privy:abc" },
      "organisation": { "id": "nas_organisation:1", "slug": "4314949a", "name": "dev's account" },
      "subscription": {
        "plan": "Ultra",
        "tier": 9,
        "monthly_charge": 200,
        "monthly_credits": 220,
        "current_period_end": "2026-09-12T04:29:00.000Z",
        "credits_remaining": 55,
        "rollover_credits": 0
      },
      "purchased_credits_remaining": 19.3462440630144,
      "tool_access": { "enabled": false, "coverage": { "fal": true } },
      "paid_service_access": {
        "allowed": true,
        "paid_access": true,
        "reason": "usable_credits",
        "has_active_subscription": true,
        "subscription_credits_remaining": 55,
        "purchased_credits_remaining": 19.3462440630144,
        "total_usable_credits": 74.3462440630144
      }
    }
    """

    @Test
    func `parses account payload into usage and credits`() throws {
        let now = Date(timeIntervalSince1970: 1_788_300_000)
        let account = try NousUsageFetcher._parseAccountForTesting(Data(Self.accountJSON.utf8), now: now)

        #expect(account.email == "dev@example.com")
        #expect(account.organizationName == "dev's account")
        #expect(account.plan == "Ultra")
        #expect(account.monthlyCredits == 220)
        #expect(account.creditsRemaining == 55)
        #expect(account.purchasedCreditsRemaining == 19.3462440630144)
        #expect(account.totalUsableCredits == 74.3462440630144)
        #expect(account.hasActiveSubscription)
        #expect(account.currentPeriodEnd == NousSettingsReader.parseISODate("2026-09-12T04:29:00.000Z"))

        let usage = account.toUsageSnapshot()
        let primary = try #require(usage.primary)
        #expect(abs(primary.usedPercent - 75) < 0.0001)
        #expect(primary.resetsAt == account.currentPeriodEnd)
        #expect(usage.secondary == nil)
        #expect(usage.subscriptionRenewsAt == account.currentPeriodEnd)
        #expect(usage.loginMethod(for: .nous) == "Ultra")
        #expect(usage.identity(for: .nous)?.accountEmail == "dev@example.com")
        #expect(usage.dataConfidence == .exact)
        #expect(usage.details.map(\.title) == ["Subscription", "Credits"])
        #expect(usage.details[0].rows.map(\.label) == ["Monthly credits", "Renews"])
        #expect(usage.details[0].rows[0].value == "$55.00 of $220.00 left")

        let credits = account.toCreditsSnapshot()
        #expect(credits.remaining == 19.3462440630144)
        #expect(credits.updatedAt == now)
    }

    @Test
    func `exhausted monthly grant reports fully used window`() throws {
        let json = Self.accountJSON.replacingOccurrences(of: "\"credits_remaining\": 55", with: "\"credits_remaining\": 0")
        let account = try NousUsageFetcher._parseAccountForTesting(Data(json.utf8))
        #expect(account.toUsageSnapshot().primary?.usedPercent == 100)
    }

    @Test
    func `free tier without monthly credits has no rate window`() throws {
        let json = """
        {
          "user": { "email": "free@example.com" },
          "organisation": { "name": "free's account" },
          "subscription": {
            "plan": "Free",
            "monthly_credits": 0,
            "credits_remaining": 0,
            "rollover_credits": 0,
            "current_period_end": null
          },
          "purchased_credits_remaining": 2.5,
          "paid_service_access": { "has_active_subscription": false, "total_usable_credits": 2.5 }
        }
        """
        let account = try NousUsageFetcher._parseAccountForTesting(Data(json.utf8))
        let usage = account.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.loginMethod(for: .nous) == "Free")
        #expect(account.toCreditsSnapshot().remaining == 2.5)
        #expect(usage.details.map(\.title) == ["Credits"])
    }

    @Test
    func `accepts decimal strings for money fields`() throws {
        let json = """
        {
          "subscription": { "plan": "Plus", "monthly_credits": "22", "credits_remaining": "11", "rollover_credits": "1.5" },
          "purchased_credits_remaining": "3.25"
        }
        """
        let account = try NousUsageFetcher._parseAccountForTesting(Data(json.utf8))
        #expect(account.monthlyCredits == 22)
        #expect(account.creditsRemaining == 11)
        #expect(account.rolloverCredits == 1.5)
        #expect(account.purchasedCreditsRemaining == 3.25)
        #expect(account.toUsageSnapshot().primary?.usedPercent == 50)
    }

    @Test
    func `error payload surfaces as api error`() {
        let json = """
        { "error": "account_missing" }
        """
        #expect {
            _ = try NousUsageFetcher._parseAccountForTesting(Data(json.utf8))
        } throws: { error in
            error as? NousUsageError == .apiError("account_missing")
        }
    }

    @Test
    func `non-object payload is a parse failure`() {
        #expect {
            _ = try NousUsageFetcher._parseAccountForTesting(Data("[1, 2]".utf8))
        } throws: { error in
            if case NousUsageError.parseFailed = error { return true }
            return false
        }
    }

    @Test
    func `account URL appends the oauth account path`() {
        let url = NousUsageFetcher.accountURL(portalBaseURL: URL(string: "https://portal.example.com")!)
        #expect(url.absoluteString == "https://portal.example.com/api/oauth/account")
    }
}
