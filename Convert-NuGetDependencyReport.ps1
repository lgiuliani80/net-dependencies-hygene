[CmdletBinding(DefaultParameterSetName = 'Pipeline')]
param(
    [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'Pipeline')]
    [object] $InputObject,
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string] $InputPath,
    [string] $OutputPath = (Join-Path (Get-Location) 'NuGetDependencyReport.html'),
    [switch] $NoOpen
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $entries = [System.Collections.Generic.List[object]]::new()
}

process {
    if ($PSCmdlet.ParameterSetName -eq 'Pipeline') {
        foreach ($entry in @($InputObject)) { $entries.Add($entry) }
    }
}

end {
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $source = (Resolve-Path -LiteralPath $InputPath -ErrorAction Stop).ProviderPath
        $decoded = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json -NoEnumerate
        if ($null -eq $decoded) { throw "Il file '$source' non contiene un report valido." }
        foreach ($entry in @($decoded)) { $entries.Add($entry) }
    }

    foreach ($entry in $entries) {
        foreach ($name in 'Package', 'ResolvedVersions', 'VersionConflict', 'TransitiveMinimums', 'MinimumConflict', 'Occurrences') {
            if ($null -eq $entry -or $null -eq $entry.PSObject.Properties[$name]) {
                throw "Report non valido: campo '$name' mancante."
            }
        }
        if ($entry.Package -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.Package) -or
            $entry.ResolvedVersions -isnot [array] -or $entry.TransitiveMinimums -isnot [array] -or
            $entry.Occurrences -isnot [array] -or $entry.VersionConflict -isnot [bool] -or
            $entry.MinimumConflict -isnot [bool]) {
            throw "Report non valido per il pacchetto '$($entry.Package)': tipi dei campi inattesi."
        }
        foreach ($occurrence in $entry.Occurrences) {
            foreach ($name in 'Project', 'Kind', 'ResolvedVersion', 'RequestedVersion', 'Parents') {
                if ($null -eq $occurrence -or $null -eq $occurrence.PSObject.Properties[$name]) {
                    throw "Report non valido per '$($entry.Package)': occorrenza priva di '$name'."
                }
            }
            if ($occurrence.Project -isnot [string] -or $occurrence.Kind -notin 'Direct', 'Transitive' -or
                $occurrence.ResolvedVersion -isnot [string] -or $occurrence.Parents -isnot [array]) {
                throw "Report non valido per '$($entry.Package)': occorrenza con tipi inattesi."
            }
            foreach ($parent in $occurrence.Parents) {
                if ($null -eq $parent -or $null -eq $parent.PSObject.Properties['Package'] -or
                    $null -eq $parent.PSObject.Properties['Range'] -or $null -eq $parent.PSObject.Properties['Minimum']) {
                    throw "Report non valido per '$($entry.Package)': vincolo transitivo incompleto."
                }
            }
        }
    }

    $data = ConvertTo-Json -InputObject @($entries.ToArray()) -Depth 30 -Compress
    $data = $data.Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
    $data = $data.Replace([string][char]0x2028, '\u2028').Replace([string][char]0x2029, '\u2029')
    $html = @'
<!doctype html>
<html lang="it">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Igiene delle dipendenze NuGet</title>
<script>
  (() => {
    const param = new URLSearchParams(window.location.search).get("scoutTheme");
    const theme =
      param || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
    document.documentElement.setAttribute("data-theme", theme);
  })();
