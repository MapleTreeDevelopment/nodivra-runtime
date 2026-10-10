"""Shared navigation inside authenticated Home Assistant ingress."""
from pathlib import Path

def navigation(current, prefix="./"):
    icons = {
        "dashboards": '<rect x="3" y="3" width="7" height="18" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
        "automations": '<circle cx="5" cy="5" r="2"/><circle cx="19" cy="5" r="2"/><circle cx="12" cy="19" r="2"/><path d="m6 7 5 10m7-10-5 10M7 5h10"/>',
        "runtime": '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9h18M3 15h18M7 6h.01M7 12h.01M7 18h.01"/>',
    }
    def link(key, title, path):
        active = ' aria-current="page"' if current == key else ''
        return f'<a class="tool-link" href="{prefix}{path}"{active}><svg viewBox="0 0 24 24" aria-hidden="true">{icons[key]}</svg><span>{title}</span></a>'
    return ('<aside class="tool-sidebar"><div class="tool-brand"><span class="tool-brand-mark" aria-hidden="true">'
            '<svg viewBox="0 0 24 24"><circle cx="5" cy="5" r="2"/><circle cx="19" cy="5" r="2"/><circle cx="12" cy="19" r="2"/><path d="m6 7 5 10m7-10-5 10M7 5h10"/></svg></span>'
            '<div><strong>Nodivra</strong><small>Dein Zuhause</small></div></div><nav aria-label="Nodivra Navigation">'
            + link("dashboards", "Dashboards", "dashboards/") + link("automations", "Automationen", "?view=automations")
            + '</nav><nav id="dashboard-page-nav" aria-label="Dashboard-Seiten" hidden></nav><nav class="tool-settings" aria-label="Runtime-Einstellungen">'
            + link("runtime", "Runtime", "?view=runtime") + '</nav></aside>')

def navigation_style():
    return Path(__file__).with_name("navigation.css").read_text()
