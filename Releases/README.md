# Releases

`Scripts/release-mac.sh <version>` writes the signed, notarized DMG here (ignored by Git), publishes it as a GitHub release and commits the Sparkle `appcast.xml`. Release notes live in `release-notes/<version>.md` and are attached to the GitHub release verbatim.
