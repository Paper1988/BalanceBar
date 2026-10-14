# BalanceBar

A lightweight macOS menu bar utility for adjusting audio output balance.

BalanceBar lets you fine-tune the left and right audio channel balance directly from the menu bar, without navigating through System Settings every time.

## Features

- **Menu bar control**: Adjust audio balance directly from the menu bar.
- **System synchronization**: Keep BalanceBar and macOS audio balance settings synchronized in both directions.
- **Custom menu bar icon**: A minimal monochrome icon designed for the macOS menu bar.
- **Launch at login**: Option to launch automatically when you sign in.
- **Lightweight**: Built with native Swift and SwiftUI frameworks.

## Requirements

- macOS 13.0 or later
- A Mac with a compatible audio output device

## Installation

1. Download `BalanceBar-1.0.0.dmg` from the project's Releases page.
2. Open the DMG file.
3. Drag `BalanceBar.app` into the Applications folder.
4. Launch BalanceBar.

Depending on how the app is signed and distributed, macOS may display a security warning.

## Development

BalanceBar uses native macOS frameworks:

- Swift
- SwiftUI
- Core Audio
- AudioToolbox
- ServiceManagement

The application is currently built using the Swift compiler directly.

## Project Structure

```text
BalanceBar/
├── BalanceBar.swift
├── Assets/
│   └── BalanceBarIcon.png
├── README.md
├── LICENSE
├── .gitignore
└── build/
```

Build artifacts and generated disk images are intended for local development and release packaging, rather than source control.

## Status

BalanceBar is a working personal macOS utility. The current version is 1.0.0.

## License

See [LICENSE](LICENSE) for licensing terms.
