"""Builds Veil/Resources/blocklist.json for WebKit's content blocker.

Sources (domain lists, low false-positive rate):
  - Peter Lowe's ad and tracking server list (via StevenBlack/hosts data/yoyo.org)
  - AdAway's default list (via StevenBlack/hosts data/adaway.org)
  - Veil's own extra tracker domains (EXTRA below)
Plus a short list of safe element-hiding selectors.

Usage: python3 tools/build_blocklist.py yoyo.txt adaway.txt
Each rule blocks third-party loads from a domain and all its subdomains.
"""
import json
import re
import sys

EXTRA = """
doubleclick.net googlesyndication.com googleadservices.com google-analytics.com googletagmanager.com
googletagservices.com adservice.google.com app-measurement.com connect.facebook.net graph.facebook.com
analytics.twitter.com ads-twitter.com static.ads-twitter.com analytics.tiktok.com ads.tiktok.com
bat.bing.com clarity.ms scorecardresearch.com quantserve.com hotjar.com hotjar.io mixpanel.com
segment.io segment.com amplitude.com fullstory.com mouseflow.com crazyegg.com newrelic.com
nr-data.net taboola.com outbrain.com criteo.com criteo.net adnxs.com rubiconproject.com pubmatic.com
openx.net casalemedia.com advertising.com adsrvr.org moatads.com doubleverify.com adsafeprotected.com
amazon-adsystem.com media.net yieldmo.com sharethrough.com teads.tv 3lift.com indexww.com
smartadserver.com chartbeat.com chartbeat.net parsely.com branch.io adjust.com appsflyer.com
""".split()

# Element hiding that is common across ad networks and rarely matches real content.
HIDE = [
    "ins.adsbygoogle",
    ".adsbygoogle",
    "div[id^=\"div-gpt-ad\"]",
    "[id^=\"google_ads_iframe\"]",
    "iframe[src*=\"doubleclick.net\"]",
    "iframe[src*=\"googlesyndication.com\"]",
    "iframe[id^=\"google_ads_\"]",
    "div[data-google-query-id]",
    ".trc_rbox_container",
    ".OUTBRAIN",
    "div[id^=\"taboola-\"]",
    "amp-ad",
    "amp-embed[type=\"taboola\"]",
]

# Never block these, even if a list includes them (would break common sites).
ALLOW = {
    "localhost", "local", "0.0.0.0", "broadcasthost", "ip6-localhost", "ip6-loopback",
    # Needed for some video players to start playback.
    "entitlements.jwplayer.com",
}

DOMAIN = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")


def read_hosts(path):
    out = set()
    for line in open(path, encoding="utf-8", errors="ignore"):
        line = line.split("#", 1)[0].strip()
        parts = line.split()
        if len(parts) >= 2 and parts[0] in ("0.0.0.0", "127.0.0.1"):
            d = parts[1].lower().strip(".")
            if d not in ALLOW and DOMAIN.match(d):
                out.add(d)
    return out


def collapse(domains):
    """Drops subdomains whose parent is already listed, since rules cover subdomains."""
    keep = set()
    for d in domains:
        labels = d.split(".")
        if any(".".join(labels[i:]) in domains for i in range(1, len(labels) - 1)):
            continue
        keep.add(d)
    return sorted(keep)


def main(paths):
    domains = set(EXTRA)
    for p in paths:
        domains |= read_hosts(p)
    domains = collapse(domains)

    rules = []
    for d in domains:
        rules.append({
            "trigger": {
                "url-filter": "^[^:]+://+([^:/]+\\.)?" + re.escape(d).replace("\\-", "-") + "[:/]",
                "load-type": ["third-party"],
            },
            "action": {"type": "block"},
        })
    rules.append({
        "trigger": {"url-filter": ".*"},
        "action": {"type": "css-display-none", "selector": ", ".join(HIDE)},
    })
    with open("Veil/Resources/blocklist.json", "w") as f:
        json.dump(rules, f, separators=(",", ":"))
    print(f"{len(domains)} domains, {len(rules)} rules")


if __name__ == "__main__":
    main(sys.argv[1:])
