#!/usr/bin/env python3
"""Steam Artwork & Grid Assets Injector for suckless-odin."""

import argparse
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Final


@dataclass
class SteamShortcut:
    """Represents a Steam Non-Steam shortcut."""

    app_name: str
    app_id: str


@dataclass
class SteamConfig:
    """Models the Steam environment with configurable paths."""

    root_paths: list[Path]
    grid_dir: Path
    shortcuts: list[SteamShortcut] = field(default_factory=list)


class SteamIntegrationError(Exception):
    """Custom exception for Steam integration failures."""


def get_steam_root(search_paths: list[Path]) -> Path:
    """Detects the Steam installation root from provided search paths."""
    for path in search_paths:
        if path.exists():
            return path
    raise SteamIntegrationError(f"Steam installation not found in: {search_paths}")


def load_config(search_paths: list[Path], target_name: str) -> SteamConfig:
    """Initializes Steam configuration and finds shortcut grid directory."""
    root = get_steam_root(search_paths)
    userdata = root / "userdata"
    shortcut_file = next(userdata.glob("*/config/shortcuts.vdf"), None)

    if not shortcut_file:
        raise SteamIntegrationError(f"No shortcuts.vdf found in {userdata}.")

    return SteamConfig(
        root_paths=search_paths,
        grid_dir=shortcut_file.parent.parent / "grid",
        shortcuts=[SteamShortcut(app_name=target_name, app_id="-1715085355")],
    )


def inject_assets(config: SteamConfig, target_name: str, assets_dir: Path, icon_source: Path) -> None:
    """Copies artwork assets to the Steam grid folder."""
    shortcut = next((s for s in config.shortcuts if s.app_name == target_name), None)
    if not shortcut:
        raise SteamIntegrationError(f"Shortcut '{target_name}' not configured.")

    config.grid_dir.mkdir(parents=True, exist_ok=True)

    assets: Final = {
        "banner.png": f"{shortcut.app_id}.png",
        "cover.png": f"{shortcut.app_id}p.png",
        "hero.png": f"{shortcut.app_id}_hero.png",
        "logo.png": f"{shortcut.app_id}_logo.png",
    }

    print(f"==> Injecting Steam Grid assets into {config.grid_dir}...")
    for src, dst in assets.items():
        src_path = assets_dir / src
        if src_path.exists():
            shutil.copy2(src_path, config.grid_dir / dst)
            print(f"    ✓ {src} -> {dst}")
        else:
            print(f"    ⚠️ Warning: Source {src_path} not found.")

    if icon_source.exists():
        dest_icon = config.grid_dir / f"{target_name}_icon.ico"
        shutil.copy2(icon_source, dest_icon)
        print(f"    ✓ Icon deployed to {dest_icon}")


def main() -> None:
    """Main execution entry point."""
    parser = argparse.ArgumentParser(description="Inject artwork and icons into Steam for suckless-odin.")
    parser.add_argument(
        "--target",
        default="suckless-odin.exe",
        help="The application name as it appears in the Steam library.",
    )
    parser.add_argument(
        "--assets-dir",
        type=Path,
        default=Path("assets/steam_grid"),
        help="Directory containing generated Steam Grid images.",
    )
    parser.add_argument(
        "--icon",
        type=Path,
        default=Path("assets/steam_grid/icon.ico"),
        help="Path to the .ico application icon.",
    )
    parser.add_argument(
        "--paths",
        nargs="+",
        type=Path,
        default=[
            Path.home() / ".var/app/com.valvesoftware.Steam/.local/share/Steam",
            Path.home() / ".local/share/Steam",
        ],
        help="Search paths for Steam installation.",
    )

    args = parser.parse_args()

    try:
        config = load_config(args.paths, args.target)
        inject_assets(config, args.target, args.assets_dir, args.icon)
        print("[✓] Steam artworks injected successfully.")
    except SteamIntegrationError as e:
        print(f"[i] Steam notice: {e}")
    except Exception as e:
        print(f"❌ Error during injection: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
