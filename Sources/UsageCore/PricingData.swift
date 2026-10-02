/// Bundled prices in $/MTok (spec §9). Embedded as source so the app bundle needs no resource bundle.
let builtinPricingJSON = #"""
{
  "models": [
    {"prefix": "claude-fable-5-1",  "input": 10.00, "output": 50.00, "cacheRead": 0.25},
    {"prefix": "claude-fable-5",    "input": 10.00, "output": 50.00, "cacheRead": 1.00},
    {"prefix": "claude-opus-5-5",   "input": 4.00,  "output": 20.00, "cacheRead": 0.20},
    {"prefix": "claude-opus-5",     "input": 5.00,  "output": 25.00, "cacheRead": 0.50},
    {"prefix": "claude-opus-4-8",   "input": 5.00,  "output": 25.00, "cacheRead": 0.50},
    {"prefix": "claude-opus-4-7",   "input": 5.00,  "output": 25.00, "cacheRead": 0.50},
    {"prefix": "claude-opus-4-6",   "input": 5.00,  "output": 25.00, "cacheRead": 0.50},
    {"prefix": "claude-sonnet-5-5", "input": 2.00,  "output": 10.00, "cacheRead": 0.20},
    {"prefix": "claude-sonnet-5",   "input": 2.00,  "output": 10.00, "cacheRead": 0.20},
    {"prefix": "claude-sonnet-4-6", "input": 3.00,  "output": 15.00, "cacheRead": 0.30},
    {"prefix": "claude-haiku-4-5",  "input": 1.00,  "output": 5.00,  "cacheRead": 0.10}
  ],
  "plans": {"Max 20x": 200, "Max 5x": 100, "Max": 100, "Pro": 20, "Team · Premium": 150, "Team": 30}
}
"""#
