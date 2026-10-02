import Foundation

enum Fixtures {
    static let usageJSON = #"""
    {
      "five_hour": {"utilization": 25.0, "resets_at": "2026-10-01T22:30:00.474962+00:00", "limit_dollars": null},
      "seven_day": {"utilization": 54.0, "resets_at": "2026-10-06T04:00:00.474983+00:00"},
      "seven_day_oauth_apps": null, "seven_day_opus": null, "seven_day_sonnet": null,
      "tangelo": null, "iguana_necktie": null, "amber_gauge": null,
      "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null},
      "limits": [
        {"kind": "session", "group": "session", "percent": 25, "severity": "normal",
         "resets_at": "2026-10-01T22:30:00.474962+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_all", "group": "weekly", "percent": 54, "severity": "normal",
         "resets_at": "2026-10-06T04:00:00.474983+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 64, "severity": "normal",
         "resets_at": "2026-10-06T04:00:00.475185+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": true}
      ],
      "spend": {"used": {"amount_minor": 0, "currency": "USD", "exponent": 2}, "enabled": false},
      "member_dashboard_available": false,
      "seven_day_breakdown": {
        "as_of": "2026-10-01T19:59:41.660782+00:00",
        "rows": [
          {"key": "claude_code", "display_name": "Claude Code", "percent": 100},
          {"key": "chat", "display_name": "Chats", "percent": 0},
          {"key": "cowork", "display_name": "Cowork", "percent": 0},
          {"key": "other", "display_name": "Other", "percent": 0}
        ]
      }
    }
    """#

    static func profileJSON(accountUuid: String = "acc-A", email: String = "you@work.example",
                            orgUuid: String = "org-A",
                            orgName: String = "you@work.example's Organization") -> String {
        """
        {"account": {"uuid": "\(accountUuid)", "email": "\(email)", "display_name": "Jeff", "full_name": "Jeff",
                     "has_claude_max": true, "has_claude_pro": false, "created_at": "2025-01-01T00:00:00Z"},
         "organization": {"uuid": "\(orgUuid)", "name": "\(orgName)", "organization_type": "claude_max",
                          "rate_limit_tier": "default_claude_max_20x", "subscription_status": "active",
                          "billing_type": "stripe_subscription"}}
        """
    }
}
