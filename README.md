# Spiker Packages

Public release repository for Spiker setup packages.

The private `hasan-ozdemir/spiker` repository builds `spiker-setup.exe` and dispatches this repository's `publish-spiker-setup.yml` workflow. That workflow downloads the private `spiker-setup` artifact with the `SPIKER_SOURCE_TOKEN` secret and publishes it to GitHub Releases.

For `push` events on the private repository's `main` branch, this repository is a cutover feed: after the new setup release is published, every older release and its tag is deleted so only the latest setup release remains.
