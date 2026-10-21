"""Brand sheet and lockups for the app icon: HTML laid out like the earlier renderer's sheets, drawn by headless
Chromium. Reads brand-sheet.json next to this file.

    uv run --with pillow python docs/brand/brand_sheet.py [path/to/chrome-headless-shell]
"""
import glob, html, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
from PIL import Image

HERE = Path(__file__).resolve().parent
cfg = json.loads((HERE / "brand-sheet.json").read_text())
chrome = sys.argv[1] if len(sys.argv) > 1 else sorted(glob.glob(os.path.expanduser(
    "~/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell")))[-1]
work = Path(tempfile.mkdtemp())
icon = Image.open(HERE / cfg["icon"]).convert("RGBA")
icon.save(work / "icon.png")
SIZES = [256, 128, 64, 32, 16]
for s in SIZES:  # each strip size as the icon set has it, shown at 1 device pixel per pixel
    icon.resize((s, s), Image.LANCZOS).save(work / f"i{s}.png")
e = html.escape
BASE = """<meta charset="utf-8"><style>
* { margin: 0; box-sizing: border-box }
body { width: %dpx; height: %dpx; background: %s; font-family: -apple-system, system-ui, sans-serif; overflow: hidden }
.serif { font-family: "Hiragino Mincho ProN", serif; font-weight: 600 }
.mono { font-family: "SF Mono", Menlo, monospace }
</style>"""

def shoot(page, w, h, out):
    (work / "p.html").write_text(page)
    subprocess.run([chrome, "--headless", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=2",
                    f"--window-size={w},{h}", f"--screenshot={HERE / out}", f"file://{work}/p.html"],
                   check=True, capture_output=True)
    print("wrote", out)

# Positions measured from the renderer's sheets (1200 x 700 CSS px, drawn at 2x).
CX = {256: 713, 128: 838, 64: 914, 32: 966, 16: 1006}

def strip(top, bg):
    cells = "".join(f'<img src="i{s}.png" style="position:absolute;width:{s * .48:.1f}px;left:{CX[s] - s * .24:.1f}px;'
                    f'top:{top + 69 - s * .24:.1f}px"><div class="mono" style="position:absolute;font-size:7px;color:#8a8a8a;'
                    f'width:40px;text-align:center;left:{CX[s] - 20}px;top:{top + 141}px">{s}</div>' for s in SIZES)
    return f'<div style="position:absolute;left:635px;top:{top}px;width:510px;height:160px;border-radius:13px;background:{bg}"></div>{cells}'

if "sheet" in cfg:
    sw = "".join(f'<div style="position:absolute;left:{650 + i * 125}px;top:312px;display:flex;align-items:center;gap:8px">'
                 f'<div style="width:22px;height:22px;border-radius:11px;background:{c};box-shadow:inset 0 0 0 0.5px rgba(0,0,0,.15)"></div>'
                 f'<div><div style="font-size:10px;font-weight:600;color:#1b1b1d">{e(n)}</div><div class="mono" '
                 f'style="font-size:7.5px;color:#777;margin-top:2px">{c}</div></div></div>' for i, (n, c) in enumerate(cfg["swatches"]))
    line = '<span style="margin:0 .8em">·</span>'.join(e(x) for x in cfg["line"])
    page = (BASE % (1200, 700, "#F1EEEA")) + f"""
<img src="icon.png" style="position:absolute;left:52px;top:82px;width:536px;filter:drop-shadow(0 12px 20px rgba(0,0,0,.16))">
<div style="position:absolute;left:648px;top:44px;font-size:74px;font-weight:700;letter-spacing:-2.5px;color:#111">{e(cfg["name"])}</div>
<div class="serif" style="position:absolute;left:651px;top:134px;font-size:23px;letter-spacing:2px;color:{cfg["accent"]}">{line}</div>
<div style="position:absolute;left:650px;top:168px;width:420px;font-size:13px;line-height:21.6px;color:#4a4a4c">{e(cfg["sheet"])}</div>
{sw}{strip(351, "#F7F4EF")}{strip(516, "#121014")}"""
    shoot(page, 1200, 700, cfg["sheet_out"])

for out, bg, fg, sub in cfg.get("lockups", []):
    page = (BASE % (520, 240, bg)) + f"""
<div style="position:absolute;left:40px;top:40px;width:160px;height:160px"><img src="icon.png" style="width:100%;
  filter:drop-shadow(0 6px 10px rgba(0,0,0,.18))"></div>
<div style="position:absolute;left:226px;top:58px;font-size:58px;font-weight:700;letter-spacing:-1.5px;color:{fg}">{e(cfg["name"])}</div>
<div class="serif" style="position:absolute;left:228px;top:150px;font-size:20px;letter-spacing:2px;color:{sub}">{e(cfg["lockup_line"])}</div>"""
    shoot(page, 520, 240, out)
shutil.rmtree(work)
