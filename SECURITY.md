# Security policy

## Supported versions

Lagoon Engine is a Swift package. Only the latest tagged release is
supported. Fixes land in the next release rather than in patches to older
ones.

## Reporting a vulnerability

Please report privately rather than opening an issue, and give the fix a
chance to ship before describing the problem publicly.

- Email **support@helop.dev**.
- Include the library version (the tag, or the commit if you are on main),
  the platform and OS version, the device or simulator, what an attacker
  could achieve, and the steps to reproduce it.
- Say whether you want credit in the release notes, and under what name.

There is no bug bounty. This is a small project maintained by one person, so
expect an acknowledgement within about a week, an assessment of severity and
scope after that, and a note when the fix is in a tagged release. If you have
not heard back in two weeks, send a reminder.

## What the engine talks to

Lagoon Engine is not a client for any service. It opens the media source URL
it is handed, and nothing else: no accounts, no Jellyfin, no diagnostics
service.
