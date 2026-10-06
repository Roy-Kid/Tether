"""Generate the Windows icon from the shared logo (requires Pillow)."""
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parent.parent
destination = root / "app-win" / "Assets" / "Tether.ico"
destination.parent.mkdir(parents=True, exist_ok=True)
with Image.open(root / "assets" / "logo.png") as logo:
    logo.convert("RGBA").save(destination, format="ICO",
        sizes=[(size, size) for size in (16, 20, 24, 32, 40, 48, 64, 128, 256)])
print(destination)