</script>
<style>
:root {
  color-scheme: light;
  --cp-bg: #f7f4ef;
  --cp-bg-elevated: #fcfbf8;
  --cp-surface: #ffffff;
  --cp-surface-soft: #f5f5f5;
  --cp-border: #dedede;
  --cp-border-strong: #919191;
  --cp-text: #242424;
  --cp-text-muted: #5c5c5c;
  --cp-text-soft: #6f6f6f;
  --cp-accent: #b11f4b;
  --cp-accent-hover: #9a1a41;
  --cp-accent-soft: rgba(177, 31, 75, 0.08);
  --cp-accent-fg: #ffffff;
  --cp-success: #16a34a;
  --cp-danger: #dc2626;
  --cp-warning: #f59e0b;
  --cp-link: #0078d4;
  --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.12);
  --cp-overlay: rgba(255, 255, 255, 0.8);
  --cp-panel: rgba(255, 255, 255, 0.86);
  --cp-panel-strong: rgba(255, 255, 255, 0.96);
  --cp-sheen: rgba(255, 255, 255, 0.55);
  --cp-highlight: rgba(177, 31, 75, 0.12);
}
html[data-theme="dark"] {
  color-scheme: dark;
  --cp-bg: #3d3b3a;
  --cp-bg-elevated: #343231;
  --cp-surface: #292929;
  --cp-surface-soft: #2e2e2e;
  --cp-border: #474747;
  --cp-border-strong: #5f5f5f;
  --cp-text: #dedede;
  --cp-text-muted: #919191;
  --cp-text-soft: #b0b0b0;
  --cp-accent: #fd8ea1;
  --cp-accent-hover: #fb7b91;
  --cp-accent-soft: rgba(253, 142, 161, 0.14);
  --cp-accent-fg: #1a1a1a;
  --cp-success: #4ade80;
  --cp-danger: #f87171;
  --cp-warning: #fbbf24;
  --cp-link: #4da6ff;
  --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.32);
  --cp-overlay: rgba(41, 41, 41, 0.88);
  --cp-panel: rgba(41, 41, 41, 0.72);
  --cp-panel-strong: rgba(41, 41, 41, 0.96);
  --cp-sheen: rgba(255, 255, 255, 0.04);
  --cp-highlight: rgba(253, 142, 161, 0.12);
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--cp-bg); color: var(--cp-text); font-family: "Segoe UI", Aptos, Calibri, -apple-system, BlinkMacSystemFont, sans-serif; }
button, input, select { font: inherit; }
button, select { cursor: pointer; }
button:focus-visible, input:focus-visible, select:focus-visible, summary:focus-visible { outline: 2px solid var(--cp-accent); outline-offset: 2px; }
.shell { max-width: 1500px; margin: auto; padding: 36px 28px 72px; }
.eyebrow { text-transform: uppercase; color: var(--cp-accent); letter-spacing: .15em; font-size: .73rem; font-weight: 700; }
h1 { margin: 8px 0; font-size: clamp(2rem, 4vw, 3.2rem); line-height: 1.12; letter-spacing: -.035em; }
h2, h3, p { margin-top: 0; }
.intro { max-width: 780px; color: var(--cp-text-muted); line-height: 1.55; }
.summary { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; margin: 30px 0 24px; }
.metric, .panel { background: var(--cp-surface); border: 1px solid var(--cp-border); border-radius: 16px; }
.metric { padding: 20px; }
.metric strong { display: block; font-size: 2rem; font-variant-numeric: tabular-nums; line-height: 1.2; }
.metric span { color: var(--cp-text-muted); font-size: .87rem; }
.metric.alert strong { color: var(--cp-accent); }
.layout { display: grid; grid-template-columns: minmax(340px, 460px) minmax(0, 1fr); gap: 16px; align-items: start; }
.panel { min-width: 0; overflow: hidden; }
.panel-heading { padding: 20px 20px 12px; border-bottom: 1px solid var(--cp-border); }
.panel-heading h2 { margin: 0 0 4px; font-size: 1.15rem; }
.subtle { color: var(--cp-text-muted); font-size: .84rem; }
.controls { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; padding: 16px 20px; }
.controls input { grid-column: 1 / -1; }
.controls input, .controls select { min-width: 0; width: 100%; padding: 10px 12px; border: 1px solid var(--cp-border); border-radius: .625rem; background: var(--cp-bg-elevated); color: var(--cp-text); }
.controls #project { grid-column: 1 / -1; }
.package-list { max-height: 690px; overflow-y: auto; border-top: 1px solid var(--cp-border); }
.package { display: block; width: 100%; text-align: left; border: 0; border-bottom: 1px solid var(--cp-border); background: var(--cp-surface); color: var(--cp-text); padding: 14px 20px; }
.package:hover, .package[aria-current="true"] { background: var(--cp-accent-soft); }
.package[aria-current="true"] { box-shadow: inset 3px 0 var(--cp-accent); }
.package-name { display: block; font-weight: 650; overflow-wrap: anywhere; margin-bottom: 5px; }
.package-meta { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; color: var(--cp-text-muted); font-size: .8rem; }
.pill { display: inline-block; padding: 3px 8px; border-radius: .625rem; border: 1px solid var(--cp-border); background: var(--cp-surface-soft); color: var(--cp-text-muted); font-size: .76rem; font-weight: 600; }
.pill.risk { border-color: var(--cp-accent); background: var(--cp-accent-soft); color: var(--cp-accent); }
.pill.minimum { border-color: var(--cp-warning); color: var(--cp-text); }
.detail { padding: 24px; min-height: 370px; }
.detail h2 { font-size: clamp(1.35rem, 2vw, 1.85rem); overflow-wrap: anywhere; margin: 0 0 8px; }
.detail-intro { display: flex; gap: 8px; flex-wrap: wrap; margin: 14px 0 24px; }
.detail h3 { font-size: .94rem; margin: 26px 0 10px; }
.version-line { display: flex; flex-wrap: wrap; gap: 7px; }
.version { padding: 6px 10px; border: 1px solid var(--cp-border); background: var(--cp-bg-elevated); border-radius: .625rem; font-family: Consolas, "Courier New", Courier, monospace; font-size: .84rem; }
.occurrence { padding: 16px 0; border-top: 1px solid var(--cp-border); }
.occurrence-header { display: flex; align-items: flex-start; justify-content: space-between; gap: 8px; }
.project-name { font-weight: 600; overflow-wrap: anywhere; }
.path { margin-top: 4px; color: var(--cp-text-muted); font-size: .78rem; overflow-wrap: anywhere; font-family: Consolas, "Courier New", Courier, monospace; }
.facts { display: flex; flex-wrap: wrap; gap: 8px 16px; margin: 12px 0 0; color: var(--cp-text-muted); font-size: .83rem; }
.facts b { color: var(--cp-text); }
details { margin-top: 12px; border: 1px solid var(--cp-border); border-radius: .625rem; padding: 9px 12px; }
summary { cursor: pointer; color: var(--cp-link); font-size: .83rem; }
.parent { border-top: 1px solid var(--cp-border); padding: 10px 0 2px; margin-top: 10px; font-size: .83rem; overflow-wrap: anywhere; }
.parent b { display: block; }
.parent span { color: var(--cp-text-muted); }
.empty { padding: 24px; color: var(--cp-text-muted); line-height: 1.5; }
footer { margin-top: 24px; color: var(--cp-text-soft); font-size: .8rem; }
@media (max-width: 900px) { .layout { grid-template-columns: 1fr; } .package-list { max-height: 320px; } }
@media (max-width: 640px) { .shell { padding: 24px 14px 48px; } .summary { grid-template-columns: repeat(2, 1fr); } .detail { padding: 18px; } }
</style>
</head>
<body>
<main class="shell">
  <div class="eyebrow">Dependency intelligence / NuGet</div>
  <h1>Igiene delle dipendenze</h1>
  <p class="intro">Esplora le versioni risolte e i vincoli transitivi tra progetti. Le differenze tra pacchetti segnalano un possibile rischio per le DLL, non un conflitto binario accertato.</p>
  <section class="summary" aria-label="Riepilogo">
    <div class="metric"><strong id="package-count">0</strong><span>Pacchetti</span></div>
    <div class="metric"><strong id="project-count">0</strong><span>Progetti</span></div>
    <div class="metric alert"><strong id="version-count">0</strong><span>Versioni divergenti</span></div>
    <div class="metric alert"><strong id="minimum-count">0</strong><span>Minimi transitivi divergenti</span></div>
  </section>
  <div class="layout">
    <section class="panel" aria-label="Elenco pacchetti">
      <div class="panel-heading"><h2>Pacchetti</h2><span id="shown" class="subtle"></span></div>
      <div class="controls">
        <input id="search" type="search" placeholder="Cerca pacchetto, progetto o dipendenza..." aria-label="Cerca">
        <select id="filter" aria-label="Filtra conflitti">
          <option value="all">Tutti i pacchetti</option>
          <option value="any">Qualsiasi divergenza</option>
          <option value="version">Versioni divergenti</option>
          <option value="minimum">Minimi divergenti</option>
        </select>
        <select id="sort" aria-label="Ordina pacchetti">
          <option value="risk">Prima le divergenze</option>
          <option value="name">Nome A–Z</option>
          <option value="projects">Numero di progetti</option>
        </select>
        <select id="project" aria-label="Filtra progetto"><option value="">Tutti i progetti</option></select>
      </div>
      <div id="packages" class="package-list"></div>
    </section>
    <section id="details" class="panel detail" aria-live="polite" aria-label="Dettaglio pacchetto"></section>
  </div>
  <footer>Report autonomo · Nessun servizio esterno richiesto · Vincoli minimi calcolati sulle dipendenze transitive</footer>
