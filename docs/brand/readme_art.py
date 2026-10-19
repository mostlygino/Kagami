"""Self-contained README artwork. Run beside readme-theme.json; stdlib only.

The material belongs to the app, not the GitHub page: paper fibres, cloth
bindings, enamel lips and a single upper-left light. Real icons stay intact.
SVGs embed their PNGs so they also work through GitHub's image proxy.
"""
from __future__ import annotations

import base64
import json
from html import escape
from pathlib import Path
import textwrap

SANS = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"
MONO = "ui-monospace,'SF Mono',Menlo,Consolas,monospace"


def palette(material: dict, dark: bool) -> dict:
    p = dict(zip(('ground', 'surface', 'ink', 'muted', 'edge', 'accent'), material['dark' if dark else 'light']))
    p.update(kind=material['kind'], dark=dark)
    return p


def surface(w: int, h: int, p: dict, label: str, body: str) -> str:
    """A lit physical surface; all ornament sits behind the readable content."""
    kind = p['kind']
    light = '#ffffff'
    edge, accent = p['edge'], p['accent']
    texture = ''
    if kind in ('cloth', 'paper'):
        texture = f'<rect x="2" y="2" width="{w-4}" height="{h-4}" rx="22" fill="url(#weave)" opacity="{0.1 if p["dark"] else 0.16}"/>'
    detail = ''
    if kind == 'cloth':
        detail = (f'<rect x="10" y="12" width="13" height="{h-24}" rx="6" fill="{accent}" opacity="0.65"/>'
                  f'<path d="M30 24V{h-24}" stroke="{edge}" stroke-dasharray="2 5"/>')
    elif kind == 'paper':
        detail = f'<path d="M24 {h-9}H{w-26}M27 {h-5}H{w-30}" stroke="{edge}" opacity="0.55"/>'
    elif kind == 'enamel':
        detail = (f'<rect x="8" y="8" width="{w-16}" height="{h-16}" rx="18" fill="none" stroke="{edge}" stroke-width="2"/>'
                  f'<path d="M25 10H{w-25}" stroke="{light}" opacity="0.35"/>')
    elif kind in ('glass', 'stone'):
        detail = f'<path d="M{w*.63} 2H{w*.79}L{w*.42} {h-2}H{w*.32}Z" fill="{light}" opacity="0.035"/>'
    elif kind == 'lacquer':
        detail = f'<path d="M26 13H{w-26}" stroke="{accent}" opacity="0.55"/><path d="M26 {h-13}H{w-26}" stroke="{accent}" opacity="0.25"/>'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-label="{escape(label, quote=True)}">
<defs>
 <linearGradient id="material" x1="0" y1="0" x2="0.65" y2="1"><stop stop-color="{p['surface']}"/><stop offset="1" stop-color="{p['ground']}"/></linearGradient>
 <linearGradient id="rim" x2="0" y2="1"><stop stop-color="{light}" stop-opacity="0.55"/><stop offset="0.45" stop-color="{edge}" stop-opacity="0.2"/><stop offset="1" stop-color="{edge}" stop-opacity="0.8"/></linearGradient>
 <pattern id="weave" width="7" height="7" patternUnits="userSpaceOnUse"><path d="M0 1H7M1 0V7" stroke="{edge}" stroke-width="0.7"/><path d="M4 3h2M3 5h1" stroke="{edge}" stroke-width="0.6"/></pattern>
 <filter id="lift" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="7" stdDeviation="8" flood-opacity="0.2"/></filter>