</main>
<script id="report-data" type="application/json">__REPORT_DATA__</script>
<script>
(() => {
  "use strict";
  const data = JSON.parse(document.getElementById("report-data").textContent);
  const byId = id => document.getElementById(id);
  const collator = new Intl.Collator("it", { sensitivity: "base", numeric: true });
  const state = { selected: null };
  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  };
  const projectName = path => path.split(/[\\/]/).pop() || path;
  const distinctProjects = item => new Set(item.Occurrences.map(o => o.Project)).size;
  const projects = [...new Set(data.flatMap(item => item.Occurrences.map(o => o.Project)))].sort(collator.compare);
  byId("package-count").textContent = data.length;
  byId("project-count").textContent = projects.length;
  byId("version-count").textContent = data.filter(item => item.VersionConflict).length;
  byId("minimum-count").textContent = data.filter(item => item.MinimumConflict).length;
  for (const path of projects) {
    const option = el("option", "", path);
    option.value = path;
    byId("project").append(option);
  }
  const badge = (text, type) => el("span", `pill ${type || ""}`, text);
  const versionLine = values => {
    const line = el("div", "version-line");
    for (const value of values) line.append(el("span", "version", value));
    return line;
  };
  function showDetails(item) {
    const target = byId("details");
    target.replaceChildren();
    if (!item) {
      target.append(el("div", "empty", "Nessun pacchetto corrisponde ai filtri. Modifica la ricerca per esplorare il report."));
      return;
    }
    target.append(el("div", "eyebrow", "Dettaglio pacchetto"), el("h2", "", item.Package));
    const tags = el("div", "detail-intro");
    tags.append(badge(`${distinctProjects(item)} progetti`));
    if (item.VersionConflict) tags.append(badge("Versioni divergenti", "risk"));
    if (item.MinimumConflict) tags.append(badge("Minimi divergenti", "minimum"));
    if (!item.VersionConflict && !item.MinimumConflict) tags.append(badge("Nessuna divergenza"));
    target.append(tags, el("h3", "", "Versioni risolte"), versionLine(item.ResolvedVersions));
    target.append(el("h3", "", "Minimi richiesti dai pacchetti padri"));
    target.append(item.TransitiveMinimums.length ? versionLine(item.TransitiveMinimums) : el("p", "subtle", "Nessun vincolo transitivo rilevato."));
    target.append(el("h3", "", `Presenza nei progetti (${item.Occurrences.length})`));
    for (const occurrence of item.Occurrences) {
      const row = el("article", "occurrence");
      const head = el("div", "occurrence-header");
      const title = el("div");
      title.append(el("div", "project-name", projectName(occurrence.Project)), el("div", "path", occurrence.Project));
      head.append(title, badge(occurrence.Kind === "Direct" ? "Diretta" : "Transitiva"));
      row.append(head);
      const facts = el("div", "facts");
      const resolved = el("span");
      resolved.append(el("span", "", "Risolta: "), el("b", "", occurrence.ResolvedVersion));
      facts.append(resolved);
      if (occurrence.RequestedVersion) {
        const requested = el("span");
        requested.append(el("span", "", "Richiesta: "), el("b", "", occurrence.RequestedVersion));
        facts.append(requested);
      }
      row.append(facts);
      if (occurrence.Parents.length) {
        const box = el("details");
        box.append(el("summary", "", `${occurrence.Parents.length} vincoli dai pacchetti padri`));
        for (const parent of occurrence.Parents) {
          const entry = el("div", "parent");
          entry.append(el("b", "", parent.Package), el("span", "", `Intervallo: ${parent.Range || "—"} · Minimo: ${parent.Minimum || "non definito"}`));
          box.append(entry);
        }
        row.append(box);
      }
      target.append(row);
    }
  }
  function render() {
    const query = byId("search").value.trim().toLocaleLowerCase("it");
    const project = byId("project").value;
    const filter = byId("filter").value;
    const visible = data.filter(item => {
      if (project && !item.Occurrences.some(o => o.Project === project)) return false;
      if (filter === "any" && !item.VersionConflict && !item.MinimumConflict) return false;
      if (filter === "version" && !item.VersionConflict) return false;
      if (filter === "minimum" && !item.MinimumConflict) return false;
      return !query || [item.Package, ...item.Occurrences.flatMap(o => [o.Project, ...o.Parents.map(p => p.Package)])]
        .some(value => value.toLocaleLowerCase("it").includes(query));
    });
    const sort = byId("sort").value;
    visible.sort((a, b) => sort === "projects"
      ? distinctProjects(b) - distinctProjects(a) || collator.compare(a.Package, b.Package)
      : sort === "risk"
        ? Number(b.VersionConflict) - Number(a.VersionConflict) || Number(b.MinimumConflict) - Number(a.MinimumConflict) || collator.compare(a.Package, b.Package)
        : collator.compare(a.Package, b.Package));
    if (!visible.some(item => item.Package === state.selected)) state.selected = visible[0]?.Package || null;
    byId("shown").textContent = `${visible.length} di ${data.length} visualizzati`;
    const list = byId("packages");
    list.replaceChildren();
    for (const item of visible) {
      const button = el("button", "package");
      button.type = "button";
      button.setAttribute("aria-current", String(item.Package === state.selected));
      button.append(el("span", "package-name", item.Package));
      const meta = el("span", "package-meta");
      meta.append(el("span", "", `${distinctProjects(item)} progetti · ${item.ResolvedVersions.join(", ")}`));
      if (item.VersionConflict) meta.append(badge("Versioni", "risk"));
      if (item.MinimumConflict) meta.append(badge("Minimi", "minimum"));
      button.append(meta);
      button.addEventListener("click", () => { state.selected = item.Package; render(); });
      list.append(button);
    }
    if (!visible.length) list.append(el("div", "empty", "Nessun risultato."));
    showDetails(visible.find(item => item.Package === state.selected));
  }
  for (const id of ["search", "filter", "sort", "project"]) {
    byId(id).addEventListener(id === "search" ? "input" : "change", render);
  }
  render();
})();
</script>
</body>
</html>
'@
    $html = $html.Replace('__REPORT_DATA__', $data)
    $destination = [IO.Path]::GetFullPath($OutputPath)
    $directory = Split-Path -Path $destination -Parent
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "La directory di output '$directory' non esiste."
    }
    Set-Content -LiteralPath $destination -Value $html -Encoding utf8
    if (-not $NoOpen) { Invoke-Item -LiteralPath $destination }
    Write-Output $destination
}