</defs>
<rect x="1" y="1" width="{w-2}" height="{h-2}" rx="24" fill="url(#material)" stroke="{edge}"/>
{texture}{detail}
<rect x="3" y="3" width="{w-6}" height="{h-6}" rx="22" fill="none" stroke="url(#rim)"/>
{body}
</svg>\n'''


def lines(text: str, x: int, y: int, size: int, width: int, colour: str, weight: int = 400) -> str:
    wrapped = textwrap.wrap(text, width=max(1, int(width / (size * .54))))
    return ''.join(f'<text x="{x}" y="{y+i*round(size*1.4)}" font-family="{SANS}" font-size="{size}" font-weight="{weight}" fill="{colour}">{escape(line)}</text>' for i, line in enumerate(wrapped))


def banner(config: dict, dark: bool, icon: str, compact: bool = False) -> str:
    p = palette(config['material'], dark)
    name = config['name']
    title_size = min(82, int(690 / max(1, len(name)) / .58))
    if compact:
        title_size = min(58, int(560 / max(1, len(name)) / .6))
        body = f'''<image href="data:image/png;base64,{icon}" x="244" y="24" width="152" height="152"/>
 <path d="M32 191H608" stroke="{p['edge']}"/>
 <text x="32" y="225" font-family="{MONO}" font-size="15" letter-spacing="1.3" fill="{p['accent']}">{escape(config['eyebrow'].upper())}</text>
 <text x="30" y="298" font-family="{SANS}" font-size="{title_size}" font-weight="700" letter-spacing="-1" fill="{p['ink']}">{escape(name)}</text>
 {lines(config['tagline'],32,345,27,568,p['ink'],500)}
 {lines(config['footer'],32,443,15,570,p['muted'])}'''
        return surface(640,480,p,f"{name}. {config['tagline']}",body)
    body = f'''<path d="M64 81H710" stroke="{p['edge']}"/>
 <text x="64" y="63" font-family="{MONO}" font-size="16" letter-spacing="2.5" fill="{p['accent']}">{escape(config['eyebrow'].upper())}</text>
 <text x="60" y="183" font-family="{SANS}" font-size="{title_size}" font-weight="700" letter-spacing="-2" fill="{p['ink']}">{escape(name)}</text>
 {lines(config['tagline'],64,235,27,650,p['ink'],500)}
 <text x="64" y="342" font-family="{MONO}" font-size="16" letter-spacing="1" fill="{p['muted']}">{escape(config['footer'])}</text>
 <rect x="834" y="40" width="382" height="316" rx="28" fill="{p['ground']}" stroke="{p['edge']}"/>
 <path d="M858 43H1192" stroke="#fff" opacity="0.3"/>
 <ellipse cx="1026" cy="304" rx="103" ry="14" fill="#000" opacity="0.12"/>
 <image href="data:image/png;base64,{icon}" x="901" y="71" width="248" height="248"/>
 <path d="M990 336H1062" stroke="{p['accent']}" stroke-width="3" stroke-linecap="round"/>'''
    return surface(1280,400,p,f"{name}. {config['tagline']}",body)


def features(config: dict, dark: bool, compact: bool = False) -> str:
    p = palette(config['material'], dark)
    parts = []
    for i, (title, description) in enumerate(config['features']):
        x = 36 if compact else 44 + i * 408
        y = 24 + i * 232 if compact else 24
        width = 568 if compact else 376
        parts.append(f'''<rect x="{x}" y="{y}" width="{width}" height="208" rx="14" fill="{p['surface']}" stroke="{p['edge']}"/>
 <path d="M{x+18} {y+3}H{x+width-18}" stroke="#fff" opacity="0.3"/>
 <text x="{x+22}" y="{y+37}" font-family="{MONO}" font-size="14" letter-spacing="2" fill="{p['accent']}">0{i+1}</text>
 {lines(title,x+22,y+81,27,width-44,p['ink'],650)}
 {lines(description,x+22,y+125,24 if compact else 21,width-56,p['muted'])}''')
    label = '; '.join(f'{title}: {description}' for title, description in config['features'])
    return surface(640 if compact else 1280,720 if compact else 256,p,label,''.join(parts))


def render(folder: Path) -> None:
    config = json.loads((folder / 'readme-theme.json').read_text())
    icon = base64.b64encode((folder / config['icon']).read_bytes()).decode()
    for mode in ('light', 'dark'):
        for compact in (False, True):
            suffix = '-mobile' if compact else ''
            (folder / f'readme-banner-{mode}{suffix}.svg').write_text(banner(config, mode == 'dark', icon, compact))
            (folder / f'readme-showcase-{mode}{suffix}.svg').write_text(features(config, mode == 'dark', compact))


if __name__ == '__main__':
    render(Path(__file__).resolve().parent)
